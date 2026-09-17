# Speculative fan-out

TypeSafe evaluates every question in a request in parallel, so adding questions costs
tokens but almost no latency. The official
[fan-out pattern](https://docs.typesafe.ai/patterns/fan-out) therefore recommends asking
everything your decision tree *might* need in one call, then letting code decide what
matters. A speculative question you end up ignoring costs a few tokens; a second round
trip costs a whole request. The one real limit is the token budget: state and questions
share roughly 32,000 tokens per request, per TypeSafe's docs.

## The questions

A support triage system needs the ticket's category. If it is a bug, it also needs the
severity and whether there are reproduction steps. If it is a billing issue, it needs to
know whether a refund is being requested. Ask all of it at once:

```elixir
defmodule MyApp.Triage do
  @questions [
    category:
      TypeSafeAPI.choice("Determine the broad category of this support ticket",
        bug_report: "The user is reporting something that is broken or producing errors",
        billing: "Charges, invoices, refunds, subscriptions",
        feature_request: "The user is requesting new functionality",
        account: "Login, permissions, profile, security",
        other: "Anything else"
      ),
    bug_severity:
      TypeSafeAPI.score("How severe is the reported issue", [
        "Cosmetic; no impact to functionality",
        "Broken or degraded feature; workaround exists",
        "Blocking issue; no workaround exists"
      ]),
    has_reproducible_steps:
      TypeSafeAPI.noul("The user describes specific steps to reproduce the issue"),
    refund_requested:
      TypeSafeAPI.noul("The user is explicitly asking for a refund or credit"),
    frustration:
      TypeSafeAPI.score("How frustrated the user appears", [
        "Calm, matter-of-fact",
        "Frustrated but civil",
        "Very angry"
      ])
  ]

  def questions, do: @questions
end
```

`bug_severity` and `has_reproducible_steps` only matter for bug reports;
`refund_requested` only matters for billing. They are included anyway.

## Routing with code

```elixir
defmodule MyApp.Triage do
  # ... @questions from above ...

  def run(client, ticket) do
    with {:ok, result} <- TypeSafeAPI.evaluate(client, ticket.body, @questions) do
      {:ok, route(ticket, result.answers)}
    end
  end

  defp route(ticket, answers) do
    actions =
      case answers.category.choice do
        :bug_report ->
          if answers.bug_severity.score > 1.5 and TypeSafeAPI.Answer.yes?(answers.has_reproducible_steps, 0.6) do
            [{:escalate_to_engineering, ticket.id, severity: :high}]
          else
            [{:add_to_bug_backlog, ticket.id}]
          end

        :billing ->
          if TypeSafeAPI.Answer.yes?(answers.refund_requested, 0.7),
            do: [{:route_to_billing, ticket.id, refund_likely: true}],
            else: [{:route_to_billing, ticket.id, []}]

        :feature_request ->
          [{:log_feature_request, ticket.id}]

        :account ->
          [{:route_to_account_team, ticket.id}]

        :other ->
          [{:route_to_general_queue, ticket.id}]
      end

    # Frustration is useful regardless of category.
    if answers.frustration.score > 1.5 do
      [{:flag_for_priority_response, ticket.id} | actions]
    else
      actions
    end
  end
end
```

Everything the decision tree needs arrives in one response. Pattern matching on
`answers.category.choice` reads naturally because the option keys come back as the atoms
you wrote in the question.

## Testing the routing without the API

`TypeSafeAPI.Test` lets you stub each answer by id, so the routing logic is testable in
isolation:

```elixir
test "escalates severe, reproducible bugs" do
  client =
    TypeSafeAPI.Test.client()
    |> TypeSafeAPI.Test.stub(
      category: {:choice, :bug_report, 0.95},
      bug_severity: {:score, 2, 0.9},
      has_reproducible_steps: {:noul, 0.8},
      refund_requested: {:noul, 0.05},
      frustration: {:score, 1, 0.7}
    )

  assert {:ok, actions} = MyApp.Triage.run(client, %{id: 42, body: "Checkout crashes on submit..."})
  assert {:escalate_to_engineering, 42, severity: :high} in actions
end
```
