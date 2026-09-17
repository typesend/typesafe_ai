defmodule TypeSafe.HTTP do
  @moduledoc """
  Layer 1: the raw HTTP client. Maps in, maps out.

  This module knows about URLs, headers, JSON, retries, telemetry, and how
  status codes map to `TypeSafe.Error` types. It knows nothing about questions
  or answers. If the API grows a field tomorrow, this layer passes it through
  untouched, which is the point: the typed layer above can lag the API without
  the raw layer becoming useless.

      client = TypeSafe.new(api_key: "sk-...")

      TypeSafe.HTTP.post(client, "/v1/systemone", %{
        "state" => "Help! My payouts have been failing for 3 days.",
        "model" => "jev-latest",
        "questions" => %{"urgent" => %{"type" => "noul", "instructions" => "Is it urgent?"}}
      })
      #=> {:ok, %{"model" => "jev-latest", "answers" => %{...}, "usage" => %{...}}}

  JSON is encoded with Elixir's built-in `JSON` module. Bodies may contain any
  term with a `JSON.Encoder` implementation, which is how the typed layer keeps
  Choice options in caller order.
  """

  alias TypeSafe.{Client, Error, Keys, Retry, Telemetry}

  @version Mix.Project.config()[:version]
  @user_agent "typesafe_api/#{@version} (Elixir)"

  @typedoc """
  Per-call options accepted by `post/4` and `get/3`.

    * `:timeout` - overrides the client timeout for this call (milliseconds)
    * `:retry` - overrides the client retry policy (`TypeSafe.Retry.new/1` input)
    * `:req_options` - extra `Req` options merged in last
    * `:telemetry` - extra metadata merged into the telemetry events
  """
  @type call_option ::
          {:timeout, pos_integer()}
          | {:retry, TypeSafe.Retry.t() | keyword()}
          | {:req_options, keyword()}
          | {:telemetry, map()}

  @type response :: {:ok, map()} | {:error, Error.t()}

  @typedoc "Result of `request/5`: the full response, not just the body."
  @type full_response :: {:ok, TypeSafe.HTTP.Response.t()} | {:error, Error.t()}

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
  Sends a request and returns the full `TypeSafe.HTTP.Response`, including the
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

  Exposed for inspection and for `TypeSafe.Test`; most callers want `post/4`.
  """
  @spec build(Client.t(), :get | :post, String.t(), term(), [call_option()]) :: Req.Request.t()
  def build(%Client{} = client, method, path, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, client.timeout)
    retry = opts |> Keyword.get(:retry, client.retry) |> Retry.new()

    request =
      Req.new(
        method: method,
        url: path,
        base_url: client.base_url,
        auth: {:bearer, client.api_key},
        headers: [user_agent: @user_agent, accept: "application/json"],
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        decode_body: false
      )
      |> Retry.attach(retry)
      |> Req.merge(client.req_options)
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case body do
      nil ->
        request

      body ->
        Req.merge(request, body: encode_body(body), headers: [content_type: "application/json"])
    end
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
        {:ok,
         %TypeSafe.HTTP.Response{
           status: status,
           body: decoded,
           headers: response.headers,
           request_id: first_header(response, "x-typesafe-request-id"),
           retry_count: retry_count
         }}

      {:ok, other} ->
        {:error, Error.unexpected("expected a JSON object body, got: #{inspect(other)}", body)}

      :error ->
        {:error, Error.unexpected("response body is not valid JSON", body)}
    end
  end

  defp handle(%Req.Response{} = response, _retry_count) do
    body =
      case decode_body(response.body) do
        {:ok, decoded} -> decoded
        :error -> response.body
      end

    {:error, Error.from_response(%{response | body: body})}
  end

  defp handle(exception, _retry_count) when is_exception(exception) do
    {:error, Error.from_exception(exception)}
  end

  defp stop_metadata(outcome, result, retries) do
    usage =
      case result do
        {:ok, %TypeSafe.HTTP.Response{body: %{"usage" => %{} = usage}}} -> usage
        _ -> %{}
      end

    %{
      status: status_of(outcome),
      retry_count: retries,
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      error: error_of(result)
    }
  end

  defp status_of(%Req.Response{status: status}), do: status
  defp status_of(_exception), do: nil

  defp error_of({:error, error}), do: error
  defp error_of(_ok), do: nil

  defp encode_body(body), do: JSON.encode_to_iodata!(body)

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :error
    end
  end

  defp decode_body(body) when is_map(body) or is_list(body), do: {:ok, body}
  defp decode_body(_), do: :error

  defp question_count(body) do
    case Keys.get(body, :questions) do
      questions when is_map(questions) -> map_size(questions)
      questions when is_list(questions) -> length(questions)
      _ -> nil
    end
  end
end
