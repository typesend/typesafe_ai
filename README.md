# typesafe_api

Typed Elixir client for TypeSafe AI and its Jev System One model, with offline test
stubs, concurrent fan-out, and atom-keyed answers. Unofficial; not affiliated with
TypeSafe AI.

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ftypesend%2Ftypesafe_ai%2Fmain%2Flivebooks%2Flive_walkthrough.livemd)

Sign up for an API key at [typesafe.ai](https://typesafe.ai). No key yet? Skip to
[Testing your code](#testing-your-code): `TypeSafeAPI.Test` runs every example on this page
offline, no key or network required.

TypeSafe's [System One](https://docs.typesafe.ai/concepts/system-one) models, of which
Jev is the first (`jev-latest` is the default model here), are small, fast models built
for calibrated decisions, not text generation: they answer typed
questions about a piece of state and return probabilities instead of prose. You ask three
kinds of question (see the [System One concepts guide](guides/system_one.md) for more
on what that means and when to reach for something else instead):

| question | asks for                                  | answer                                          |
| -------- | ----------------------------------------- | ----------------------------------------------- |
| Noul     | yes or no, on a question or a statement   | probability of yes                              |
| Choice   | one option from a set you define          | the option, a probability per option, confidence |
| Score    | a position on an ordered scale you define | a score, a probability per level, confidence    |

`state` is what the questions are about: a string, or a JSON-shaped map or list.
`confidence` is a number from 0 to 1 saying how peaked the model's probability
distribution is; a Noul answer has no `confidence` field, since the API returns none for
it (`TypeSafeAPI.Answer.confidence/1` covers what this library uses instead).

This library gives you typed question structs in, typed answer structs out, with retries,
telemetry, and test stubs handled. Under the typed layer sits a raw one (`TypeSafeAPI.HTTP`)
that speaks maps, for the parts of the API this library does not model yet.

## Installation

```elixir
def deps do
  [
    {:typesafe_api, "~> 0.1.0-alpha.3"},
    # optional, for TypeSafeAPI.Test stubs in your test suite
    {:plug, "~> 1.16", only: :test}
  ]
end
```

Requires Elixir 1.18 or later (it uses the built-in `JSON` module).

## Quick start

```elixir
client = TypeSafeAPI.new(api_key: System.fetch_env!("TYPESAFE_API_KEY"))

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

result.model            #=> "jev-1.13.0" (whatever the API resolved "jev-latest" to)
result.usage            #=> %TypeSafeAPI.Usage{input_tokens: 312, output_tokens: 48}

result.answers.urgent   #=> %TypeSafeAPI.Answer.Noul{id: :urgent, noul: 0.92, confidence: 0.92}

result.answers.dept
#=> %TypeSafeAPI.Answer.Choice{id: :dept, choice: :technical,
#     description: "Bugs, outages, integrations",
#     probabilities: %{billing: 0.08, technical: 0.85, sales: 0.07},
#     options: [{:billing, 0.08}, {:technical, 0.85}, {:sales, 0.07}], confidence: 0.82}

result.answers.anger
#=> %TypeSafeAPI.Answer.Score{id: :anger, score: 1.6, level: 2, label: "Very angry", description: "Very angry",
#     levels: [{"Calm", 0.05}, {"Frustrated", 0.3}, {"Very angry", 0.65}],
#     probabilities: %{0 => 0.05, 1 => 0.3, 2 => 0.65}, legend: %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"},
#     confidence: 0.78}

TypeSafeAPI.Answer.gate(result.answers.dept, act: 0.8, review: 0.5)
#=> :act   (or :review, or :escalate)
```

`TypeSafeAPI.new/0` with no options reads `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, and
`TYPESAFE_DEFAULT_MODEL`, or the same keys under `config :typesafe_api`. `jev-latest` is a
pinned alias, not a model id; the API resolves it to a versioned id like `"jev-1.13.0"`,
which is what `result.model` reports. `TypeSafeAPI.models/1` lists the model ids your account
can pin to instead of `jev-latest`.

Question ids and Choice options come back exactly as you sent them: atoms stay atoms,
strings stay strings. Nothing in the response is ever turned into an atom.

Handle the outcome by matching on the error `type`:

```elixir
case TypeSafeAPI.evaluate(client, state, questions) do
  {:ok, result} ->
    handle(result)

  {:error, %TypeSafeAPI.Error{type: :rate_limited} = error} ->
    Logger.warning("typesafe rate limited, backing off: #{error.request_id}")
    :retry_later

  {:error, error} ->
    Logger.error("typesafe request failed (#{error.request_id}): #{Exception.message(error)}")
    :error
end
```

`request_id` (on both `TypeSafeAPI.Result` and `TypeSafeAPI.Error`) is the value to quote when
you contact TypeSafe support about a specific call.

### Where to build the client

`TypeSafeAPI.new/1` returns a plain struct, not a process, so there is nothing to start under
a supervisor. Build it in an ordinary context function:

```elixir
defmodule MyApp.TypeSafe do
  def client, do: TypeSafeAPI.new()
end
```

Do not call `TypeSafeAPI.new/1` in a module attribute (`@client TypeSafeAPI.new()`): module
attributes are evaluated at compile time, before your runtime config (`config/runtime.exs`,
environment variables in a release) has loaded, so the client would be built with whatever
configuration happened to be present at compile time. Read the API key at runtime instead:

```elixir
# config/runtime.exs
config :typesafe_api, api_key: System.fetch_env!("TYPESAFE_API_KEY")
```

## Many states, one question set

```elixir
TypeSafeAPI.evaluate_many(client, tickets, questions, max_concurrency: 8)
#=> [{:ok, %TypeSafeAPI.Result{}}, {:error, %TypeSafeAPI.Error{}}, ...] in input order
```

The question set is validated and encoded once. `max_concurrency` defaults to 8; that is a
guess, since TypeSafe has not published rate limits. A failed state does not fail the
batch: `on_error` defaults to `:collect`, returning `{:error, _}` in place for that state;
pass `on_error: :raise` to fail fast instead. Tasks are supervised and unlinked, so a state
that raises is one failed outcome rather than a dead caller. `timeout` bounds a single HTTP
attempt, exactly as in `evaluate/4`; `task_timeout` bounds one state's whole task and must
cover every retry of it.

## Errors and retries

Every call returns `{:ok, result}` or `{:error, %TypeSafeAPI.Error{}}` with a `type` you can
match on: `:auth`, `:validation`, `:rate_limited`, `:overloaded`, `:server_error`,
`:timeout`, `:connection`, or `:unexpected`, with `TypeSafeAPI.Error.retryable?/1` to tell
the transient ones apart. Bang variants (`TypeSafeAPI.evaluate!/4`) raise the same struct.
Retries mirror the official SDKs — two retries with exponential backoff and jitter, `429`,
`408`, and `5xx` retried, `retry-after-ms` and `Retry-After` honored, and a 30 second
budget per call — with one deliberate difference: connection errors *and* timeouts on
`POST /v1/systemone` are not retried by default, since a retry there can double-bill an
evaluation that already reached the server.

See the [errors and retries guide](guides/errors_and_retries.md) for every error type, the
full retry timeline, and how to tune or opt into replaying connection errors.

## Telemetry

Each request runs inside a `[:typesafe_api, :request, :start | :stop | :exception]` span. The
`:start` event carries `model` and `question_count`; the `:stop` event adds `status`,
`retry_count`, `input_tokens`, `output_tokens`, and `error` (a `TypeSafeAPI.Error`, or `nil`
on success). `TypeSafeAPI.Telemetry.attach_logger/1` logs one line per request from the
`:stop` event; `detach_logger/0` removes it.

An API failure is a normal `:stop` event with `error` set, not an `:exception` — the
request succeeded at the HTTP level and returned an error body. `:exception` only fires
when the call itself raises (a bug, not an API error), so do not rely on it to catch
`TypeSafeAPI.Error`.

## Testing your code

`TypeSafeAPI.Test` stubs the API by question id, no fixtures needed, and the decoded structs
are identical to real ones:

```elixir
setup :typesafe_stubs

def typesafe_stubs(ctx), do: TypeSafeAPI.Test.typesafe_stubs(ctx)

test "routes billing tickets" do
  client =
    TypeSafeAPI.Test.client()
    |> TypeSafeAPI.Test.stub(dept: {:choice, :billing, 0.9}, urgent: {:noul, 0.3})

  assert {:ok, result} = MyApp.Triage.run(client, "Where is my refund?")
  assert result.answers.dept.choice == :billing
end
```

`TypeSafeAPI.Test` builds its responses with `Req.Test` and `Plug.Conn`, so it needs
`plug` in your test dependencies (`{:plug, "~> 1.16", only: :test}`). Without it, a stub
call raises `UndefinedFunctionError` for `Plug.Conn` (or `Req.Test`, depending on which
loads first) rather than something that mentions `TypeSafeAPI.Test`.

A `confidence` has to beat the uniform baseline of `1 / n` for a question with `n`
options or levels, or the option you named would not be the one with the highest
probability and the stubbed answer would decode to something else. A question you did
not stub is answered with HTTP 422, so `evaluate/4` returns
`{:error, %TypeSafeAPI.Error{type: :validation}}` and `evaluate_many/4` gives you one
error per state instead of an exception inside a task.

### Composing stubs and errors

Every helper adds to the same client, so one client can serve several endpoints, and
`stub_error/4` can cover just the next call:

```elixir
client =
  TypeSafeAPI.Test.client()
  |> TypeSafeAPI.Test.stub_models([%{name: "jev-1.13.0"}])
  |> TypeSafeAPI.Test.stub(dept: {:choice, :billing, 0.9})
  |> TypeSafeAPI.Test.stub_error(429, %{"error" => "slow down"},
    headers: [{"retry-after", "1"}],
    times: 1
  )
```

The first call gets the 429 and the retry gets the answers.

### Recording fixtures

Wrap a client with `TypeSafeAPI.Test.record/2` for one live run and every response is
appended to a fixture file; `TypeSafeAPI.Test.replay/2` turns that file back into a
client, so the same test runs offline against the answers the real model gave:

```elixir
TypeSafeAPI.new() |> TypeSafeAPI.Test.record("test/fixtures/triage.jsonl") |> MyApp.Triage.run(state)
client = TypeSafeAPI.Test.replay("test/fixtures/triage.jsonl")
```

A fixture is [JSON Lines](https://jsonlines.org): one `{"request": ..., "response": ...}`
object per line, in the order the responses arrived, so appending is one write and a diff
reads one response per line. Error responses are recorded too, so an error path can be
replayed. Recordings match on method, path and body (`match: [:method, :path]` ignores the
body, and then pairs requests to recordings by position, so keep it for fixtures recorded
by sequential calls). Only the request method, path and JSON body are written, never
headers, so a fixture you commit cannot carry your API key.

## Example app

[`examples/support_triage`](examples/support_triage/README.md) is a small Mix app that
routes support messages with one `evaluate/4` call and gates the answers on confidence.
Its whole test suite runs on `TypeSafeAPI.Test` stubs with no key and no network, and CI
runs it on every push.

## The raw layer

```elixir
TypeSafeAPI.HTTP.post(client, "/v1/systemone", %{"state" => ..., "model" => ..., "questions" => ...})
#=> {:ok, %{"model" => ..., "answers" => ..., "usage" => ...}}
```

Same auth, retries, and telemetry; no structs. Reach for it when a field the API returns
is not one the typed layer models yet: there is no `extra_body` option or raw-question
escape hatch inside `evaluate/4` itself, so that call moves to `TypeSafeAPI.HTTP` entirely
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
  tokens per request, per TypeSafe's docs. A Choice needs 1 to 255 options and a
  Score 2 to 10 levels, both enforced locally before a request is sent. A one-option
  Choice is degenerate but well defined, and criteria built at runtime can filter down
  to a single survivor, so only the empty set is rejected.
- Pass Choice criteria as a keyword list or a list of `{key, description}` pairs, never a
  map: option order is what the model sees, and a map has no order to preserve.
  `TypeSafeAPI.choice/2` raises on a map rather than silently reordering it.
- `instructions` is optional on all three question types — the API requires only the type,
  plus the criteria for a Choice or a Score. Pass `nil` (or omit it, with
  `TypeSafeAPI.noul/1`) and the key is left out of the request rather than sent as `null`.

## Security

The client's `api_key` is redacted from `inspect/1` output (`TypeSafeAPI.Client` has a custom
`Inspect` implementation), and it never appears in telemetry metadata or in the `body` of
a `TypeSafeAPI.Error` — those carry the response TypeSafe sent back, not the request you made.

## Raw questions and unknown question types

The API supports question types this library does not model yet (`bounding_box`, for
example — see [Design notes](DESIGN.md)). Send those with `TypeSafeAPI.HTTP.post/4`
directly, against `TypeSafeAPI.SystemOne.path/0`:

```elixir
{:ok, raw} =
  TypeSafeAPI.HTTP.post(client, TypeSafeAPI.SystemOne.path(), %{
    "state" => "A photo of a storefront.",
    "model" => client.model,
    "questions" => %{"region" => %{"type" => "bounding_box", "instructions" => "The storefront sign"}}
  })

raw["answers"]["region"]
```

`raw` is the decoded JSON body: a plain map, with every answer exactly as the API sent
it, whatever its type. This is also where an unknown answer type ends up when it comes
back from the typed `evaluate/4` path — as `result.raw`, alongside the decoded
`result.answers` for every question this library does model.

## Guides

- [Getting started](guides/getting_started.md)
- [System One concepts](guides/system_one.md)
- [Configuration and concurrency](guides/configuration_and_concurrency.md)
- [Errors and retries](guides/errors_and_retries.md)
- [Phoenix LiveDashboard metrics](guides/live_dashboard.md)
- [Broadway and Oban integration](guides/broadway_and_oban.md)
- [Cheatsheet](guides/cheatsheet.cheatmd)
- [Speculative fan-out](guides/speculative_fan_out.md)
- [Confidence-gated routing](guides/confidence_gated_routing.md)
- [Composite scoring](guides/composite_scoring.md)
- [Design notes](DESIGN.md) on what differs from the official SDKs and why

## License

MIT. See the LICENSE file in the repository.
