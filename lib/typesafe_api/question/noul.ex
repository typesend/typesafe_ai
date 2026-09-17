defmodule TypeSafeAPI.Question.Noul do
  @moduledoc """
  A yes/no judgment. The instructions may be a question ("Does this convey
  urgency?") or a statement to evaluate ("This message contains unsolicited
  advertising."); the answer is the probability that the answer is yes, or
  that the statement holds.

      TypeSafeAPI.noul("Does this convey urgency?",
        true: "Explicitly time-sensitive",
        false: "No urgency expressed"
      )

  TypeSafe's advice: ask for one snap judgment per question. If the
  instructions need an "and" or a "but", split them into two Nouls.

  Both `instructions` and `criteria` are optional; the API requires only the
  question's type. `criteria`, when given, describes what a yes and a no mean;
  either description may be a string, map, or list (the API accepts JSON
  structure everywhere a description goes), or `nil` when that side of the
  judgment speaks for itself.

  The criteria keys may be the atoms `true`/`false` or the strings
  `"true"`/`"false"` (the shape the API itself uses); both are normalized to
  atoms by `new/2` and reach the wire as the JSON keys `"true"` and `"false"`.

  `TypeSafeAPI.noul()` builds a Noul with neither instructions nor criteria. It is
  a valid request — the API requires only the type — but it asks the model
  nothing in particular, so it is almost never what you want. Criteria alone
  are enough, though: `TypeSafeAPI.noul(true: "spam", false: "legitimate")` reads
  the keyword list as criteria rather than as instructions.
  """

  alias TypeSafeAPI.Question

  @type t :: %__MODULE__{
          instructions: Question.instructions(),
          criteria:
            %{optional(true) => Question.description(), optional(false) => Question.description()}
            | nil
        }

  defstruct instructions: nil, criteria: nil

  @wire_type "noul"

  @doc "The `type` tag this question and its answer carry on the wire."
  @spec wire_type() :: String.t()
  def wire_type, do: @wire_type

  @doc """
  Builds a Noul question.

  `instructions` is optional and may be omitted or `nil`, which sends a Noul
  carrying only its type (and its criteria, if any).

  ## Options

    * `:true` - what a yes (value near 1) means
    * `:false` - what a no (value near 0) means

  Either key may also be given as the string `"true"` or `"false"`; both forms
  are normalized to atoms. A `nil` description means that side speaks for
  itself.

  When `criteria` is omitted and `instructions` is a keyword list whose keys
  are only `true` and `false`, it is read as the criteria — so
  `new(true: "yes", false: "no")` means what it looks like, rather than binding
  a keyword list to `instructions`.

  Like every constructor here, `new/2` does not validate; a misspelled key is
  reported as a `:validation` error by `TypeSafeAPI.evaluate/4`, or raised by
  `TypeSafeAPI.Question.validate!/1` when you want to fail early.
  """
  @spec new(Question.instructions() | keyword(), keyword() | map() | nil) :: t()
  def new(instructions \\ nil, criteria \\ nil)

  def new(instructions, nil) do
    if criteria_only?(instructions) do
      build(nil, instructions)
    else
      build(instructions, [])
    end
  end

  def new(instructions, criteria) when is_list(criteria) or is_map(criteria) do
    build(instructions, criteria)
  end

  defp build(instructions, criteria) do
    criteria = Map.new(criteria, fn {key, description} -> {criteria_key(key), description} end)

    %__MODULE__{instructions: instructions, criteria: if(criteria == %{}, do: nil, else: criteria)}
  end

  defp criteria_only?([_ | _] = list) do
    Enum.all?(list, fn
      {key, _description} -> key in [true, false, "true", "false"]
      _other -> false
    end)
  end

  defp criteria_only?(_other), do: false

  defp criteria_key("true"), do: true
  defp criteria_key("false"), do: false
  defp criteria_key(key), do: key

  @doc false
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{instructions: instructions, criteria: criteria}) do
    with :ok <- Question.validate_description(instructions, "instructions", allow_nil: true) do
      validate_criteria(criteria)
    end
  end

  defp validate_criteria(nil), do: :ok

  defp validate_criteria(criteria)
       when is_list(criteria) or (is_map(criteria) and not is_struct(criteria)) do
    Enum.reduce_while(criteria, :ok, fn
      {key, description}, :ok when key in [true, false, "true", "false"] ->
        case Question.validate_description(description, "criteria.#{key}", allow_nil: true) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      {key, _description}, :ok ->
        {:halt, {:error, "Noul criteria keys must be true or false, got: #{inspect(key)}"}}

      other, :ok ->
        {:halt,
         {:error, "Noul criteria must be {true | false, description} pairs, got: #{inspect(other)}"}}
    end)
  end

  defp validate_criteria(other) do
    {:error, "Noul criteria must be a map with true/false keys, got: #{inspect(other)}"}
  end

  @doc false
  @spec encode(t()) :: map()
  def encode(%__MODULE__{instructions: instructions, criteria: nil}) do
    Question.put_instructions(%{"type" => @wire_type}, instructions)
  end

  def encode(%__MODULE__{instructions: instructions, criteria: criteria}) do
    criteria = Map.new(criteria, fn {key, description} -> {wire_key(key), description} end)

    Question.put_instructions(
      %{"type" => @wire_type, "criteria" => criteria},
      instructions
    )
  end

  defp wire_key(true), do: "true"
  defp wire_key(false), do: "false"
  defp wire_key(key) when is_binary(key), do: key
end
