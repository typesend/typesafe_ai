# Design notes

Why this library is shaped the way it is, and the decisions behind the parts that are
not obvious from the code alone.

## Architecture

The library is two layers. `TypeSafeAPI.HTTP` is the thin layer: it knows about Req,
retries, and the TypeSafe AI System One HTTP API, and returns raw-ish results. `TypeSafeAPI`
(the facade) and `TypeSafeAPI.SystemOne` are the typed layer: they validate input, encode it
in the shape the API expects, call the HTTP layer, and decode the response into typed
structs (`TypeSafeAPI.Result`, `TypeSafeAPI.Answer.*`, `TypeSafeAPI.Error`). Callers who want raw
maps can use `TypeSafeAPI.HTTP` directly; everyone else uses `TypeSafeAPI`.

`TypeSafeAPI.Client` is a plain struct, not a supervised process. There is no `GenServer`,
no application-managed state, and no client registry: a client is just configuration
(base URL, API key, Req options, retry policy) threaded explicitly through calls. This
keeps the library usable from anywhere — LiveView, Task, Oban job, IEx — without asking
the caller to start anything under a supervision tree first.

`TypeSafeAPI.SystemOne` holds the `evaluate/4` pipeline (validate, encode, post, decode)
alongside `prepare/1` and `evaluate_prepared/4`, which let `evaluate_many/4` validate and
encode a question set once instead of once per state. The prepared set is a
`TypeSafeAPI.SystemOne.Prepared` struct, so the functions that take one match on it instead
of trusting the shape of a bare map.

## Why Req

