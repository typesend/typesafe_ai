defmodule TypeSafe.Error do
  @moduledoc """
  The single error value returned by every `{:error, _}` tuple in this library.

  Errors are values, not exceptions, so callers can pattern match on `type` without
  rescuing. The bang variants (`TypeSafe.evaluate!/4` and friends) raise this same
  struct, which is why it is also an exception.

  ## Types

    * `:auth` - HTTP 401. The API key is missing or invalid.
    * `:validation` - HTTP 400 or 422 from the API (a malformed body, an
      unknown model, too many options), or a problem this library caught
      locally before sending anything (for example a Score with one level).
      `status` is `nil` for local validation errors.
    * `:rate_limited` - HTTP 429. Retried automatically; you only see it once
      the retry policy gives up.
    * `:overloaded` - HTTP 529 (and 503). Also retried automatically.
    * `:timeout` - the request exceeded its timeout without a response.
    * `:connection` - the request could not reach the server at all.
    * `:unexpected` - anything else: an unknown status, a body that failed to
      decode, or a response shape this library does not understand.

  ## Fields

    * `status` - the HTTP status, or `nil` when no response was involved
      (local validation, timeouts, connection failures).
    * `message` - a one-line summary. For a 422 the API returns a list of
      `%{"loc" => [...], "msg" => ...}` entries; they are joined as
      `body.questions.dept.criteria: Field required; ...` so the offending
      field is readable without parsing `body`.
    * `body` - the decoded JSON error body, the raw string when it was not
      JSON, or `nil`. Log it for `:unexpected` errors: it shows what changed.
    * `request_id` - the `x-typesafe-request-id` response header. Quote it
      when contacting TypeSafe support.
    * `retry_after_ms` - the wait the server asked for, from `retry-after-ms`
      or `Retry-After`, kept even after retries are exhausted so you can back
      off before the next call or batch.

      case TypeSafe.evaluate(client, state, questions) do
        {:ok, result} -> result
        {:error, %TypeSafe.Error{type: :rate_limited, retry_after_ms: ms}} -> retry_later(ms)
        {:error, %TypeSafe.Error{request_id: id} = error} -> Logger.error(Exception.message(error), request_id: id)
      end
  """

  @type type ::
          :auth
          | :validation
          | :rate_limited
          | :overloaded
          | :timeout
          | :connection
          | :unexpected

  @type t :: %__MODULE__{
          type: type(),
          status: pos_integer() | nil,
          message: String.t(),
          body: term(),
          request_id: String.t() | nil,
          retry_after_ms: non_neg_integer() | nil
        }

  defexception [:type, :status, :message, :body, :request_id, :retry_after_ms]

  @impl Exception
  def message(%__MODULE__{type: type, status: nil, message: message}) do
    "#{type}: #{message}"
  end

  def message(%__MODULE__{type: type, status: status, message: message}) do
    "#{type} (HTTP #{status}): #{message}"
  end

  @doc """
  Builds a local validation error. Nothing was sent to the API.
  """
  @spec validation(String.t()) :: t()
  def validation(message) when is_binary(message) do
    %__MODULE__{type: :validation, status: nil, message: message}
  end

  @doc """
  Builds an `:unexpected` error for a response we could not make sense of.
  """
  @spec unexpected(String.t(), term()) :: t()
  def unexpected(message, body \\ nil) when is_binary(message) do
    %__MODULE__{type: :unexpected, status: nil, message: message, body: body}
  end

  @doc """
  Maps an HTTP response to an error. Only call this for non-2xx responses.
  """
  @spec from_response(Req.Response.t()) :: t()
  def from_response(%Req.Response{status: status, body: body} = response) do
    %__MODULE__{
      type: type_for_status(status),
      status: status,
      message: extract_message(body) || default_message(status),
      body: body,
      request_id: TypeSafe.HTTP.first_header(response, "x-typesafe-request-id"),
      retry_after_ms: TypeSafe.Retry.retry_after_ms(response)
    }
  end

  @doc """
  Maps a transport-level exception (no HTTP response) to an error.
  """
  @spec from_exception(Exception.t()) :: t()
  def from_exception(%Req.TransportError{reason: :timeout} = exception) do
    %__MODULE__{type: :timeout, message: Exception.message(exception)}
  end

  def from_exception(%Req.TransportError{} = exception) do
    %__MODULE__{type: :connection, message: Exception.message(exception)}
  end

  def from_exception(%Req.HTTPError{} = exception) do
    %__MODULE__{type: :connection, message: Exception.message(exception)}
  end

  def from_exception(exception) when is_exception(exception) do
    %__MODULE__{type: :unexpected, message: Exception.message(exception)}
  end

  @doc false
  @spec type_for_status(pos_integer()) :: type()
  def type_for_status(401), do: :auth
  def type_for_status(status) when status in [400, 422], do: :validation
  def type_for_status(429), do: :rate_limited
  def type_for_status(status) when status in [503, 529], do: :overloaded
  def type_for_status(_status), do: :unexpected

  defp default_message(401), do: "Missing or invalid API key"
  defp default_message(400), do: "The request was rejected"
  defp default_message(422), do: "The request body failed validation"
  defp default_message(429), do: "Rate limit exceeded"
  defp default_message(529), do: "TypeSafe is temporarily overloaded"
  defp default_message(status), do: "Unexpected HTTP status #{status}"

  # Mirrors the official SDK: prefer `error`, then `message`, then `detail`
  # (which FastAPI-style validation errors return as a list of `%{loc, msg}`).
  defp extract_message(body) when is_binary(body) and body != "", do: body
  defp extract_message(%{"error" => error}) when is_binary(error) and error != "", do: error
  defp extract_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg

  defp extract_message(%{"message" => message}) when is_binary(message) and message != "",
    do: message

  defp extract_message(%{"detail" => detail}) when is_binary(detail) and detail != "", do: detail

  defp extract_message(%{"detail" => %{"message" => msg}}) when is_binary(msg) and msg != "",
    do: msg

  defp extract_message(%{"detail" => [_ | _] = details}) do
    details
    |> Enum.map(&format_detail/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "; ")
    end
  end

  defp extract_message(_body), do: nil

  defp format_detail(%{"loc" => loc, "msg" => msg}) when is_list(loc) and is_binary(msg) do
    "#{Enum.map_join(loc, ".", &to_string/1)}: #{msg}"
  end

  defp format_detail(%{"msg" => msg}) when is_binary(msg), do: msg
  defp format_detail(_), do: nil
end
