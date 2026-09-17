# Confidence-gated routing

Every Choice and Score answer carries a `confidence` between 0 and 1, derived from how
spread out the probability distribution is. The official
[confidence-routing pattern](https://docs.typesafe.ai/patterns/confidence-routing)
treats it as a second axis: the answer says *what*, confidence says *whether to act*.
Riskier actions deserve a higher bar.

## The question

A voice banking assistant classifies what the user asked for:

```elixir
defmodule MyBank.Voice do
  @intent TypeSafe.choice("What action is the user requesting?",
            check_balance: "Check the balance of an account",
            approve_transfer: "Approve the pending transfer request",
            other: "Something else"
          )

  def intent, do: @intent
end
```

## Routing by stakes

```elixir
defmodule MyBank.Voice do
  # ... @intent and intent/0 from above ...

  def handle(client, account_id, transcript) do
    with {:ok, result} <- TypeSafe.evaluate(client, transcript, intent: intent()) do
      {:ok, route(account_id, result.answers.intent)}
    end
  end

  # Below 0.6 confidence on any action, route to a human.
  defp route(account_id, %{confidence: confidence}) when confidence < 0.6,
    do: {:support_agent, account_id}

  # Low stakes. 0.6 confidence is sufficient.
  defp route(account_id, %{choice: :check_balance}),
    do: {:show_balance, account_id}

  # High stakes, but high confidence. Safe to act automatically.
  defp route(account_id, %{choice: :approve_transfer, confidence: confidence}) when confidence > 0.85,
    do: {:approve_transfer, account_id}

  # High stakes, moderate confidence. Verify intent first.
  defp route(_account_id, %{choice: :approve_transfer}),
    do: {:confirm, "Just to confirm: you would like to approve this transfer, is that correct?"}

  defp route(account_id, _other), do: {:support_agent, account_id}
end
```

The 0.6 floor catches anything the model is genuinely unsure about. Above the floor, each
action has its own threshold set by the cost of being wrong.

## `TypeSafe.Answer.gate/2`

When a single pair of thresholds is enough, `gate/2` turns the confidence into one of
three verdicts:

```elixir
case TypeSafe.Answer.gate(result.answers.intent, act: 0.85, review: 0.6) do
  :act -> perform(result.answers.intent.choice)
  :review -> ask_user_to_confirm(result.answers.intent.choice)
  :escalate -> route_to_support_agent()
end
```

For Noul answers, which have no separate confidence field, `gate/2` uses how far the
probability sits from 0.5 (`max(noul, 1 - noul)`), so a 0.05 "no" gates the same as a
0.95 "yes".
