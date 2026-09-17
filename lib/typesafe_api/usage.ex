defmodule TypeSafeAPI.Usage do
  @moduledoc """
  Token counts for one call.

  The OpenAPI schema requires `usage` on every response, with `input_tokens`
  and `output_tokens` both required integers. This module still tolerates a
  missing, null or malformed count and reports it as `nil`, which is a
  defensive choice rather than something the spec permits: a complete, correct
  set of answers is not worth failing over a token count that drifted. When a
  count is `nil`, the API did not send a usable one.

  `total_tokens/1` and `add/2` treat `nil` as zero, so aggregating a batch
  (`TypeSafeAPI.evaluate_many/4`, a Broadway pipeline) never has to reinvent
  `|| 0`.
  """

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil
        }

  defstruct input_tokens: nil, output_tokens: nil

  @doc """
  Decodes the wire `usage` object.

  A missing object, or a token count that isn't a non-negative integer,
  decodes to `nil` for that field rather than failing.

      iex> TypeSafeAPI.Usage.decode(%{"input_tokens" => 312, "output_tokens" => 48})
      %TypeSafeAPI.Usage{input_tokens: 312, output_tokens: 48}

      iex> TypeSafeAPI.Usage.decode(nil)
      %TypeSafeAPI.Usage{input_tokens: nil, output_tokens: nil}
  """
  @spec decode(term()) :: t()
  def decode(usage) when is_map(usage) do
    %__MODULE__{
      input_tokens: token(usage, "input_tokens"),
      output_tokens: token(usage, "output_tokens")
    }
  end

  def decode(_other), do: %__MODULE__{}

  @doc """
  Input plus output tokens, counting a `nil` as zero.

      iex> TypeSafeAPI.Usage.total_tokens(%TypeSafeAPI.Usage{input_tokens: 312, output_tokens: 48})
      360

      iex> TypeSafeAPI.Usage.total_tokens(%TypeSafeAPI.Usage{})
      0
  """
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(%__MODULE__{input_tokens: input, output_tokens: output}) do
    zero(input) + zero(output)
  end

  @doc """
  Sums two usages field by field, counting a `nil` as zero.

  Made for folding a batch, where one call reporting no counts should not
  poison the total:

      iex> results = [%TypeSafeAPI.Usage{input_tokens: 10, output_tokens: 2},
      ...>            %TypeSafeAPI.Usage{input_tokens: 5}]
      iex> Enum.reduce(results, %TypeSafeAPI.Usage{}, &TypeSafeAPI.Usage.add/2)
      %TypeSafeAPI.Usage{input_tokens: 15, output_tokens: 2}

  The result's counts are always integers, never `nil`, so a sum cannot be
  mistaken for "the API sent nothing".
  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = left, %__MODULE__{} = right) do
    %__MODULE__{
      input_tokens: zero(left.input_tokens) + zero(right.input_tokens),
      output_tokens: zero(left.output_tokens) + zero(right.output_tokens)
    }
  end

  defp zero(nil), do: 0
  defp zero(count), do: count

  defp token(usage, key) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end
end
