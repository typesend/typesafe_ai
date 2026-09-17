defmodule TypeSafe.Answer.Score do
  @moduledoc """
  A decoded Score answer: a point on the scale, plus enough structure to use
  it without hand-decoding probabilities yourself.

  `level` is the argmax of `probabilities` (the lowest index wins a tie).
  `label` is always a string and comes from the *question*'s levels
  (`TypeSafe.Question.Score.label/1`), not from the wire `legend`, so it is
  still meaningful when the caller never reads `legend` at all. `description`
  is the winning level exactly as it was written in the question, structure
  and all. `levels` pairs every question level's label, in order, with its
  probability, 0.0 for a level the wire response left out.

  `legend` is the API's own copy of the levels you sent, keyed by level index
  (the string keys of the wire object, parsed back to integers). A plain
  string level comes back as that string; a structured level comes back as it
  was sent, so a `{label, description}` pair reads as a map with `"label"` and
  `"description"`. It is there for display and for logging what the model was
  actually shown; `label`, `description` and `levels` already give you the
  same information keyed the way you wrote the question.
  """

  alias TypeSafe.Keys

  @type t :: %__MODULE__{
          id: Keys.key(),
          score: float(),
          level: non_neg_integer(),
          label: String.t(),
          description: TypeSafe.Question.description(),
          levels: [{String.t(), float()}],
          probabilities: %{non_neg_integer() => float()},
          legend: %{non_neg_integer() => term()},
          confidence: float()
        }

  @enforce_keys [
    :id,
    :score,
    :level,
    :label,
    :description,
    :levels,
    :probabilities,
    :legend,
    :confidence
  ]
  defstruct [
    :id,
    :score,
    :level,
    :label,
    :description,
    :levels,
    :probabilities,
    :legend,
    :confidence
  ]

  @doc """
  The score scaled to `0.0..1.0` by dividing by the top level index, so scales
  with different numbers of levels can be weighted against each other (see
  the composite scoring guide). A single-level scale is undefined and returns `0.0`.

  This assumes `score` lies between 0 and the top level index, which is what
  the API guarantees. The division is done as given, with no clamping, so a
  response outside that range produces a value outside `0.0..1.0` instead of
  an error. Clamp it yourself if you are feeding the number into something
  that cannot tolerate that.
  """
  @spec normalized(t()) :: float()
  def normalized(%__MODULE__{score: score, levels: levels}) do
    case length(levels) - 1 do
      top when top > 0 -> score / top
      _ -> 0.0
    end
  end
end
