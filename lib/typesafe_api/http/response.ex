defmodule TypeSafeAPI.HTTP.Response do
  @moduledoc """
  A successful raw response: the decoded JSON body plus the metadata the
  typed layer and support conversations need.

  `TypeSafeAPI.HTTP.post/4` and `get/3` return only the body, which is enough for
  most raw callers. `TypeSafeAPI.HTTP.request/5` returns this struct so callers
  can also read the status, headers, and the `x-typesafe-request-id` header
  that TypeSafe support asks for.

  The same metadata is on `TypeSafeAPI.Error` for the calls that failed, so
  "which request was this and how many retries did it burn" is answerable
  either way.

  `body` is the decoded JSON object. A 2xx with no body at all (a 204, or an
  empty 200) decodes to `%{}` rather than an error: the call succeeded and
  there was simply nothing to read.

  Only `status` and `body` are required, so a hand-built response in a test
  needs just those two:

      %TypeSafeAPI.HTTP.Response{status: 200, body: %{"answers" => %{}}}
  """

  @type t :: %__MODULE__{
          status: pos_integer(),
          body: map(),
          headers: %{String.t() => [String.t()]},
          request_id: String.t() | nil,
          retry_count: non_neg_integer()
        }

  @enforce_keys [:status, :body]
  defstruct [:status, :body, :request_id, headers: %{}, retry_count: 0]

  @doc """
  The first value of a response header, trimmed, or `nil`.

  Header names are lowercase. Saves callers from knowing that `Req` stores
  headers as `%{name => [value]}`.

      TypeSafeAPI.HTTP.Response.first_header(response, "x-typesafe-request-id")
  """
  @spec first_header(t(), String.t()) :: String.t() | nil
  def first_header(%__MODULE__{headers: headers}, name) when is_binary(name) do
    case Map.get(headers, String.downcase(name)) do
      [value | _] -> String.trim(value)
      _ -> nil
    end
  end
end
