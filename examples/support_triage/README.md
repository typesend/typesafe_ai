# Support triage example

A small Mix application that routes inbound support messages with one
`TypeSafeAPI.evaluate/4` call, and whose entire test suite runs **offline**: no API
key, no network, no recorded fixtures.

That is the point of the example. Most AI client libraries leave you choosing
between hitting a paid API from CI, maintaining a cassette directory, or mocking
at a layer so low that the test no longer exercises your decoding. `TypeSafeAPI.Test`
stubs by question id and builds the same structs a real response decodes into,
so the code under test is the code that runs in production.

## What it does

`SupportTriage.triage/2` asks three questions about one message, in a single
request:

| id             | type   | asks                                    |
| -------------- | ------ | --------------------------------------- |
| `:urgent`      | Noul   | is the customer blocked right now?      |
| `:dept`        | Choice | billing, technical, or sales?           |
| `:frustration` | Score  | calm, annoyed, or angry?                |

Then it gates on confidence with `TypeSafeAPI.Answer.gate/2` and decides:

- `{:escalate, dept}` — blocked, or angry enough to need a person today.
- `{:queue, dept}` — routed to a team's normal queue.
- `{:needs_human_review, reasons}` — at least one answer did not clear the
  confidence bar, so the app refuses to guess. Each reason carries the answer
  and whether it was borderline (`:review`) or close to a coin flip
  (`:escalate`), which is something a classifier returning a bare label cannot
  tell you.

`SupportTriage.triage_many/3` does the same for a list of messages with
`TypeSafeAPI.evaluate_many/4`, which validates and encodes the question set once
into a `TypeSafeAPI.SystemOne.Prepared` struct and reuses it for every message.
Outcomes come back in input order, and one failed message does not sink the
batch.

## Run the tests offline

```sh
mix deps.get
mix test
```

No `TYPESAFE_API_KEY` needed, and none is used even if one is set: every test
builds its client with `TypeSafeAPI.Test.client/1`. The suite covers the
escalation path, the queue path, the low-confidence path, batch ordering,
partial batch failure, and a `429` surfacing as
`{:error, %TypeSafeAPI.Error{type: :rate_limited}}`.

Two stubbing styles appear in `test/support_triage_test.exs`:

- `TypeSafeAPI.Test.stub/2` when one set of answers covers the test.
- A plain `Req.Test.stub/2` function that answers differently per state, for the
  batch tests. It shows the wire shape `TypeSafeAPI.Test` builds for you.

## Run the demo

```sh
mix support_triage.demo
```

Triages a handful of sample messages and prints each decision. With
`TYPESAFE_API_KEY` set it calls the real API; without one it falls back to the
same stubs the tests use. The first line of output says which mode it ran in.

## Layout

```
lib/support_triage.ex            questions, gating, routing
lib/support_triage/demo.ex       sample messages and their offline stubs
lib/mix/tasks/support_triage.demo.ex
test/support_triage_test.exs     the whole suite, offline
```

The library is a path dependency (`{:typesafe_api, path: "../.."}`), so the
example always builds against the working tree rather than a published release.
