defmodule TypeSafe.Answer.Noul do
  @moduledoc """
  A decoded Noul answer: the model's probability that the answer is yes.

  `noul` is always between 0.0 and 1.0. Values near the extremes mean the
  model is confident; values near 0.5 mean it isn't. `TypeSafe.Answer.yes?/2`
  and `TypeSafe.Answer.confidence/1` turn this single number into a decision.
  """

  alias TypeSafe.Keys

  @type t :: %__MODULE__{id: Keys.key(), noul: float()}

  @enforce_keys [:id, :noul]
  defstruct [:id, :noul]
end
