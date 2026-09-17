defmodule TypeSafeAPI.SystemOne.Prepared do
  @moduledoc """
  A question set that has been validated, encoded, and had its caller keys
  recorded, ready to send with any number of states.

  Doing this work once is what makes `TypeSafeAPI.evaluate_many/4` cheap: the
  validation, the wire encoding and the `TypeSafeAPI.Keys` registry are identical
  for every state, so they are built once and shared across tasks. `encoded`
  holds JSON bytes, not a term to be serialized again, so a request body is a
  splice of the cached iodata rather than another walk of the question set. It
  is a struct rather than a bare map so the functions that take one can match
  on it and fail loudly when handed something else.

  ## Do not modify one by hand

  `count`, `encoded` and `keys` are all derived from `questions` when the
  struct is built, and nothing revalidates them afterwards.
  `%{prepared | questions: other_questions}` compiles and still matches every
  `%Prepared{}` guard, but it sends the *old* questions on the wire and decodes
  the answers under a stale key registry. Build a new one with
  `TypeSafeAPI.prepare/1` instead.
  """

  alias TypeSafeAPI.JSON.Encoded
  alias TypeSafeAPI.{Keys, Question}

  @type t :: %__MODULE__{
          questions: [{Keys.key(), Question.t()}],
          count: pos_integer(),
          encoded: Encoded.t(),
          keys: Keys.t()
        }

  @enforce_keys [:questions, :count, :encoded, :keys]
  defstruct [:questions, :count, :encoded, :keys]

  @doc """
  Builds a prepared question set from an already normalized `[{id, question}]`
  list, deriving the count, the wire encoding and the key registry from it.

  `TypeSafeAPI.prepare/1` is the public entry point; it normalizes and validates
  first.
  """
  @spec new([{Keys.key(), Question.t()}]) :: t()
  def new(questions) when is_list(questions) do
    %__MODULE__{
      questions: questions,
      count: length(questions),
      encoded: Question.encode_all(questions),
      keys: Keys.build(questions)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{questions: questions, count: count}, opts) do
      ids = Enum.map(questions, fn {id, _question} -> id end)

      concat([
        "#TypeSafeAPI.SystemOne.Prepared<count: ",
        Integer.to_string(count),
        ", ids: ",
        to_doc(ids, opts),
        ">"
      ])
    end
  end
end