The library is built on [Req](https://hexdocs.pm/req), and that is not a free choice: Req
brings Finch, Mint, NimblePool, Jason, and MIME along with it. Counting only runtime
dependencies (excluding `credo`, `dialyxir`, and `ex_doc`, which are dev/test tooling, and
excluding `plug`, which this library also declares but only as `optional: true`, needed
solely for `TypeSafeAPI.Test`), `mix deps.tree --format plain` shows this client pulling in
9 packages:

| package         | why it's here                                    |
| ---------------- | ------------------------------------------------- |
| `req`            | the HTTP client itself                             |
| `finch`          | Req's HTTP connection pool manager                 |
| `mint`           | Finch's low-level HTTP/1 and HTTP/2 implementation |
| `nimble_pool`    | Finch's connection pooling                         |
| `hpax`           | Mint's HTTP/2 header compression (HPACK)           |
| `jason`          | Req's default JSON codec (present, unused here)    |
| `mime`           | Req and Finch's MIME type handling                 |
| `nimble_options` | this library's own option validation, and Finch's  |
| `telemetry`      | this library's own spans, and Req/Finch/Plug's     |

For comparison, a bare Mint-based client would pull in 2 packages (`mint` and `hpax`), and
a codegen-based rival built against the OpenAPI spec pulls in roughly 23, once its
generated request/response validation, its own HTTP client choice, and their transitive
dependencies are counted. Req sits in between: heavier than hand-rolled Mint, much lighter
than a full codegen stack.

That tradeoff is worth it for three reasons:

- **Req is the Elixir ecosystem's default.** Most Elixir services that talk HTTP already
  depend on it, directly or transitively, so for many users this library adds no new
  dependency tree at all — and for everyone else, Req is a dependency they are likely to
  meet again.
- **The offline test stubs are built on it.** `TypeSafeAPI.Test` stubs requests with
  `Req.Test`, which is what makes `TypeSafeAPI.evaluate/4` testable against canned answers
  with no fixtures, no HTTP mocking library, and no real network access. That convenience
  comes from Req specifically, not from HTTP clients in general.
- **It keeps this library's own transport code small.** Connection pooling, HTTP/2,
  timeouts, and TLS are Finch and Mint's problem, not this library's. The alternative —
  hand-rolled connection ownership on top of bare Mint — would trade five dependencies for
  a few hundred lines of code this library would then have to maintain and get right.

A few things worth knowing if you're weighing this yourself:

- **Req is pre-1.0**, but stable in practice: its public API has been steady across the
  0.x line this library has tracked, and the underlying Finch/Mint stack is used in
  production well beyond Req itself (Phoenix's own test client, for one).
- **Jason ships transitively but is unused.** This library encodes and decodes JSON with
  Elixir's built-in `JSON` module (see "Differences from the official SDKs" below); Req
  0.7 still declares Jason as a hard dependency, so it appears in `mix.lock` regardless.
- **You can share an existing Finch pool** instead of letting this library start its own,
  with the `finch:` client option. That's the escape hatch if your application already runs
  Finch and you'd rather not spin up a second pool, and the only way to control pool size.
  It is a first-class option rather than something passed through `req_options` because Req
  refuses `:finch` and `:connect_options` together: the client has to know, so it can stop
  sending the connect timeout it otherwise sets on every request.
- **The library starts one process.** `TypeSafeAPI.Application` supervises a single
  `Task.Supervisor` for `TypeSafeAPI.FanOut`, so batch tasks are unlinked from the caller.
  An `async_stream` over linked tasks propagates any exit other than a kill-on-timeout, so
  one raising task would take down the calling process and every sibling request with it —
  the opposite of what `on_error: :collect` promises.

## Atom-key safety and the Keys registry

Decoded API responses are handed to callers as structs with atom keys, which means
turning JSON object keys into atoms somewhere. Elixir atoms are not garbage collected, so
converting arbitrary server-controlled strings to atoms is a memory-exhaustion risk.
`TypeSafeAPI.Keys` is a small fixed registry of the atoms this library will ever need
(`:model`, `:input_tokens`, criteria keys, and so on); decoding only ever looks up
already-known atoms, never calls `String.to_atom/1` on response data. A response field
this library does not recognize is dropped rather than atomized.

## Ordered JSON encoding

Choice option order and question order matter to the model: the API reads them as
presented, not as an unordered set. Elixir's `Map` does not preserve insertion order, so
anything that needs to survive to the wire in caller order needs its own carrier.
`TypeSafeAPI.JSON.OrderedObject` is a tiny struct with a `JSON.Encoder` implementation for
exactly this; `Question.encode_all/1` also uses it for the top-level `questions` object
so question order on the wire matches caller order. Because the `questions` object is a
list of pairs rather than a map, two ids that collide on the wire (`:billing` and
`"billing"`, or the same id twice) would emit a duplicate JSON key instead of overwriting
one another, so `Question.normalize/1` rejects them with a `:validation` error, the way
`Choice.validate/1` already rejected duplicate option keys.

`Question.encode_all/1` returns a `TypeSafeAPI.JSON.Encoded`, which serializes the ordered
object once at construction and encodes as those cached bytes wherever it appears. That
is what makes a prepared question set cheap across states: `evaluate_many/4` splices the
same iodata into every request body instead of walking and serializing the question set
once per state. The bytes and the term are captured together and nothing mutates the
struct afterwards, so they cannot drift.

`Choice.new/2` rejects maps outright. It once accepted one up to 32 entries, on the belief
that small maps preserve insertion order; they do not — a small atom-keyed map iterates by
atom index, so the order was arbitrary at any size. Option order is what the model sees, so
criteria are keyword lists or `[{key, description}]` lists only (with no limit of their own,
aside from the API's 255-option cap), and a map raises `ArgumentError` at construction.

## Score level shapes

A Score level may be a plain string or a `{label, description}` pair. The API itself has
no label concept — a level is just a description string — so a `{label, description}`
level is sent to the wire as a structured description (`{"label": ..., "description":
...}`), which the API accepts as an opaque description value, and the label is what
`TypeSafeAPI.Answer.Score.label` and `levels` report back. Plain string levels report the
description itself as the label. `label` is always a string: a structured level without a
label falls back to a truncated `inspect/1` of itself, and the answer's `description`
field always carries the winning level exactly as written, independent of what the label
computation does with it.

`TypeSafeAPI.Answer.Score.normalized/1` (score divided by the top level index) exists because
the composite-scoring pattern needs it and every caller would otherwise write it by hand.

`Answer.gate/2` on a Noul answer uses `max(noul, 1 - noul)`, since Noul answers carry no
separate `confidence` field — a confident "no" gates the same as a confident "yes".

## Errors and retries

503 maps to `:overloaded`, alongside 529 (the header TypeSafe AI's own docs call out for
overload). Other 5xx map to `:server_error`. An HTTP 408 maps to `:timeout`: the server is
reporting the same thing a transport timeout does, and making callers match two types for
"nothing came back in time" buys nothing. That leaves `:unexpected` for its real meaning —
a response this library could not interpret — rather than as a bucket holding both a
broken API and a broken parse. `TypeSafeAPI.Error.retryable?/1` tells the transient types
apart without a caller re-deriving the retry policy from `status`.

A connection-pool checkout timeout deserves its own note. Finch does not return an error
for it; Finch's HTTP/1 pool reraises a bare `RuntimeError`, which Req never normalizes and
which therefore escapes the call as an exception — breaking the "every failure is an
`{:error, %Error{}}`" promise exactly when the pool is saturated.
This library wraps the Req adapter to turn it back into
`%Req.HTTPError{reason: :pool_timeout}`, which maps to `:timeout` and is always retried
regardless of method, since the request was never sent.

Two response shapes carry error detail: 422 responses have `detail` as a list, 400
responses have it as a map (`error_type`, `message`). `TypeSafeAPI.Error` reads both. Every
400 seen in practice was a caller mistake (unknown model, too many Choice options), so 400
maps to `:validation`.

Per-call options are validated with `NimbleOptions.validate!/2` and raise on misuse, while
questions and state return `{:error, %TypeSafeAPI.Error{type: :validation}}` instead of
raising. The distinction is deliberate: options are code written by the developer calling
the library, while questions and state are data that may ultimately come from end users
and should fail as a value, not a crash.

Constructors never validate. `noul/2`, `choice/2`, and `score/2` build structs and nothing
more; `evaluate/4` validates the whole question set once and returns an error value. An
earlier idiom pass briefly made `noul/2` raise on a misspelled criteria key so a typo could
not be dropped silently; that was reverted in favor of the validator reporting the bad
key, plus `TypeSafeAPI.Question.validate!/1` for callers who build questions at compile time
and want the raise at that line.

`instructions` is optional on every question type, matching the API: only `type` (plus
`criteria`, for a Choice or a Score) is required. Rather than adding a separate option, the
existing first positional argument simply accepts `nil` — and `noul/0,1` default it — so
every existing call site keeps working. A `nil` is dropped from the encoded wire map rather
than sent as `null`, since an absent key and a null one are not the same request.

## Timeout options for batch callers

`evaluate_many/4` has two separate timeout knobs. `:timeout` is the single HTTP attempt
timeout, exactly as in `evaluate/4`; `:task_timeout` caps one state's whole task. They
default so that a task is never killed while a legitimate retry is still in flight:
`:task_timeout` defaults to the retry budget plus one attempt timeout (40 s with
defaults), or 60 s when the budget is disabled. This split exists because a caller who
wants to shorten a single HTTP attempt (say, to fail fast on one slow question) should not
have to build a second client with a different Req timeout just to do it.

The names matter more than the split. An earlier version had `:timeout` mean the task and
`:attempt_timeout` mean the attempt, so `evaluate_many(client, states, qs, timeout: 5_000)`
written by analogy with `evaluate/4` silently meant something else — same name, same unit,
different thing, no error. The batch function now keeps `:timeout` meaning what it means
everywhere else, and the new concept got the new name.

The retry budget is a gate on *starting* a retry, not a deadline on an attempt:
worst-case wall time is budget plus one attempt timeout, and `TypeSafeAPI.FanOut` derives its
default task timeout from exactly that sum, so the two defaults have to move together.

Neither knob touches the connect timeout. Req picks a Finch pool by `connect_options`, so
feeding a per-call timeout into it starts a pool per distinct value and throws connection
reuse away. The connect timeout is therefore a client setting, `connect_timeout` (default
5 000 ms), and the per-call `:timeout` sets `receive_timeout` only: calls that differ in
timeout still share one pool.

## Differences from the official SDKs

- **Milliseconds everywhere.** The official Python SDK's retry policy uses float seconds
  (`backoff_initial: 0.5`, `timeout: 30.0`). Elixir convention is integer milliseconds
  (`Process.sleep/1`, Req timeouts, `Task.async_stream`), so `TypeSafeAPI.Retry` uses
  `backoff_initial: 500`, `backoff_max: 5_000`, `budget: 30_000`. The semantics are
  identical.
- **Jason is present transitively, but unused.** The library uses Elixir's built-in
  `JSON` module for all encoding and decoding, but Req 0.7 declares Jason as a hard
  dependency, so it appears in `mix.lock`. Nothing here calls it. Req's own body decoding
  is disabled (`decode_body: false`) so responses go through `JSON.decode/1`.
- **Connection-error retries are off for `POST /v1/systemone`.** The official SDKs retry
  them unconditionally, but a connection that is reset or times out may still have
  reached the server, the endpoint is not idempotent, and there is no idempotency key,
  so a retry can double-bill an evaluation. `retry_connection_errors` defaults to
  `:auto`, which `TypeSafeAPI.Retry.for_method/2` resolves to `true` for `GET
  /v1/models` and `false` for `POST` when the policy is attached. `retry_timeout_errors`
  defaults to `:auto` for the same reason and a stronger one: a timed-out attempt is the
  failure *most* likely to have reached the server. An explicit boolean, on the client or
  per call, always wins, and status-driven retries (`429`, `503`, `529`, `Retry-After`)
  are untouched.
- **A server-requested delay is clamped, not obeyed.** `retry-after: 0`, an empty header
  and an HTTP date a skewed clock reads as past all parse to zero, and honoring that
  verbatim turns the policy into a tight loop against a server that is already struggling
  while the wall-clock budget never advances. The honored delay is floored at
  `retry_after_min` (100 ms) and capped at `retry_after_max` (60 s), and otherwise obeyed:
  a server asking for less than the backoff schedule gets it, since it knows its own load.
- **`plug` is an optional dependency.** `TypeSafeAPI.Test` builds on `Req.Test`, which needs
  Plug to construct responses. Users who want the stubs add `{:plug, "~> 1.16", only:
  :test}`; everyone else does not pay for it.

## Verified against the live API (2026-09-17)

A live run with a real key settled several things the docs left open:

- **`jev-latest` and `jev-preview` both resolve to a versioned id** such as
  `jev-1.13.0`, which is what `result.model` reports. The bare id `jev`, shown in the
  Python usage docs, is rejected with a 400 "Unknown model".
- **Limits are enforced server-side:** 256 Choice options and 11 Score levels are
  rejected, so `Choice.validate/1` enforces 255 and Score keeps its 2 to 10 bound. A
  one-level Score is accepted by the API but still rejected locally, since it cannot
  produce a meaningful score.
- **400 responses carry `detail` as a map** (`error_type`, `message`), unlike 422s whose
  `detail` is a list. `TypeSafeAPI.Error` reads both, and 400 maps to `:validation` since
  every 400 seen was a caller mistake (unknown model, too many options).
- **`x-typesafe-request-id` is on every response**, success included, so
  `TypeSafeAPI.Result` carries `request_id` and `TypeSafeAPI.HTTP.request/5` exposes the full
  response for raw callers.
- **`release_date` on the models endpoint is a full ISO 8601 datetime**, while the
  schema describes it as "formatted as YYYY-MM-DD". `TypeSafeAPI.Model` normalizes it to
  the `Date` the schema promises, reading the date part as written rather than shifting
  it into UTC, and keeps the original string on `release_date_raw`. An alias with an
  unparseable date leaves `release_date` `nil`.
- **The API knows a `bounding_box` question type** that is not in the public docs. This
  library does not model it; a request with an unknown type is rejected locally.

## Verified against the live docs (2026-09-16)

- **Models endpoint** is `GET /v1/models`, returning `{"models": [{name, description,
  release_date}]}`. The public API reference does not document it; the path and shape
  come from the official Python SDK's constants and generated schema.
- **`retry-after-ms` beats `Retry-After`** when both are present. The Python SDK checks
  `retry-after-ms` first. `Retry-After` may be seconds (fractional allowed) or an HTTP
  date; negative or unparseable values are ignored and backoff applies.
- **Usage tokens are required, and this library still tolerates their absence.** The
  OpenAPI schema requires `usage` on every response, with `input_tokens` and
  `output_tokens` both required non-nullable integers. `TypeSafeAPI.Usage` nonetheless
  reports `nil` for a missing or malformed count, and `TypeSafeAPI.Result` decodes a
  missing `usage` to an empty one: a correct set of answers is not worth failing over a
  token count that drifted. That is a defensive choice, not something the spec permits,
  and `test/typesafe_api/result_test.exs` pins the spec so the drift stays visible.
- **Score takes 2 to 10 levels**, not just "at least 2". Local validation enforces both
  bounds.
- **Descriptions may be structured.** Instructions, Choice option descriptions, Score
  level descriptions, and Noul criteria all accept a string, map, or list. Validation
  allows all three.
- **The API accepts no per-request timeout or extra behavioural headers.** The official
  SDKs send `X-TypeSafe-SDK`, `X-TypeSafe-Runtime`, and `X-TypeSafe-Retry-Count` for
  diagnostics. This library sends `User-Agent` and `X-TypeSafe-Retry-Count` on retries.

## Documentation conventions

Every public options keyword list is a NimbleOptions schema exposed through an
`options_schema/0`, and the facade's docs interpolate `NimbleOptions.docs/1` at the call
site rather than linking away, so `TypeSafeAPI.evaluate/4` reads the same as the module that
implements it. Every module belongs to a `groups_for_modules` group in `mix.exs`; a module
with no group is a docs bug.

An adversarial docs review (three personas: first-time integrator, on-call engineer, SDK
expert) drove the README's onboarding section, the error and telemetry field prose, the
end-to-end timeout timeline in `TypeSafeAPI.Retry`, and the "Writing good questions" section.

## Toolchain

CI runs OTP 27 and 28. Nothing in the library is OTP-version specific.

## Things worth revisiting

- **Rate limits are unpublished.** `evaluate_many/4` defaults to `max_concurrency: 8` as
  a guess. When TypeSafe publishes limits, raise the default and document it.
- **Retry counting on `Req.Test` transport errors.** The custom retry step re-runs the
  full Req pipeline, including request steps, on each retry. That is what Req's own step
  does; it is worth keeping in mind if anyone adds a request step with side effects.
- **HTTP-date `Retry-After` parsing** is a small RFC 7231 fixdate parser in
  `TypeSafeAPI.Retry`, so the library does not depend on `inets`.

## Refreshing the OpenAPI snapshot

`priv/openapi.json` is a vendored, pretty-printed copy of TypeSafe's OpenAPI document
(currently `info.version` `0.2.0`). It ships in the Hex package (see `files` in
`mix.exs`) and is the source of truth for `test/typesafe_api/openapi_spec_test.exs`,
which asserts the request/response shapes this client relies on: the two paths and
their bearer security, which question/answer fields are actually required versus
optional, the `minItems`/`minProperties` bounds, and the 422 `HTTPValidationError`
shape. If TypeSafe changes the API in a way that would break this client, that test is
meant to fail first.

To refresh it: obtain the current `openapi.json` from TypeSafe AI (their docs site or
OpenAPI endpoint), replace `priv/openapi.json` with it, then run

    mix test test/typesafe_api/openapi_spec_test.exs

and fix any failures — either the client (if the API genuinely changed underneath it)
or the test (if a local policy, like the Score 2-to-10 level bound, is intentionally
stricter than the spec and needs a fresh comment explaining why).
