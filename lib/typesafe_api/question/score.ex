defmodule TypeSafeAPI.Question.Score do
  @moduledoc """
  Rate the state along an ordered scale you describe in steps.

      TypeSafeAPI.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])

  TypeSafe's advice: ask for one snap judgment per question, and write the
  levels in order from low to high; this library enforces two at minimum and
  ten at most as local policy (see "Limits" below).

  `levels` is an ordered list from the low end of the scale to the high end.
  This library requires at least two levels and caps a Score at ten: a single
  level cannot produce a meaningful score, and the live API rejects eleven
  levels with a 400 (see `DESIGN.md`). Each level is a description: a string,
  or a map or list when a level needs structure.

  A level may also be given as `{label, description}`. The label is a short
  name you want back in the answer (`TypeSafeAPI.Answer.Score.label`), and the
  pair is sent to the API as a structured level:

      {"Very angry", "Threats to cancel, profanity, all caps"}
      #=> {"label": "Very angry", "description": "Threats to cancel, ..."}

  The same structured shape written out by hand,
  `%{"label" => "Very angry", "description" => "..."}`, is recognized as a
  labelled level too, so a level that round-trips through the wire `legend`
  still reports its label rather than an `inspect/1` of the map.

  Labels are strings. Atom labels — `[calm: "...", angry: "..."]`, the shape
  `TypeSafeAPI.choice/2` takes — are not accepted yet; write the label as a
  string for now.

  Every level has a string label in the answer. A plain string level is its
  own label; a structured level without one gets a truncated `inspect/1` of
  itself, which is fine for logs but not for display, so give structured
  levels a label when the label matters. Labels must be distinct and non-empty:
  the answer's `levels` list is keyed by label, so two levels sharing one name
  cannot be told apart.

  ## Limits

  | limit      | our validator | spec (`priv/openapi.json`, API 0.2.0)  | source |
  | ---------- | -------------- | ---------------------------------------- | ------ |
  | min levels | 2              | `minItems: 1`                            | local policy: a one-level score is meaningless |
  | max levels | 10             | no bound                                  | local policy, matching a live-API 400 observed at 11 (see `DESIGN.md`) |

  `ScoreQuestion.criteria` in the OpenAPI spec requires only `minItems: 1` and
  sets no maximum; both bounds here are this library's own policy, tighter
  than what the spec itself requires.
  """

  alias TypeSafeAPI.Question

  @min_levels 2
  @max_levels 10

  @type level :: Question.description() | {String.t(), Question.description()}

  @type t :: %__MODULE__{
          instructions: Question.instructions(),
          levels: [level()]
        }

  @enforce_keys [:levels]
  defstruct [:levels, instructions: nil]

  @wire_type "score"

  @doc "The `type` tag this question and its answer carry on the wire."
  @spec wire_type() :: String.t()
  def wire_type, do: @wire_type

  @doc """
  Builds a Score question.

  `instructions` is optional and may be `nil`; only the levels are required.
  """
  @spec new(Question.instructions(), [level()]) :: t()
  def new(instructions, levels) when is_list(levels) do
    %__MODULE__{instructions: instructions, levels: levels}
  end

  @label_limit 60

  @doc """
  The string label for a level: the label of a `{label, description}` pair or
  of a `%{"label" => ...}` map, a string level itself, or a truncated
  `inspect/1` of any other structured level.
  """
  @spec label(level()) :: String.t()
  def label({label, _description}) when is_binary(label), do: label
  def label(description) when is_binary(description), do: description
  def label(%{"label" => label}) when is_binary(label), do: label

  def label(description) do
    case inspect(description, limit: 10, printable_limit: @label_limit) do
      text when byte_size(text) <= @label_limit -> text
      text -> String.slice(text, 0, @label_limit - 3) <> "..."
    end
  end

  @doc "The description sent to the API for a level, without any label wrapper."
  @spec description(level()) :: Question.description()
  def description({_label, description}), do: description

  def description(%{"label" => label, "description" => description}) when is_binary(label),
    do: description

  def description(description), do: description

  @doc false
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{instructions: instructions, levels: levels}) do
    with :ok <- Question.validate_description(instructions, "instructions", allow_nil: true),
         :ok <- validate_count(levels),
         :ok <- validate_levels(levels) do
      validate_labels(levels)
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

  # Answers key their `levels` list by label, so two levels with the same name
  # (or an empty one) would be indistinguishable in the result.
  defp validate_labels(levels) do
    labels = levels |> Enum.map(&explicit_label/1) |> Enum.reject(&is_nil/1)

    with :ok <- validate_labels_present(labels), do: validate_labels_unique(labels)
  end

  defp validate_labels_present(labels) do
    if "" in labels do
      {:error, "Score level labels must not be empty"}
    else
      :ok
    end
  end

  defp validate_labels_unique(labels) do
    case labels -- Enum.uniq(labels) do
      [] -> :ok
      [dup | _] -> {:error, "Score level label #{inspect(dup)} is given more than once"}
    end
  end

  defp explicit_label({label, _description}) when is_binary(label), do: label
  defp explicit_label(label) when is_binary(label), do: label
  defp explicit_label(%{"label" => label}) when is_binary(label), do: label
  defp explicit_label(_other), do: nil

  @doc false
  @spec encode(t()) :: map()
  def encode(%__MODULE__{instructions: instructions, levels: levels}) do
    Question.put_instructions(
      %{"type" => @wire_type, "criteria" => Enum.map(levels, &encode_level/1)},
      instructions
    )
  end

  defp encode_level({label, description}), do: %{"label" => label, "description" => description}
  defp encode_level(description), do: description
end
