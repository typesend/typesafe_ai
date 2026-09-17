defmodule TypeSafeAPI.Answer.Score do
  @moduledoc """
  A decoded Score answer: a point on the scale, plus enough structure to use
  it without hand-decoding probabilities yourself.

  ## `score` and `level` are two different readings

  `score` is the API's probability-weighted average of the level indices — an
  expected value, so it is usually not a whole number. `level` is the argmax of
  `probabilities`, the single most likely level (the lowest index wins a tie).
  They can disagree, and the disagreement is information: a bimodal answer with
  0.5 on level 0 and 0.5 on level 2 has `score` 1.0 and `level` 0, because no
  probability mass sits on the middle at all.

  Use `score` (or `normalized/1`) when you are averaging, thresholding or
  feeding a weighted sum — anything that wants a magnitude. Use `level`,
  `label` and `description` when you are branching, routing or displaying a
  single level, and read `levels` when the shape of the distribution matters.
  Do not use `round(score)` as a level: it is not guaranteed to equal `level`.

  ## Fields

  `label` is always a string and comes from the *question*'s levels
  (`TypeSafeAPI.Question.Score.label/1`), not from the wire `legend`, so it is
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

  ## What decoding rejects

  Probabilities are validated against the question, so a `level` can never be
  read off a scale the caller did not send:

    * a probability or legend key outside `0..n-1` for an `n`-level question
      is an `:unexpected` error, rather than being dropped from `levels` and
      hidden from the argmax
    * a probability that is not a number is an `:unexpected` error; numbers are
      floated, so an integer `1` on the wire decodes to `1.0`
    * an empty `probabilities` object is an `:unexpected` error, because a
      missing distribution would otherwise argmax to level 0 and report the
      lowest label with full confidence
    * a `legend` whose labels disagree with the question's own levels is an
      `:unexpected` error naming both, since the label would then describe a
      different scale from the one the model was shown

  A level the response simply left out is filled in as 0.0 rather than
  rejected, so a response that reports only the levels with mass still decodes.
  """

  alias TypeSafeAPI.Keys

  @type t :: %__MODULE__{
          id: Keys.key(),
          score: float(),
          level: non_neg_integer(),
          label: String.t(),
          description: TypeSafeAPI.Question.description(),
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
