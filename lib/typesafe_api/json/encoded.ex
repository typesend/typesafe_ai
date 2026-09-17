defmodule TypeSafeAPI.JSON.Encoded do
  @moduledoc """
  A value that has already been serialized to JSON iodata, and encodes as
  those bytes wherever it appears.

  `TypeSafeAPI.evaluate_many/4` sends one question set with many states. Keeping
  the questions as a `TypeSafeAPI.JSON.OrderedObject` would mean walking and
  serializing the whole set once per request; wrapping it here serializes it
  once, and every request body splices the same iodata in.

      encoded = TypeSafeAPI.JSON.Encoded.new(TypeSafeAPI.JSON.OrderedObject.new([{"a", 1}]))
      JSON.encode!(%{"questions" => encoded})
      #=> ~s({"questions":{"a":1}})

  The original term is kept in `object` so callers can still read the
  structure. The two are captured together at construction and never diverge,
  because nothing modifies the struct afterwards.
  """

  @type t :: %__MODULE__{object: term(), iodata: iodata()}

  @enforce_keys [:object, :iodata]
  defstruct [:object, :iodata]

  @doc "Serializes `object` once and wraps it with its bytes."
  @spec new(term()) :: t()
  def new(object) do
    %__MODULE__{object: object, iodata: JSON.encode_to_iodata!(object)}
  end

  @doc "The term that was encoded."
  @spec object(t()) :: term()
  def object(%__MODULE__{object: object}), do: object

  @doc "The cached JSON bytes, as a binary."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{iodata: iodata}), do: IO.iodata_to_binary(iodata)

  defimpl JSON.Encoder do
    def encode(%{iodata: iodata}, _encoder), do: iodata
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{iodata: iodata}, opts) do
      concat(["#TypeSafeAPI.JSON.Encoded<", to_doc(IO.iodata_to_binary(iodata), opts), ">"])
    end
  end
end
