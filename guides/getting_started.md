# Getting started

This page takes you from an empty project to a successful first call against the TypeSafe
AI System One API. For background on what System One questions are, see the
[README](../README.md); for the reasoning behind the library's design, see
[Design notes](../DESIGN.md).

## Requirements

- Elixir `~> 1.18` (the library uses the built-in `JSON` module, added in 1.18).
- Erlang/OTP. CI tests OTP 27 and 28; OTP 27 or later is recommended.
- A TypeSafe AI API key. Sign up at [typesafe.ai](https://typesafe.ai). No key yet? Skip
  ahead to [Testing without a key](#testing-without-a-key): `TypeSafeAPI.Test` runs every
  example on this page offline.

## Install

Add `typesafe_api` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:typesafe_api, "~> 0.1.0-alpha.3"},
    # optional, for TypeSafeAPI.Test stubs in your test suite
    {:plug, "~> 1.16", only: :test}
  ]
end
```

Then fetch it:

```
mix deps.get
```

`typesafe_api` is built on [Req](https://hexdocs.pm/req); see
[Why Req](../DESIGN.md#why-req) in the design notes if you're curious what that pulls in
and why.

## Configure a client

`TypeSafeAPI.new/1` builds a plain struct, not a process. There is no application to
start and nothing to add to a supervision tree — build the client in an ordinary function
and pass it wherever it's needed:

```elixir
defmodule MyApp.TypeSafe do
  def client, do: TypeSafeAPI.new()
end
```

Avoid building it in a module attribute (`@client TypeSafeAPI.new()`): module attributes
are evaluated at compile time, before runtime configuration (environment variables, or
`config/runtime.exs` in a release) has loaded.

Each setting `TypeSafeAPI.new/1` needs — `api_key`, `base_url`, `model`, and so on — is
resolved in this order:

1. the option passed directly to `new/1`, e.g. `TypeSafeAPI.new(api_key: "sk-...")`
2. application config, e.g. `config :typesafe_api, api_key: "sk-..."`
3. an environment variable: `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`
4. a built-in default (there is no default for `api_key`; `new/1` raises `ArgumentError`
   if none of the above supplied one)

So the simplest setup is just an environment variable:

```
export TYPESAFE_API_KEY=sk-...
```

```elixir
client = TypeSafeAPI.new()
```

## Your first call

TypeSafe's System One models answer typed questions about a piece of `state` — a string,
or a JSON-shaped map or list — and return probabilities instead of prose. There are three
question types, and you can ask any mix of them in a single `evaluate/4` call:

```elixir
client = TypeSafeAPI.new()

{:ok, result} =
  TypeSafeAPI.evaluate(client, "Help! My payouts have been failing for 3 days.",
    urgent:
      TypeSafeAPI.noul("Does this convey urgency?",
        true: "Explicitly time-sensitive",
        false: "No urgency expressed"
      ),
    dept:
      TypeSafeAPI.choice("Which team should handle this?",
        billing: "Payments, invoicing, refunds",
        technical: "Bugs, outages, integrations",
        sales: nil
      ),
    anger: TypeSafeAPI.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
  )
