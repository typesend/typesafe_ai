defmodule TypeSafe.HTTP.Response do
  @moduledoc """
  A successful raw response: the decoded JSON body plus the metadata the
  typed layer and support conversations need.

  `TypeSafe.HTTP.post/4` and `get/3` return only the body, which is enough for
  most raw callers. `TypeSafe.HTTP.request/5` returns this struct so callers
  can also read the status, headers, and the `x-typesafe-request-id` header
  that TypeSafe support asks for.
  """

  @type t :: %__MODULE__{
          status: pos_integer(),
          body: map(),
          headers: %{String.t() => [String.t()]},
          request_id: String.t() | nil,
          retry_count: non_neg_integer()
        }

  @enforce_keys [:status, :body, :headers, :request_id, :retry_count]
  defstruct [:status, :body, :headers, :request_id, :retry_count]
end
