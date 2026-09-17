defmodule TypeSafeAPI.HTTP do
  @moduledoc """
  Layer 1: the raw HTTP client. Maps in, maps out.

  This module knows about URLs, headers, JSON, retries, telemetry, and how
  status codes map to `TypeSafeAPI.Error` types. It knows nothing about questions
  or answers. If the API grows a field tomorrow, this layer passes it through
  untouched, which is the point: the typed layer above can lag the API without
  the raw layer becoming useless.

      client = TypeSafeAPI.new(api_key: "sk-...")

      TypeSafeAPI.HTTP.post(client, "/v1/systemone", %{
        "state" => "Help! My payouts have been failing for 3 days.",
        "model" => "jev-latest",
        "questions" => %{"urgent" => %{"type" => "noul", "instructions" => "Is it urgent?"}}
      })
      #=> {:ok, %{"model" => "jev-latest", "answers" => %{...}, "usage" => %{...}}}

  JSON is encoded with Elixir's built-in `JSON` module. Bodies may contain any
  term with a `JSON.Encoder` implementation, which is how the typed layer keeps
  Choice options in caller order.

  ## Timeouts and connection pools

  `Req` starts (or reuses) a Finch pool keyed by the connection settings of a
  request, so anything that changes those settings from call to call creates a
  pool per distinct value and throws connection reuse away.

  What selects a pool:

    * the client's `finch:` option - names a pool you started and supervise
      yourself, which is the only way to control pool size. `connect_options`
      is then omitted entirely, `connect_timeout` included: those settings
      belong to your `Finch` child spec instead
    * `req_options` carrying `connect_options:` - a different value is a
      different pool. What this module sets as the connect timeout is merged
      *under* yours, so `connect_timeout` survives unless you set `timeout:`
      inside `connect_options` yourself
    * the client's `connect_timeout`, which is the `connect_options` timeout
      this module sets; it is fixed for the life of a client

  What does not select a pool:

    * the client's `timeout` and the per-call `:timeout`, which means the same
      thing in `TypeSafeAPI.evaluate_many/4`; they set `receive_timeout` only,
      so two calls with different timeouts share a pool
    * `:retry`, `:telemetry`, headers, the body, the path

  In short: vary `:timeout` per call as much as you like; set `connect_options`
  once, on the client, or hand the client a `finch:` pool of your own.
  """

  alias TypeSafeAPI.{Client, Error, Keys, Retry, Telemetry, Usage}
  alias TypeSafeAPI.HTTP.Adapter
  alias TypeSafeAPI.JSON.{Encoded, OrderedObject}

  @version Mix.Project.config()[:version]
  @user_agent "typesafe_api/#{@version} (Elixir)"

  @typedoc """
  Per-call options accepted by `post/4` and `get/3`.

    * `:timeout` - overrides the client timeout for this call (milliseconds).
      Bounds waiting for the response only; the connect timeout is the
      client's `connect_timeout`, so this option never changes which Finch
      pool the call uses
    * `:retry` - a keyword list layers onto the client retry policy, changing
      only the settings it names; a `%TypeSafeAPI.Retry{}` replaces it wholesale
    * `:req_options` - extra `Req` options merged in last. The options this
      library owns (`:retry`, `:auth`, `:base_url`, `:finch`) are not yours to
      set here; use the matching client option
    * `:telemetry` - extra metadata merged into the telemetry events
  """
  @type call_option ::
          {:timeout, pos_integer()}
          | {:retry, TypeSafeAPI.Retry.t() | keyword()}
          | {:req_options, keyword()}
          | {:telemetry, map()}

  @type response :: {:ok, map()} | {:error, Error.t()}

  @typedoc "Result of `request/5`: the full response, not just the body."
  @type full_response :: {:ok, TypeSafeAPI.HTTP.Response.t()} | {:error, Error.t()}

  @doc "The `User-Agent` sent with every request."
  @spec user_agent() :: String.t()
  def user_agent, do: @user_agent

  @doc """
  Sends a JSON `POST` and returns the decoded JSON body.
  """
  @spec post(Client.t(), String.t(), term(), [call_option()]) :: response()
  def post(%Client{} = client, path, body, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, response} <- request(client, :post, path, body, opts), do: {:ok, response.body}
  end

  @doc """
  Sends a `GET` and returns the decoded JSON body.
  """
  @spec get(Client.t(), String.t(), [call_option()]) :: response()
  def get(%Client{} = client, path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, response} <- request(client, :get, path, nil, opts), do: {:ok, response.body}
  end

  @doc """
  Sends a request and returns the full `TypeSafeAPI.HTTP.Response`, including the
  status, headers, `request_id`, and how many retries it took.

  `body` is JSON-encoded when present; pass `nil` for a bodiless request.
  """
  @spec request(Client.t(), :get | :post, String.t(), term(), [call_option()]) ::
          full_response()
  def request(%Client{} = client, method, path, body, opts \\ [])
      when method in [:get, :post] and is_binary(path) and is_list(opts) do
    metadata =
      %{method: method, path: path}
      |> Map.merge(Keyword.get(opts, :telemetry, %{}))
      |> Map.put_new_lazy(:model, fn -> Keys.get(body, :model) end)
      |> Map.put_new_lazy(:question_count, fn -> question_count(body) end)

    Telemetry.span(metadata, fn ->
      {request, outcome} =
        client |> build(method, path, body, opts) |> Req.Request.run_request()

      retries = Retry.retry_count(request)
      result = handle(outcome, retries)
      {result, stop_metadata(outcome, result, retries)}
    end)
  end

  @doc """
  Builds the `Req.Request` for a call without running it.

  Exposed for inspection and for `TypeSafeAPI.Test`; most callers want `post/4`.

  The per-call `:timeout` lands on `receive_timeout`; `connect_options` comes
  from the client alone, so two calls that differ only in `:timeout` build
  identical `connect_options` and share one connection pool.

  Connection settings and `retry: false` are merged after every user option,
  so `req_options` can neither re-enable `Req`'s own retry step on top of this
  library's nor drop the client's connect timeout.
  """
  @spec build(Client.t(), :get | :post, String.t(), term(), [call_option()]) :: Req.Request.t()
  def build(%Client{} = client, method, path, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, client.timeout)

    request =
      Req.new(
        method: method,
        url: path,
        base_url: client.base_url,
        auth: {:bearer, client.api_key},
        headers: [user_agent: @user_agent, accept: "application/json"],
        receive_timeout: timeout,
        decode_body: false
      )
      |> Retry.attach(retry_policy(client, opts))
      |> Req.merge(client.req_options)
      |> Req.merge(Keyword.get(opts, :req_options, []))
      |> connect_settings(client)
      # Last, so no user option can re-enable Req's own retry step on top of
      # this library's: two nested loops multiply attempts and Req's is not
      # bounded by the wall-clock budget.
      |> Req.merge(retry: false)
      # Last of all, and around whatever adapter the options settled on: a
      # Finch pool checkout timeout raises rather than returning an error, and
      # this turns it back into one the retry step can act on.
      |> Adapter.wrap()

    case body do
      nil ->
        request

      body ->
        Req.merge(request, body: encode_body(body), headers: [content_type: "application/json"])
    end
  end

  # A keyword list names the settings to change; a policy replaces the client's.
  defp retry_policy(client, opts) do
    case Keyword.fetch(opts, :retry) do
      :error -> Retry.new(client.retry)
      {:ok, overrides} -> Retry.merge(client.retry, overrides)
    end
  end

  # `Req.merge/2` replaces `connect_options` wholesale, so the client's connect
  # timeout has to be merged back under whatever the user supplied. A client
  # with its own Finch pool gets neither: Req refuses `:finch` and
  # `:connect_options` together, and pool settings live in the Finch child spec.
  defp connect_settings(request, %Client{finch: nil} = client) do
    user = Map.get(request.options, :connect_options, [])
    Req.merge(request, connect_options: Keyword.merge([timeout: client.connect_timeout], user))
  end

  defp connect_settings(request, %Client{finch: finch}) do
    request
    |> Req.Request.delete_option(:connect_options)
    |> Req.merge(finch: finch)
  end

  @doc false
  # First value of a response header, or nil. Shared by the error and retry modules.
  @spec first_header(Req.Response.t(), String.t()) :: String.t() | nil
  def first_header(%Req.Response{} = response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> String.trim(value)
      [] -> nil
    end
  end

  defp handle(%Req.Response{status: status, body: body} = response, retry_count)
       when status in 200..299 do
    case decode_body(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, ok_response(response, decoded, retry_count)}

      # A 204, or a 2xx that simply has nothing to say. The call succeeded;
      # there is no body to decode, so the body is an empty map.
      :empty ->
        {:ok, ok_response(response, %{}, retry_count)}

      {:ok, other} ->
        {:error,
         unexpected(response, "expected a JSON object body, got: #{inspect(other)}", retry_count)}

      :error ->
        {:error, unexpected(response, "response body is not valid JSON", retry_count)}
    end
  end

  defp handle(%Req.Response{} = response, retry_count) do
    body =
      case decode_body(response.body) do
        {:ok, decoded} -> decoded
        _ -> response.body
      end

    error = Error.from_response(%{response | body: body})
    {:error, %{error | retry_count: retry_count}}
  end

  defp handle(exception, retry_count) when is_exception(exception) do
    error = Error.from_exception(exception)
    {:error, %{error | retry_count: retry_count}}
  end

  defp ok_response(%Req.Response{} = response, body, retry_count) do
    %TypeSafeAPI.HTTP.Response{
      status: response.status,
      body: body,
      headers: response.headers,
      request_id: first_header(response, "x-typesafe-request-id"),
      retry_count: retry_count
    }
  end

  # A response did arrive, so the status and the request id support will ask
  # for are known even though the body made no sense.
  defp unexpected(%Req.Response{} = response, message, retry_count) do
    Error.unexpected(message, response.body,
      status: response.status,
      request_id: first_header(response, "x-typesafe-request-id"),
      headers: response.headers,
      retry_count: retry_count
    )
  end

  defp stop_metadata(outcome, result, retries) do
    # Decoded rather than read raw: the wire `usage` object may omit a count or
    # send it as a float, and a handler should not have to defend against that.
    usage =
      case result do
        {:ok, %TypeSafeAPI.HTTP.Response{body: %{"usage" => %{} = usage}}} -> Usage.decode(usage)
        _ -> %Usage{}
      end

    %{
      status: status_of(outcome),
      retry_count: retries,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      error: error_of(result)
    }
  end

  defp status_of(%Req.Response{status: status}), do: status
  defp status_of(_exception), do: nil

  defp error_of({:error, error}), do: error
  defp error_of(_ok), do: nil

  defp encode_body(body), do: JSON.encode_to_iodata!(body)

  defp decode_body(body) when is_binary(body) do
    case body |> String.trim() |> decode_trimmed() do
      {:ok, decoded} -> {:ok, decoded}
      other -> other
    end
  end

  defp decode_body(body) when is_map(body) or is_list(body), do: {:ok, body}
  defp decode_body(nil), do: :empty
  defp decode_body(_), do: :error

  defp decode_trimmed(""), do: :empty

  defp decode_trimmed(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :error
    end
  end

  # The typed layer sends its questions pre-serialized, so what lands here is
  # usually a struct rather than a plain map. `map_size/1` on a struct counts
  # its fields, which would have reported the same wrong number for every
  # evaluation, so each shape is matched deliberately and anything unrecognised
  # reports nothing rather than a plausible lie.
  defp question_count(body) do
    body |> Keys.get(:questions) |> count_questions()
  end

  defp count_questions(%Encoded{object: object}), do: count_questions(object)
  defp count_questions(%OrderedObject{} = questions), do: Enum.count(questions)
  defp count_questions(%_{}), do: nil
  defp count_questions(questions) when is_map(questions), do: map_size(questions)
  defp count_questions(questions) when is_list(questions), do: length(questions)
  defp count_questions(_other), do: nil
end
