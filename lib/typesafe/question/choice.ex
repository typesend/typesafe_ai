defmodule TypeSafe.Question.Choice do
  @moduledoc """
  Pick one option from a set you define.

      TypeSafe.choice("Which team should handle this?",
        billing: "Payments, invoicing, refunds",
        technical: "Bugs, outages, integrations",
        sales: nil
      )

  Criteria are stored as an ordered list of `{key, description}` pairs, not a
  map. The order is what the model sees, and Elixir maps stop preserving
  insertion order past 32 keys while a Choice allows up to 255 options.
  Keys may be atoms or strings; the answer comes back under the same kind.
  A `nil` description means the option name speaks for itself. A Choice needs
  at least two options (one option is not a choice) and the API allows at
  most 255; give it the full list rather than a shortlist, and add
  an `other` option when the list might not cover every input.
  """

  alias TypeSafe.{JSON.OrderedObject, Keys, Question}

  @min_options 2
  @max_options 255

  @type option :: {Keys.key(), Question.description() | nil}

  @type t :: %__MODULE__{
          instructions: Question.description(),
          criteria: [option()]
        }

  @enforce_keys [:instructions, :criteria]
  defstruct [:instructions, :criteria]

  @wire_type "choice"

  @doc "The `type` tag this question and its answer carry on the wire."
  @spec wire_type() :: String.t()
  def wire_type, do: @wire_type

  @doc """
  Builds a Choice question from a keyword list, map, or list of pairs.

  A map is accepted for convenience only while it can preserve order: Elixir
  maps keep insertion order up to 32 entries, so a map with more than 32
  options raises `ArgumentError`. Pass a keyword list or a list of
  `{key, description}` pairs for larger option sets.
  """
  @max_map_options 32

  @spec new(Question.description(), [option()] | map()) :: t()
  def new(instructions, criteria) when is_list(criteria) do
    %__MODULE__{instructions: instructions, criteria: criteria}
  end

  def new(instructions, criteria)
      when is_map(criteria) and map_size(criteria) <= @max_map_options do
    %__MODULE__{instructions: instructions, criteria: Enum.to_list(criteria)}
  end

  def new(_instructions, criteria) when is_map(criteria) do
    raise ArgumentError,
          "a map with #{map_size(criteria)} options does not preserve order past " <>
            "#{@max_map_options} entries; pass a keyword list or list of {key, description} pairs"
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{instructions: instructions, criteria: criteria}) do
    with :ok <- Question.validate_description(instructions, "instructions"),
         :ok <- validate_count(criteria),
         :ok <- validate_options(criteria) do
      validate_unique(criteria)
    end
  end

  defp validate_count(list) when is_list(list) do
    case length(list) do
      count when count < @min_options ->
        {:error, "Choice needs at least #{@min_options} options, got #{count}"}

      count when count > @max_options ->
        {:error, "Choice allows at most #{@max_options} options, got #{count}"}

      _ ->
        :ok
    end
  end

  defp validate_count(other),
    do: {:error, "Choice criteria must be a list, got: #{inspect(other)}"}

  defp validate_options(criteria) do
    Enum.reduce_while(criteria, :ok, fn
      {key, description}, :ok when (is_atom(key) and not is_nil(key)) or is_binary(key) ->
        case Question.validate_description(description, "criteria.#{key}", allow_nil: true) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      other, :ok ->
        {:halt, {:error, "Choice options must be {key, description} pairs, got: #{inspect(other)}"}}
    end)
  end

  defp validate_unique(criteria) do
    wire_keys = Enum.map(criteria, fn {key, _} -> Keys.wire(key) end)

    case wire_keys -- Enum.uniq(wire_keys) do
      [] -> :ok
      [dup | _] -> {:error, "Choice option #{inspect(dup)} is given more than once"}
    end
  end

  @doc false
  @spec encode(t()) :: map()
  def encode(%__MODULE__{instructions: instructions, criteria: criteria}) do
    pairs = Enum.map(criteria, fn {key, description} -> {Keys.wire(key), description} end)
    %{"type" => @wire_type, "instructions" => instructions, "criteria" => OrderedObject.new(pairs)}
  end
end
