defmodule TypeSafe.Answer.Choice do
  @moduledoc """
  A decoded Choice answer: which option the model picked, and how sure it was
  about every option it was offered.

  `choice` and the keys of `probabilities` are restored through
  `TypeSafe.Keys.option/3`, so they come back as atoms when the caller built
  the question with atom keys, and as strings when the caller used strings.
  An option the API named that the caller never declared stays a string.
  """

  alias TypeSafe.Keys

  @type t :: %__MODULE__{
          id: Keys.key(),
          choice: Keys.key(),
          probabilities: %{Keys.key() => float()},
          confidence: float()
        }

  @enforce_keys [:id, :choice, :probabilities, :confidence]
  defstruct [:id, :choice, :probabilities, :confidence]
end