```

`instructions` — the first argument to `noul/2`, `choice/2`, and `score/2` — is optional on
every question type; the API requires only the question's type, plus `criteria` for a
Choice or a Score. Pass `nil` (or just omit it, as `TypeSafeAPI.noul/0,1` does) and the
library leaves the field out of the request rather than sending it as `null`.

A Noul can evaluate a statement as well as a question. `TypeSafeAPI.noul("Does this convey
urgency?")` asks a question; `TypeSafeAPI.noul("This message contains unsolicited
advertising.")` asks the model to judge a statement, and the answer is the probability that
the statement holds.

## Reading the result

`result` is a `TypeSafeAPI.Result`. It carries the model that actually answered
(`result.model`, since `"jev-latest"` resolves to a versioned id like `"jev-1.13.0"`), token
usage (`result.usage`), and one answer per question id under `result.answers`:

```elixir
result.model            #=> "jev-1.13.0"
result.usage            #=> %TypeSafeAPI.Usage{input_tokens: 312, output_tokens: 48}
```

Each answer is a struct whose shape depends on which question produced it. Question ids and
Choice option keys come back exactly as you sent them — atoms stay atoms, strings stay
strings — so `result.answers.urgent` and `result.answers.dept` work whether you built the
question set with atom or string keys.

### Noul

```elixir
result.answers.urgent
#=> %TypeSafeAPI.Answer.Noul{id: :urgent, noul: 0.92, confidence: 0.92}
```

`noul` is the probability of yes (or, for a statement, the probability it holds), always
between 0.0 and 1.0 — a value outside that range is rejected as an `:unexpected` error
rather than clamped.

`confidence` is `max(noul, 1 - noul)`, this library's own convention rather than a number
the API sent: the API returns no confidence for a Noul question. It reads distance from 0.5
as certainty, so 0.92 and 0.08 both give 0.92, and it never drops below 0.5. That last
point matters for `TypeSafeAPI.Answer.gate/2`: a `review:` threshold of 0.5 or lower could
never escalate a Noul answer, so `gate/2` raises rather than offering an unreachable band.
Pick something just above it, like `review: 0.55`.

### Choice

```elixir
result.answers.dept
#=> %TypeSafeAPI.Answer.Choice{id: :dept, choice: :technical,
#     description: "Bugs, outages, integrations",
#     probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07},
#     options: [{:billing, 0.08}, {:technical, 0.85}, {:sales, 0.07}], confidence: 0.82}
```

`choice` is the winning option and `description` is that option's description, exactly as
you wrote it in the question (`nil` for an option you gave none). `probabilities` gives
every option's share: every option you sent is present, with 0.0 for one the response left
out, so a lookup never returns `nil`. `options` is the same data as an ordered list in your
question's order, mirroring a Score answer's `levels`, so a ranked display does not have to
re-sort. `confidence` is a number from 0 to 1 saying how peaked the distribution is — near 1
means the model was sure; near 0 means the options were close.

An answer that disagrees with the question is an `:unexpected` error rather than a struct
that is confidently wrong: an option you never declared, or a `choice` that is not the
highest-probability option.

### Score

```elixir
result.answers.anger
#=> %TypeSafeAPI.Answer.Score{id: :anger, score: 1.6, level: 2, label: "Very angry",
#     description: "Very angry",
#     levels: [{"Calm", 0.05}, {"Frustrated", 0.3}, {"Very angry", 0.65}],
#     probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65}, legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
#     confidence: 0.78}
```

`level` is the winning 0-based index into the levels you gave `TypeSafeAPI.score/2`; `label`
is always a string version of that level. `score` is a continuous position on the scale
(useful for sorting or thresholding across many results); `levels` pairs every level's label
with its probability, in the order you wrote them. `confidence` means the same thing as it
does for a Choice answer.

`score` and `level` are two different readings and they can disagree. `score` is the
probability-weighted average of the level indices, an expected value; `level` is the single
most likely level. A bimodal answer with 0.5 on level 0 and 0.5 on level 2 has `score` 1.0
and `level` 0, though no probability mass sits on the middle at all. Use `score` when you
are averaging or thresholding, and `level` when you are branching or displaying one level.
Do not use `round(score)` as a level.

A `legend` whose labels disagree with the levels you sent, a probability outside
`0..n-1`, a non-numeric probability, and an empty `probabilities` object are all
`:unexpected` errors. A level the response simply left out is filled in as 0.0.

### Acting on an answer

All three answer types work with `TypeSafeAPI.Answer.gate/2`, which turns a confidence
number into a three-way routing decision:

```elixir
TypeSafeAPI.Answer.gate(result.answers.dept, act: 0.8, review: 0.5)
#=> :act   (or :review, or :escalate)
```

## Testing without a key

`TypeSafeAPI.Test` stubs the API by question id, so you can write and run tests (and follow
along with this guide) without a real key or network access. Add `{:plug, "~> 1.16", only:
:test}` to your deps, then:

```elixir
client =
  TypeSafeAPI.Test.client()
  |> TypeSafeAPI.Test.stub(
    urgent: {:noul, 0.92},
    dept: {:choice, :technical, 0.82},
    anger: {:score, 2, 0.78}
  )

{:ok, result} = TypeSafeAPI.evaluate(client, "Help! My payouts have been failing for 3 days.", questions)
```

See the [README](../README.md#testing-your-code) for the full pattern, including the
`setup :typesafe_stubs` helper.

## Next steps

- [Errors and retries](errors_and_retries.md) — every `TypeSafeAPI.Error` type, what gets
  retried automatically, and how to tune it.
- [Cheatsheet](cheatsheet.cheatmd) — every option and question shape on one page.
- [Speculative fan-out](speculative_fan_out.md) — asking everything a decision tree might
  need in one call.
- [Confidence-gated routing](confidence_gated_routing.md) — turning `confidence` into
  automated vs. human-reviewed decisions.
- [Composite scoring](composite_scoring.md) — combining several answers into one score.
- [Design notes](../DESIGN.md) — what differs from the official SDKs, and why.
