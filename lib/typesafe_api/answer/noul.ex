defmodule TypeSafeAPI.Answer.Noul do
  @moduledoc """
  A decoded Noul answer: the model's probability that the answer is yes.

  `noul` is between 0.0 and 1.0 — a response outside that range is rejected as
  an `:unexpected` error rather than clamped, so a malformed value cannot
  quietly reach `TypeSafeAPI.Answer.gate/2`. Values near the extremes mean the
  model is confident; values near 0.5 mean it isn't.

  `confidence` is `max(noul, 1 - noul)`. It is this library's convention, not
  something the model reported: the API sends no confidence for a Noul answer,
  only the probability. It reads distance from 0.5 as certainty, so 0.92 and
  0.08 both give 0.92, and it never drops below 0.5. It is not the same
  measurement as a Choice or Score `confidence`, so do not tune one threshold
  against numbers from the other. The field is here so the three answer structs
  have the same shape; `TypeSafeAPI.Answer.confidence/1` returns the same value.

  Because the value has a floor of 0.5, `TypeSafeAPI.Answer.gate/2` cannot
  return `:escalate` for a Noul answer unless `:review` is above 0.5 — it
  raises on a lower threshold rather than offering an unreachable band. Use
  `TypeSafeAPI.Answer.yes?/2` for the yes/no reading and `gate/2` for routing.
  """

  alias TypeSafeAPI.Keys

  @type t :: %__MODULE__{id: Keys.key(), noul: float(), confidence: float()}

  @enforce_keys [:id, :noul, :confidence]
  defstruct [:id, :noul, :confidence]
end
