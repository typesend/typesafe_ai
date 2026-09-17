defmodule TypeSafeAPI.Answer.Choice do
  @moduledoc """
  A decoded Choice answer: which option the model picked, and how sure it was
  about every option it was offered.

  `choice` and the keys of `probabilities` are restored through
  `TypeSafeAPI.Keys.option/3`, so they come back as atoms when the caller built
  the question with atom keys, and as strings when the caller used strings.

  Every option the question declared appears in `probabilities`, with 0.0 for
  one the response left out, so `probabilities[option]` is never `nil` for an
  option you sent. `options` is the same data as an ordered
  `[{key, probability}]` list in the question's own order, mirroring
  `TypeSafeAPI.Answer.Score`'s `levels`, so a ranked display does not have to
  re-sort against the criteria. `description` is the chosen option's
  description exactly as it was written in the question, or `nil` for an option
  whose name speaks for itself.

  Decoding is strict about agreement with the question: an option the caller
  never declared (in `choice` or in `probabilities`), a probability that is not
  a number, an empty `probabilities` object, or a `choice` that is not the
  highest-probability option is an `:unexpected` error. The API documents
  `choice` as the option with the highest probability, so a disagreement is a
  signal worth surfacing rather than a value worth passing on. A tie that
  includes the reported choice is fine.
  """

  alias TypeSafeAPI.{Keys, Question}

  @type t :: %__MODULE__{
          id: Keys.key(),
          choice: Keys.key(),
          description: Question.description() | nil,
          probabilities: %{Keys.key() => float()},
          options: [{Keys.key(), float()}],
          confidence: float()
        }

  @enforce_keys [:id, :choice, :description, :probabilities, :options, :confidence]
  defstruct [:id, :choice, :description, :probabilities, :options, :confidence]
end
