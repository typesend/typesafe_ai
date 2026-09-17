defmodule TypeSafe.Question.Score do
  @moduledoc """
  Rate the state along an ordered scale you describe in steps.

      TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])

  TypeSafe's advice: ask for one snap judgment per question, and write the
  levels in order from low to high, two at minimum and ten at most.

  `levels` is an ordered list from the low end of the scale to the high end.
  The API needs at least two levels and accepts up to ten. Each level is a
  description: a string, or a map or list when a level needs structure.

  A level may also be given as `{label, description}`. The label is a short
  name you want back in the answer (`TypeSafe.Answer.Score.label`), and the
  pair is sent to the API as a structured level:

      {"Very angry", "Threats to cancel, profanity, all caps"}
      #=> {"label": "Very angry", "description": "Threats to cancel, ..."}

  Every level has a string label in the answer. A plain string level is its
  own label; a structured level without one gets a truncated `inspect/1` of
  itself, which is fine for logs but not for display, so give structured
  levels a label when the label matters.
  """

  alias TypeSafe.Question

  @min_levels 2
  @max_levels 10

  @type level :: Question.description() | {String.t(), Question.description()}

  @type t :: %__MODULE__{
          instructions: Question.description(),
          levels: [level()]
        }

  @enforce_keys [:instructions, :levels]
  defstruct [:instructions, :levels]

  @wire_type "score"

  @doc "The `type` tag this question and its answer carry on the wire."
  @spec wire_type() :: String.t()
  def wire_type, do: @wire_type

  @doc "Builds a Score question."
  @spec new(Question.description(), [level()]) :: t()
  def new(instructions, levels) when is_list(levels) do
    %__MODULE__{instructions: instructions, levels: levels}
  end

  @label_limit 60

  @doc """
  The string label for a level: the label of a `{label, description}` pair,
  a string level itself, or a truncated `inspect/1` of a structured level.
  """
  @spec label(level()) :: String.t()
  def label({label, _description}) when is_binary(label), do: label
  def label(description) when is_binary(description), do: description

  def label(description) do
    case inspect(description, limit: 10, printable_limit: @label_limit) do
      text when byte_size(text) <= @label_limit -> text
      text -> String.slice(text, 0, @label_limit - 3) <> "..."
    end
  end

  @doc "The description sent to the API for a level, without any label wrapper."
  @spec description(level()) :: Question.description()
  def description({_label, description}), do: description
  def description(description), do: description

  @doc false
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{instructions: instructions, levels: levels}) do
    with :ok <- Question.validate_description(instructions, "instructions"),
         :ok <- validate_count(levels) do
      validate_levels(levels)
    end
  end

  defp validate_count(levels) when is_list(levels) do
    count = length(levels)

    cond do
      count < @min_levels -> {:error, "Score needs at least #{@min_levels} levels, got #{count}"}
      count > @max_levels -> {:error, "Score allows at most #{@max_levels} levels, got #{count}"}
      true -> :ok
    end
  end

  defp validate_count(other), do: {:error, "Score levels must be a list, got: #{inspect(other)}"}

  defp validate_levels(levels) do
    levels
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {{label, description}, index}, :ok when is_binary(label) ->
        continue(Question.validate_description(description, "levels[#{index}]"))

      {{_label, _description} = pair, _index}, :ok ->
        {:halt, {:error, "Score level labels must be strings, got: #{inspect(pair)}"}}

      {description, index}, :ok ->
        continue(Question.validate_description(description, "levels[#{index}]"))
    end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  @doc false
  @spec encode(t()) :: map()
  def encode(%__MODULE__{instructions: instructions, levels: levels}) do
    %{
      "type" => @wire_type,
      "instructions" => instructions,
      "criteria" => Enum.map(levels, &encode_level/1)
    }
  end

  defp encode_level({label, description}), do: %{"label" => label, "description" => description}
  defp encode_level(description), do: description
end
