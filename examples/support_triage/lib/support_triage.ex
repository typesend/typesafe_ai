defmodule SupportTriage do
  @moduledoc """
  Routes an inbound support message to a queue, an escalation, or a human.

  One evaluation asks three questions about the message at once:

    * `:urgent` — a Noul: is the customer blocked right now?
    * `:dept` — a Choice: billing, technical, or sales?
    * `:frustration` — a Score: how angry does the customer sound?

  The answers are then gated on confidence. Anything the model is not sure
  enough about becomes `{:needs_human_review, reasons}` rather than a guess,
  which is the whole point of asking for calibrated probabilities instead of
  prose.

  Every function here takes a `TypeSafeAPI.Client` as its first argument, so the
  same code runs against the live API in production and against
  `TypeSafeAPI.Test` stubs in the test suite. See `test/support_triage_test.exs`.
  """

  alias TypeSafeAPI.Answer

  @typedoc "Which team owns the ticket."
  @type department :: :billing | :technical | :sales

  @typedoc "Why a message could not be routed automatically."
  @type reason :: {question_id :: atom(), Answer.t(), verdict :: :review | :escalate}

  @typedoc "What to do with a message."
  @type decision ::
          {:escalate, department()}
          | {:queue, department()}
          | {:needs_human_review, [reason()]}

  @doc """
  The confidence at or above which an answer is acted on without a human.
  """
  @spec act_threshold() :: float()
  def act_threshold, do: 0.75

  @doc """
  The confidence below which an answer is treated as no answer at all.

  Between this and `act_threshold/0` an answer is "borderline": still a
  `{:needs_human_review, _}` decision, but the reason carries `:review` rather
  than `:escalate` so a queue can sort the near-misses first.

  Kept above 0.5 on purpose: a Noul answer's confidence is `max(p, 1 - p)`, so it
  is never below 0.5 and `TypeSafeAPI.Answer.gate/2` rejects a review threshold
  that could never produce `:escalate` for it.
  """
  @spec review_threshold() :: float()
  def review_threshold, do: 0.6

  @questions [
    urgent:
      TypeSafeAPI.Question.validate!(
        TypeSafeAPI.noul("Is the customer blocked right now by the problem they describe?",
          true: "Something they rely on is broken or unavailable at this moment",
          false: "A question, a request, or a problem that can wait"
        )
      ),
    dept:
      TypeSafeAPI.Question.validate!(
        TypeSafeAPI.choice("Which team should own this message?",
          billing: "Payments, invoices, refunds, plan changes, and card failures",
          technical: "Bugs, outages, API errors, integrations, and performance",
          sales: "Pricing questions, upgrades, trials, and contract negotiation"
        )
      ),
    frustration:
      TypeSafeAPI.Question.validate!(
        TypeSafeAPI.score("How frustrated does the customer sound?", [
          "Calm and matter of fact",
          "Visibly annoyed",
          "Angry, threatening to leave"
        ])
      )
  ]

  @doc """
  The question set, built once.

  `TypeSafeAPI.Question.validate!/1` runs at compile time so a malformed question
  raises here rather than surfacing as a `:validation` error at call time.
  """
  @spec questions() :: keyword(TypeSafeAPI.Question.t())
  def questions, do: @questions

  @doc """
  Triages one message.

  Returns `{:ok, decision}`, or `{:error, %TypeSafeAPI.Error{}}` when the API call
  itself failed. Callers that want to distinguish a rate limit from a bad key
  match on the error's `type`.

      iex> client =
      ...>   TypeSafeAPI.Test.client()
      ...>   |> TypeSafeAPI.Test.stub(
      ...>     urgent: {:noul, 0.95},
      ...>     dept: {:choice, :technical, 0.9},
      ...>     frustration: {:score, 2, 0.88}
      ...>   )
      iex> SupportTriage.triage(client, "The API has been returning 500s for an hour.")
      {:ok, {:escalate, :technical}}
  """
  @spec triage(TypeSafeAPI.Client.t(), TypeSafeAPI.SystemOne.state()) ::
          {:ok, decision()} | {:error, TypeSafeAPI.Error.t()}
  def triage(client, message) do
    with {:ok, result} <- TypeSafeAPI.evaluate(client, message, questions()) do
      {:ok, decide(result.answers)}
    end
  end

  @doc """
  Triages many messages against the same question set, concurrently.

  `TypeSafeAPI.evaluate_many/4` validates and encodes the question set once into a
  `TypeSafeAPI.SystemOne.Prepared` struct and reuses it for every message. Outcomes
  come back in input order, one per message, so a single failure does not sink
  the batch.
  """
  @spec triage_many(TypeSafeAPI.Client.t(), [TypeSafeAPI.SystemOne.state()], keyword()) ::
          [{:ok, decision()} | {:error, TypeSafeAPI.Error.t()}]
  def triage_many(client, messages, opts \\ []) do
    opts = Keyword.put_new(opts, :max_concurrency, 4)

    client
    |> TypeSafeAPI.evaluate_many(messages, questions(), opts)
    |> Enum.map(fn
      {:ok, result} -> {:ok, decide(result.answers)}
      {:error, error} -> {:error, error}
    end)
  end

  @doc """
  Turns one set of answers into a decision.

  Split out from `triage/2` so the routing rules can be read, and tested,
  without a client in the way.
  """
  @spec decide(map()) :: decision()
  def decide(answers) do
    case low_confidence(answers) do
      [] -> route(answers)
      reasons -> {:needs_human_review, reasons}
    end
  end

  # Anything that did not clear `act_threshold/0` blocks the automatic route.
  # The verdict is kept so a reviewer can tell a near-miss from a coin flip.
  defp low_confidence(answers) do
    [:urgent, :dept, :frustration]
    |> Enum.map(fn id ->
      answer = Map.fetch!(answers, id)
      {id, answer, Answer.gate(answer, act: act_threshold(), review: review_threshold())}
    end)
    |> Enum.reject(fn {_id, _answer, verdict} -> verdict == :act end)
  end

  defp route(answers) do
    department = answers.dept.choice

    if Answer.yes?(answers.urgent, act_threshold()) or answers.frustration.level == 2 do
      {:escalate, department}
    else
      {:queue, department}
    end
  end

  @doc """
  A one-line summary of a decision, for logs and for the demo task.
  """
  @spec describe({:ok, decision()} | {:error, TypeSafeAPI.Error.t()}) :: String.t()
  def describe({:ok, {:escalate, department}}), do: "escalate to #{department}"
  def describe({:ok, {:queue, department}}), do: "queue for #{department}"

  def describe({:ok, {:needs_human_review, reasons}}) do
    detail =
      Enum.map_join(reasons, ", ", fn {id, answer, verdict} ->
        "#{id} #{verdict} at #{Float.round(Answer.confidence(answer), 2)}"
      end)

    "needs human review (#{detail})"
  end

  def describe({:error, %TypeSafeAPI.Error{} = error}), do: "failed: #{Exception.message(error)}"
end
