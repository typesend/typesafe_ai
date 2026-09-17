defmodule TypeSafeAPI.Question.Choice do
  @moduledoc """
  Pick one option from a set you define.

      TypeSafeAPI.choice("Which team should handle this?",
        billing: "Payments, invoicing, refunds",
        technical: "Bugs, outages, integrations",
        sales: nil
      )

  Criteria are an ordered list of `{key, description}` pairs — a keyword list
  or a list of pairs — never a map: the order is what the model sees, and
  Elixir maps have no order to preserve.
  Keys may be atoms or strings; the answer comes back under the same kind.
  A bare list of option names is accepted too, and each name becomes an option
  with no description:

      TypeSafeAPI.choice("Which team?", [:billing, :sales])
      # same as
      TypeSafeAPI.choice("Which team?", billing: nil, sales: nil)

  Give a Choice the full list rather than a shortlist, and add an `other`
  option when the list might not cover every input.

  `instructions` is optional; only `criteria` and the type are required. Pass
  `nil` for a Choice whose options speak for themselves.

  ## `nil` descriptions

  A `nil` option description means the option name speaks for itself, and it
  travels as JSON `null`: `sales: nil` is sent as `"sales":null`. This is the
  one place the library sends a `null` rather than omitting the key — a JSON
  object key must carry some value, and the spec's `ChoiceQuestion.criteria`
  allows `null` explicitly. A `nil` *instructions*, by contrast, is left out of
  the request entirely.

  ## Limits

  | limit        | our validator | spec (`priv/openapi.json`, API 0.2.0)       | source |
  | ------------ | -------------- | -------------------------------------------- | ------ |
  | min options  | 1              | no bound (`criteria` is an unconstrained object) | local policy: an empty option set asks nothing |
  | max options  | 255            | no bound                                      | local policy, matching a live-API 400 observed at 256 (see `DESIGN.md`) |

  `ChoiceQuestion.criteria` in the OpenAPI spec has no `minProperties` or
  `maxProperties` at all; both bounds here are this library's own policy, not
  something read off the spec. A single-option Choice is a degenerate question
  but a well-defined one, and criteria built at runtime can legitimately filter
  down to one survivor, so only the empty set is rejected.
  """

  alias TypeSafeAPI.{JSON.OrderedObject, Keys, Question}

  @min_options 1
  @max_options 255

  @type option :: {Keys.key(), Question.description() | nil}

  @type t :: %__MODULE__{
          instructions: Question.instructions(),
          criteria: [option()]
        }

  @enforce_keys [:criteria]
  defstruct [:criteria, instructions: nil]

  @wire_type "choice"

  @doc "The `type` tag this question and its answer carry on the wire."
  @spec wire_type() :: String.t()
  def wire_type, do: @wire_type

  @doc """
  Builds a Choice question from a keyword list, a list of `{key, description}`
  pairs, or a bare list of option names.

  A bare name is normalized to `{name, nil}`, so
  `new("Which?", [:billing, :sales])` and `new("Which?", billing: nil, sales: nil)`
  build the same question.

  Maps are not accepted: they have no order, and option order is what the
  model sees. `instructions` is optional and may be `nil`.
  """
  @spec new(Question.instructions(), [option() | Keys.key()]) :: t()
  def new(instructions, criteria) when is_list(criteria) do
    %__MODULE__{instructions: instructions, criteria: Enum.map(criteria, &option/1)}
  end

  def new(_instructions, criteria) when is_map(criteria) do
    raise ArgumentError,
          "Choice criteria must be a keyword list or list of {key, description} pairs, " <>
            "not a map: a map has no order, and option order is what the model sees"
  end

  defp option({_key, _description} = pair), do: pair

  defp option(key) when (is_atom(key) and not is_nil(key)) or is_binary(key), do: {key, nil}

  defp option(other), do: other

  @doc false
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{instructions: instructions, criteria: criteria}) do
    with :ok <- Question.validate_description(instructions, "instructions", allow_nil: true),
         :ok <- validate_count(criteria),
         :ok <- validate_options(criteria) do
      validate_unique(criteria)
    end
  end

  defp validate_count(list) when is_list(list) do
    case length(list) do
      count when count < @min_options ->
        {:error, "Choice needs at least #{@min_options} option, got #{count}"}

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

    Question.put_instructions(
      %{"type" => @wire_type, "criteria" => OrderedObject.new(pairs)},
      instructions
    )
  end
end
