defmodule TypeSafe.SystemOne.Prepared do
  @moduledoc """
  A question set that has been validated, encoded, and had its caller keys
  recorded, ready to send with any number of states.

  Doing this work once is what makes `TypeSafe.evaluate_many/4` cheap: the
  validation, the wire encoding and the `TypeSafe.Keys` registry are identical
  for every state, so they are built once and shared across tasks. It is a
  struct rather than a bare map so the functions that take one can match on
  it and fail loudly when handed something else.
  """

  alias TypeSafe.JSON.OrderedObject
  alias TypeSafe.{Keys, Question}

  @type t :: %__MODULE__{
          questions: [{Keys.key(), Question.t()}],
          count: pos_integer(),
          encoded: OrderedObject.t(),
          keys: Keys.t()
        }

  @enforce_keys [:questions, :count, :encoded, :keys]
  defstruct [:questions, :count, :encoded, :keys]
end
