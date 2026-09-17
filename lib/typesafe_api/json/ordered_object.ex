defmodule TypeSafeAPI.JSON.OrderedObject do
  @moduledoc """
  A JSON object that encodes its pairs in the order given.

  Elixir maps do not preserve insertion order at any size. The API treats a
  Choice question's `criteria` as an ordered list of options (the order is
  what the model sees), so Choice criteria travel as this struct rather than
  as a map.

      JSON.encode!(%TypeSafeAPI.JSON.OrderedObject{pairs: [{"b", 1}, {"a", nil}]})
      #=> ~s({"b":1,"a":null})

  Keys must be atoms or strings, and `new/1` says so at construction rather
  than letting a bad key surface from inside the encoder at request time.
  Values may be anything `JSON` can encode.

  ## It is not a map

  This is a struct, so `is_map/1` returns `true` for it and `map_size/1`
  returns its field count, not its pair count. Anything that inspects a wire
  object generically should use `Enum` instead: the struct implements
  `Enumerable` over its `{key, value}` pairs, so `Enum.count/1`,
  `Enum.map/2` and `Enum.into/2` all work and see the pairs in order.

      object = TypeSafeAPI.JSON.OrderedObject.new([{"b", 1}, {"a", 2}])
      Enum.count(object)   #=> 2
      Enum.into(object, %{}) #=> %{"a" => 2, "b" => 1}
  """

  @type t :: %__MODULE__{pairs: [{atom() | String.t(), term()}]}

  @enforce_keys [:pairs]
  defstruct [:pairs]

  @doc """
  Wraps a list of `{key, value}` pairs.

  Raises `ArgumentError` for an element that is not a two-element tuple, or a
  key that is not an atom or a string.
  """
  @spec new([{atom() | String.t(), term()}]) :: t()
  def new(pairs) when is_list(pairs), do: %__MODULE__{pairs: Enum.map(pairs, &pair!/1)}

  defp pair!({key, _value} = pair) when is_binary(key) or (is_atom(key) and not is_nil(key)) do
    pair
  end

  defp pair!({key, _value}) do
    raise ArgumentError,
          "TypeSafeAPI.JSON.OrderedObject keys must be atoms or strings, got: #{inspect(key)}"
  end

  defp pair!(other) do
    raise ArgumentError,
          "TypeSafeAPI.JSON.OrderedObject takes {key, value} pairs, got: #{inspect(other)}"
  end

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

  defimpl Enumerable do
    def count(%{pairs: pairs}), do: {:ok, length(pairs)}

    def member?(%{pairs: pairs}, {_key, _value} = pair), do: {:ok, pair in pairs}
    def member?(_object, _other), do: {:ok, false}

    def reduce(%{pairs: pairs}, acc, fun), do: Enumerable.reduce(pairs, acc, fun)

    # Pairs are a linked list, so there is no cheaper way in than walking it;
    # `{:error, __MODULE__}` tells `Enum` to fall back to `reduce/3`.
    def slice(_object), do: {:error, __MODULE__}
  end
end
