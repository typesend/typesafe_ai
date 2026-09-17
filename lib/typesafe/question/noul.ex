defmodule TypeSafe.Question.Noul do
  @moduledoc """
  A yes/no question. The answer is the probability that the answer is yes.

      TypeSafe.noul("Does this convey urgency?",
        true: "Explicitly time-sensitive",
        false: "No urgency expressed"
      )

  TypeSafe's advice: ask for one snap judgment per question. If the
  instructions need an "and" or a "but", split them into two Nouls.

  `criteria` is optional. When given, it describes what a yes and a no mean;
  either description may be a string, map, or list (the API accepts JSON
  structure everywhere a description goes).
  """

  alias TypeSafe.Question

  @type t :: %__MODULE__{
          instructions: Question.description(),
          criteria:
            %{optional(true) => Question.description(), optional(false) => Question.description()}
            | nil
        }

  @enforce_keys [:instructions]
  defstruct [:instructions, criteria: nil]

  @wire_type "noul"

  @doc "The `type` tag this question and its answer carry on the wire."
  @spec wire_type() :: String.t()
  def wire_type, do: @wire_type

  @doc """
  Builds a Noul question.

  ## Options

    * `:true` - what a yes (value near 1) means
    * `:false` - what a no (value near 0) means

  Like every constructor here, `new/2` does not validate; a misspelled key is
  reported as a `:validation` error by `TypeSafe.evaluate/4`, or raised by
  `TypeSafe.Question.validate!/1` when you want to fail early.
  """
  @spec new(Question.description(), keyword() | map()) :: t()
  def new(instructions, criteria \\ []) when is_list(criteria) or is_map(criteria) do
    criteria = Map.new(criteria)
    %__MODULE__{instructions: instructions, criteria: if(criteria == %{}, do: nil, else: criteria)}
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{instructions: instructions, criteria: criteria}) do
    with :ok <- Question.validate_description(instructions, "instructions") do
      validate_criteria(criteria)
    end
  end

  defp validate_criteria(nil), do: :ok

  defp validate_criteria(criteria) when is_map(criteria) do
    Enum.reduce_while(criteria, :ok, fn
      {key, description}, :ok when key in [true, false] ->
        case Question.validate_description(description, "criteria.#{key}") do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {key, _}, :ok ->
        {:halt, {:error, "Noul criteria keys must be true or false, got: #{inspect(key)}"}}
    end)
  end

  defp validate_criteria(other) do
    {:error, "Noul criteria must be a map with true/false keys, got: #{inspect(other)}"}
  end

  @doc false
  @spec encode(t()) :: map()
  def encode(%__MODULE__{instructions: instructions, criteria: nil}) do
    %{"type" => @wire_type, "instructions" => instructions}
  end

  def encode(%__MODULE__{instructions: instructions, criteria: criteria}) do
    %{
      "type" => @wire_type,
      "instructions" => instructions,
      "criteria" =>
        Map.new(criteria, fn {key, description} -> {Atom.to_string(key), description} end)
    }
  end
end
