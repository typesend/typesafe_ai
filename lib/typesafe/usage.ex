defmodule TypeSafe.Usage do
  @moduledoc """
  Token counts for one call, when the API reports them.

  The official SDKs treat `input_tokens`/`output_tokens` as optional: the
  wire `usage` object may leave either out, or send it as `null`. This module
  mirrors that instead of raising, so a caller who doesn't track usage never
  has to think about it, and a caller who does gets `nil` instead of a crash.
  """

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil
        }

  defstruct input_tokens: nil, output_tokens: nil

  @doc """
  Decodes the wire `usage` object. A missing map, or a token count that isn't
  a non-negative integer, decodes to `nil` for that field rather than failing.
  """
  @spec decode(map() | nil) :: t()
  def decode(nil), do: %__MODULE__{}

  def decode(usage) when is_map(usage) do
    %__MODULE__{
      input_tokens: token(usage, "input_tokens"),
      output_tokens: token(usage, "output_tokens")
    }
  end

  defp token(usage, key) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end
end
