defmodule TypeSafe.JSON.OrderedObject do
  @moduledoc """
  A JSON object that encodes its pairs in the order given.

  Elixir maps with more than 32 keys do not preserve insertion order, and a
  Choice question can carry up to 255 options. The API treats `criteria` as an
  ordered list of options (the order is what the model sees), so Choice
  criteria travel as this struct rather than as a map.

      JSON.encode!(%TypeSafe.JSON.OrderedObject{pairs: [{"b", 1}, {"a", nil}]})
      #=> ~s({"b":1,"a":null})

  Keys must be atoms or strings. Values may be anything `JSON` can encode.
  """

  @type t :: %__MODULE__{pairs: [{atom() | String.t(), term()}]}

  @enforce_keys [:pairs]
  defstruct [:pairs]

  @doc "Wraps a list of `{key, value}` pairs."
  @spec new([{atom() | String.t(), term()}]) :: t()
  def new(pairs) when is_list(pairs), do: %__MODULE__{pairs: pairs}

  defimpl JSON.Encoder do
    def encode(%{pairs: []}, _encoder), do: "{}"

    def encode(%{pairs: pairs}, encoder) do
      encoded =
        Enum.map_intersperse(pairs, ?,, fn {key, value} ->
          [encode_key(key, encoder), ?:, encoder.(value, encoder)]
        end)

      [?{, encoded, ?}]
    end

    defp encode_key(key, encoder) when is_binary(key), do: encoder.(key, encoder)

    defp encode_key(key, encoder) when is_atom(key) and not is_nil(key) do
      encoder.(Atom.to_string(key), encoder)
    end
  end
end
