# typesafe_api

Unofficial Elixir client for the TypeSafe AI API. Not affiliated with or endorsed by TypeSafe AI.

Sign up for an API key at [typesafe.ai](https://typesafe.ai). No key yet? Skip to
[Testing your code](#testing-your-code): `TypeSafe.Test` runs every example on this page
offline, no key or network required.

TypeSafe's [System One](https://docs.typesafe.ai/concepts/system-one) models are small,
fast models built for calibrated decisions, not text generation: they answer typed
questions about a piece of state and return probabilities instead of prose. You ask three
kinds of question:

| question | asks for                                  | answer                                          |
| -------- | ----------------------------------------- | ----------------------------------------------- |
| Noul     | yes or no                                 | probability of yes                              |
| Choice   | one option from a set you define          | the option, a probability per option, confidence |
| Score    | a position on an ordered scale you define | a score, a probability per level, confidence    |

`state` is what the questions are about: a string, or a JSON-shaped map or list.
`confidence` is a number from 0 to 1 saying how peaked the model's probability
distribution is; a Noul answer has no `confidence` field, since the API returns none for
it (`TypeSafe.Answer.confidence/1` covers what this library uses instead).

This library gives you typed question structs in, typed answer structs out, with retries,
telemetry, and test stubs handled. Under the typed layer sits a raw one (`TypeSafe.HTTP`)
that speaks maps, for the parts of the API this library does not model yet.

## Installation

```elixir
def deps do
  [
    {:typesafe_api, "~> 0.1.0-alpha.1"},
    # optional, for TypeSafe.Test stubs in your test suite
    {:plug, "~> 1.16", only: :test}
  ]
end
```

Requires Elixir 1.18 or later (it uses the built-in `JSON` module).

## Quick start

```elixir
client = TypeSafe.new(api_key: System.fetch_env!("TYPESAFE_API_KEY"))

{:ok, result} =
  TypeSafe.evaluate(client, "Help! My payouts have been failing for 3 days.",
    urgent:
      TypeSafe.noul("Does this convey urgency?",
        true: "Explicitly time-sensitive",
        false: "No urgency expressed"
      ),
    dept:
      TypeSafe.choice("Which team should handle this?",
        billing: "Payments, invoicing, refunds",
        technical: "Bugs, outages, integrations",
        sales: nil
      ),
    anger: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
  )

result.model            #=> "jev-1.13.0" (whatever the API resolved "jev-latest" to)
result.usage            #=> %TypeSafe.Usage{input_tokens: 312, output_tokens: 48}

result.answers.urgent   #=> %TypeSafe.Answer.Noul{id: :urgent, noul: 0.92}

result.answers.dept
#=> %TypeSafe.Answer.Choice{id: :dept, choice: :technical,
#     probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07}, confidence: 0.82}

result.answers.anger
#=> %TypeSafe.Answer.Score{id: :anger, score: 1.6, level: 2, label: "Very angry", description: "Very angry",
#     levels: [{"Calm", 0.05}, {"Frustrated", 0.3}, {"Very angry", 0.65}],
#     probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65}, legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
#     confidence: 0.78}

TypeSafe.Answer.gate(result.answers.dept, act: 0.8, review: 0.5)
#=> :act   (or :review, or :escalate)
```

`TypeSafe.new/0` with no options reads `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, and
`TYPESAFE_DEFAULT_MODEL`, or the same keys under `config :typesafe_api`. `jev-latest` is a
pinned alias, not a model id; the API resolves it to a versioned id like `"jev-1.13.0"`,
which is what `result.model` reports. `TypeSafe.models/1` lists the model ids your account
can pin to instead of `jev-latest`.

Question ids and Choice options come back exactly as you sent them: atoms stay atoms,
strings stay strings. Nothing in the response is ever turned into an atom.

Handle the outcome by matching on the error `type`:

```elixir
case TypeSafe.evaluate(client, state, questions) do
  {:ok, result} ->
    handle(result)

  {:error, %TypeSafe.Error{type: :rate_limited} = error} ->
    Logger.warning("typesafe rate limited, backing off: #{error.request_id}")
    :retry_later

  {:error, error} ->
    Logger.error("typesafe request failed (#{error.request_id}): #{Exception.message(error)}")
    :error
end
```

`request_id` (on both `TypeSafe.Result` and `TypeSafe.Error`) is the value to quote when
you contact TypeSafe support about a specific call.

### Where to build the client

`TypeSafe.new/1` returns a plain struct, not a process, so there is nothing to start under
a supervisor. Build it in an ordinary context function:

```elixir
defmodule MyApp.TypeSafe do
  def client, do: TypeSafe.new()
end
```

Do not call `TypeSafe.new/1` in a module attribute (`@client TypeSafe.new()`): module
attributes are evaluated at compile time, before your runtime config (`config/runtime.exs`,
environment variables in a release) has loaded, so the client would be built with whatever
configuration happened to be present at compile time. Read the API key at runtime instead:

```elixir
# config/runtime.exs
config :typesafe_api, api_key: System.fetch_env!("TYPESAFE_API_KEY")
```

## Many states, one question set

```elixir
TypeSafe.evaluate_many(client, tickets, questions, max_concurrency: 8)
#=> [{:ok, %TypeSafe.Result{}}, {:error, %TypeSafe.Error{}}, ...] in input order
```

The question set is validated and encoded once. `max_concurrency` defaults to 8; that is a
guess, since TypeSafe has not published rate limits. A failed state does not fail the
batch: `on_error` defaults to `:collect`, returning `{:error, _}` in place for that state;
pass `on_error: :raise` to fail fast instead. `attempt_timeout` bounds a single HTTP
attempt for each state, separately from the per-state task `timeout` that must cover every
retry of that attempt.

## Errors and retries

Every call returns `{:ok, result}` or `{:error, %TypeSafe.Error{}}` with a `type` you can
match on: `:auth`, `:validation`, `:rate_limited`, `:overloaded`, `:timeout`, `:connection`,
or `:unexpected`. Bang variants (`TypeSafe.evaluate!/4`) raise the same struct.

`:validation` covers both a request the API rejected outright (HTTP 400 or 422, for
example "Unknown model" or "Too many choices") and a problem this library caught locally
before sending anything. Build questions once, at compile time when you can, and check
them eagerly with `TypeSafe.Question.validate!/1` so a malformed question raises at the
line that wrote it instead of surfacing at call time.

Retries mirror the official SDKs: two retries with exponential backoff and jitter, `429`,
`408`, and `5xx` retried, `retry-after-ms` and `Retry-After` honored, connection and
timeout errors retried, and a 30 second total budget per call that includes every attempt
and delay. A `408` that survives every retry surfaces as `:unexpected`, since it is not
one of this library's own status-to-type mappings. Tune the policy with `retry:` on the
client or per call:

```elixir
TypeSafe.new(api_key: key, retry: [max_retries: 4, budget: 60_000])
TypeSafe.evaluate(client, state, questions, retry: [max_retries: 0])
```

## Telemetry

Each request runs inside a `[:typesafe, :request, :start | :stop | :exception]` span. The
`:start` event carries `model` and `question_count`; the `:stop` event adds `status`,
`retry_count`, `input_tokens`, `output_tokens`, and `error` (a `TypeSafe.Error`, or `nil`
on success). `TypeSafe.Telemetry.attach_logger/1` logs one line per request from the
`:stop` event; `detach_logger/0` removes it.

An API failure is a normal `:stop` event with `error` set, not an `:exception` — the
request succeeded at the HTTP level and returned an error body. `:exception` only fires
when the call itself raises (a bug, not an API error), so do not rely on it to catch
`TypeSafe.Error`.

## Testing your code

`TypeSafe.Test` stubs the API by question id, no fixtures needed, and the decoded structs
are identical to real ones:

```elixir
setup :typesafe_stubs

def typesafe_stubs(ctx), do: TypeSafe.Test.typesafe_stubs(ctx)

test "routes billing tickets" do
  client =
    TypeSafe.Test.client()
    |> TypeSafe.Test.stub(dept: {:choice, :billing, 0.9}, urgent: {:noul, 0.3})

  assert {:ok, result} = MyApp.Triage.run(client, "Where is my refund?")
  assert result.answers.dept.choice == :billing
end
```

`TypeSafe.Test` builds its responses with `Req.Test` and `Plug.Conn`, so it needs
`plug` in your test dependencies (`{:plug, "~> 1.16", only: :test}`). Without it, a stub
call raises `UndefinedFunctionError` for `Plug.Conn` (or `Req.Test`, depending on which
loads first) rather than something that mentions `TypeSafe.Test`.

## The raw layer

```elixir
TypeSafe.HTTP.post(client, "/v1/systemone", %{"state" => ..., "model" => ..., "questions" => ...})
#=> {:ok, %{"model" => ..., "answers" => ..., "usage" => ...}}
```

Same auth, retries, and telemetry; no structs. Reach for it when a field the API returns
is not one the typed layer models yet: there is no `extra_body` option or raw-question
escape hatch inside `evaluate/4` itself, so that call moves to `TypeSafe.HTTP` entirely
for that request.

## Writing good questions

- Ask everything one call's decision tree might need in a single request. Questions in
  one request are evaluated independently and answered in parallel, so extra questions
  cost tokens, not extra round trips.
- Ask for one snap judgment per question. A question that bundles two decisions ("is this
  urgent and who should own it") cannot be gated or routed on separately.
- Give a Choice an `other` option when its criteria may not cover every input; without one,
  the model is forced into the closest listed option even when none of them fit.
- The only real ceiling is the token budget: state and questions share roughly 32,000
  tokens per request, per TypeSafe's docs. A Choice needs 2 to 255 options and a
  Score 2 to 10 levels, both enforced locally before a request is sent.
- Pass Choice criteria as a keyword list (or list of `{key, description}` pairs) rather
  than a map once you have more than 32 options: Elixir maps stop preserving insertion
  order past 32 keys, and option order is what the model sees. `TypeSafe.choice/2`
  raises on a map that large rather than silently reordering it.

## Security

The client's `api_key` is redacted from `inspect/1` output (`TypeSafe.Client` has a custom
`Inspect` implementation), and it never appears in telemetry metadata or in the `body` of
a `TypeSafe.Error` — those carry the response TypeSafe sent back, not the request you made.

## Guides

- [Cheatsheet](guides/cheatsheet.cheatmd)
- [Speculative fan-out](guides/speculative_fan_out.md)
- [Confidence-gated routing](guides/confidence_gated_routing.md)
- [Composite scoring](guides/composite_scoring.md)
- [Design notes](DESIGN.md) on what differs from the official SDKs and why

## License

MIT. See the LICENSE file in the repository.
