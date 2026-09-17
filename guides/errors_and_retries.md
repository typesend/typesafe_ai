# Errors and retries

Every call into this library returns `{:ok, result}` or `{:error, %TypeSafeAPI.Error{}}`
(the bang variants, like `TypeSafeAPI.evaluate!/4`, raise the same struct instead). This
guide covers every error `type`, what gets retried automatically before you ever see an
error, and how to tune or observe that retry behavior. For a first working call, see
[Getting started](getting_started.md).

## Error types

`TypeSafeAPI.Error` has one `type` field to match on:

| `type`         | when                                                                  | retried automatically |
| -------------- | ---------------------------------------------------------------------| ---------------------- |
| `:auth`        | HTTP 401 — the API key is missing or invalid                         | no                      |
| `:validation`  | HTTP 400 or 422, or a problem caught locally before sending anything | no                      |
| `:rate_limited`| HTTP 429                                                              | yes                     |
| `:overloaded`  | HTTP 503 or 529 (TypeSafe's own overload signal)                     | yes                     |
| `:server_error`| any other 5xx — the API failed, not the request                      | yes                     |
| `:timeout`     | an attempt exceeded its timeout, HTTP 408, or a pool checkout timed out | depends — see below   |
| `:connection`  | the request could not reach the server at all                        | depends — see below     |
| `:unexpected`  | anything this library could not make sense of: an unrecognized status, an undecodable body | no |

`TypeSafeAPI.Error.retryable?/1` answers that last column for an error you are
holding, so a caller does not have to re-derive the retry policy from `status`.

`:validation` covers two different situations: a request the API rejected outright (a body
that failed its own validation — for example an unknown model or too many Choice options)
and a problem this library caught locally before sending anything (for example a Score
built with one level). Local validation errors have `status: nil`. Build questions once
(at compile time, when you can) and validate them eagerly with
`TypeSafeAPI.Question.validate!/1` so a malformed question raises `ArgumentError` at the
line that wrote it, instead of surfacing as a runtime `{:error, _}` at call time.

An HTTP `408` is retried like the other retryable statuses (`429`, `5xx`), and surfaces as
`:timeout` when it survives every retry. The server is telling you the same thing a
transport timeout does — nothing came back in time — so matching on `:timeout` catches
both, rather than making callers remember which side of the wire the clock was on.

503 and 529 both map to `:overloaded`; 529 is the header TypeSafe's own docs call out for
overload, and 503 is the conventional HTTP status for the same condition. Every other
`5xx` maps to `:server_error`, which is retried just as automatically. `:unexpected` is
kept for responses this library could not interpret at all, so seeing one means something
changed on the wire — not that the API is having a bad day.

Every `TypeSafeAPI.Error` also carries:

- `status` — the HTTP status, or `nil` when no response was involved.
- `message` — a one-line summary. For a 422, the API returns `detail` as a list of
  `%{"loc" => [...], "msg" => ...}` entries; these are joined into something like
  `body.questions.dept.criteria: Field required; ...` so the offending field is readable
  without parsing `body` yourself. A 400's `detail` is a map (`error_type`, `message`)
  instead, and is read directly.
- `body` — the decoded JSON error body, the raw string if it wasn't JSON, or `nil`. Worth
  logging for `:unexpected` errors, since it shows what changed on TypeSafe's end.
- `request_id` — the `x-typesafe-request-id` response header. Quote this when contacting
  TypeSafe support about a specific call.
- `retry_after_ms` — the wait the server asked for, kept on the error even after retries
  are exhausted, so you can back off before the next call.

```elixir
case TypeSafeAPI.evaluate(client, state, questions) do
  {:ok, result} ->
    handle(result)

  {:error, %TypeSafeAPI.Error{type: :rate_limited, retry_after_ms: ms} = error} ->
    Logger.warning("typesafe rate limited (#{error.request_id}), retry after #{ms}ms")
    :retry_later

  {:error, error} ->
    Logger.error("typesafe request failed (#{error.request_id}): #{Exception.message(error)}")
    :error
end
```

`request_id` is also on `TypeSafeAPI.Result`, so you can log it on success too:

```elixir
{:ok, result} = TypeSafeAPI.evaluate(client, state, questions)
Logger.info("typesafe call ok, request_id=#{result.request_id}")
```

You don't have to thread it through by hand: every request runs inside a
`[:typesafe_api, :request, :stop]` telemetry event whose metadata includes `error` (a
`TypeSafeAPI.Error`, or `nil` on success). `TypeSafeAPI.Telemetry.attach_logger/1` attaches
a handler that logs one line per request — status, duration, retry count, and, on
failure, the error message — from that event. See `TypeSafeAPI.Telemetry` for the full
metadata shape and how to attach your own handler instead.

## Retry policy

Retries mirror the official TypeSafe SDKs, reimplemented as a `Req` step
(`TypeSafeAPI.Retry`) because Req's own retry step counts attempts, not wall time, and the
official SDKs bound the whole call by a *total* time budget.

| option                     | default             | meaning                                    |
| -------------------------- | ------------------- | ------------------------------------------ |
| `max_retries`              | `2`                 | retries after the first attempt            |
| `backoff_initial`          | `500` ms            | first delay, doubled each retry            |
| `backoff_max`              | `5_000` ms          | ceiling for the exponential delay          |
| `backoff_jitter`           | `0.25`              | fraction randomly subtracted from a delay  |
| `statuses`                 | `408, 429, 500-599` | HTTP statuses that trigger a retry         |
| `respect_retry_after`      | `true`              | honor `retry-after-ms` and `Retry-After`   |
| `retry_after_min`          | `100` ms            | floor on a server-requested delay          |
| `retry_after_max`          | `60_000` ms         | ceiling on a server-requested delay        |
| `retry_connection_errors`  | `:auto`             | retry when the server cannot be reached    |
| `retry_timeout_errors`     | `:auto`             | retry when a single attempt times out      |
| `budget`                   | `30_000` ms         | wall time before another retry starts      |

A server-requested delay is clamped into `retry_after_min..retry_after_max` and otherwise
honored as given, even when it is shorter than the backoff schedule. The floor is what stops
`retry-after: 0`, an empty header, or an HTTP date a skewed clock reads as past from turning
the policy into a tight loop against a server that is already struggling.

The budget gates whether another retry is *started*, not how long the attempt it starts
may run, so a call can overrun it by up to one attempt timeout.

Tune it with `retry:` on the client (applies to every call) or per call (overrides the
client for that one call):

```elixir
TypeSafeAPI.new(api_key: key, retry: [max_retries: 4, budget: 60_000])
TypeSafeAPI.evaluate(client, state, questions, retry: [max_retries: 0])
```

### `retry-after-ms` vs. `Retry-After`

When a response carries both headers, `retry-after-ms` wins (matching the Python SDK).
`Retry-After` may be seconds (fractional allowed) or an HTTP date; a negative or
unparseable value is ignored and exponential backoff is used instead.

### The total budget

`budget` (30 seconds by default) bounds the entire call: the first attempt, every retry,
and every delay in between. It gates the *decision to start* a retry — elapsed time plus
the next delay must land under the budget — but it does not interrupt an attempt already
in flight and does not shorten that attempt's own timeout. So the worst case for a call is
roughly `budget` plus one attempt timeout: about 40 seconds with the defaults (30 s budget
+ 10 s client timeout). `TypeSafeAPI.FanOut` derives its own default per-state task timeout
from that same sum, so if you change one you likely want to look at the other for batch
calls (`TypeSafeAPI.evaluate_many/4`'s `:timeout` option).

A worked example — three `529`s in a row, each answered quickly, with default settings:

| time    | what happens                                                    |
| ------- | ---------------------------------------------------------------- |
| 0.0 s   | attempt 1 goes out                                                |
| 0.4 s   | 529 back; retry 1 allowed, sleep 375 to 500 ms                    |
| 0.9 s   | attempt 2 goes out                                                |
| 1.3 s   | 529 back; retry 2 allowed, sleep 750 ms to 1 s                    |
| 2.3 s   | attempt 3 goes out                                                |
| 2.7 s   | 529 back; `max_retries` reached, so the call returns              |

The caller gets `{:error, %TypeSafeAPI.Error{type: :overloaded, status: 529}}` in under 3
seconds; the budget never came into it.

A single `429` carrying `Retry-After: 20` plays out differently: the header wins over
backoff, so the delay is 20 000 ms. At 0.4 s elapsed, the budget check passes (0.4 s + 20 s
is under 30 s), the step sleeps 20 seconds, and attempt 2 goes out at 20.4 s. If that
attempt also comes back 429 at 20.8 s, the next delay is another 20 s — but 20.8 s + 20 s
is past the 30 s budget, so the call returns the 429 rather than retrying again.
`retry_after_ms` is still on the returned error, so the caller can back off itself.

## Connection errors and replay

A *connection error* is a failure with no response behind it at all: the connection was
refused or reset, DNS or the TLS handshake failed, or the attempt timed out waiting for a
response. `Req` surfaces these as `Req.TransportError` and `Req.HTTPError`, which this
library maps to `TypeSafeAPI.Error` types `:connection` and `:timeout`.

These are ambiguous in a way a `429` or `503` is not: a refused connection never reached
the server, but a reset connection or a timeout may well have — the request could have
been received, the evaluation run and billed, with only the reply lost. Retrying it then
runs it a second time. `POST /v1/systemone` is not idempotent and the API has no
idempotency key, so a retry here can double-bill an evaluation.

`retry_connection_errors` therefore defaults to `:auto`, resolved per request against the
HTTP method (`TypeSafeAPI.Retry.for_method/2`):

- `GET` (`/v1/models`) — resolves to `true`. Reads are safe to replay.
- `POST` (`/v1/systemone`) — resolves to `false`. A connection error is returned to the
  caller as `{:error, %TypeSafeAPI.Error{type: :connection}}`, and it's the caller who
  decides whether re-running the evaluation is worth the risk of a duplicate charge.

Opt in, per call or on the client, where you'd rather have the answer than avoid the
possible second charge:

```elixir
TypeSafeAPI.evaluate(client, state, questions, retry: [retry_connection_errors: true])
TypeSafeAPI.new(api_key: key, retry: [retry_connection_errors: true])
```

An explicit `true` or `false` is never overridden by the method-based default.

`retry_timeout_errors` is a separate setting that defaults to `:auto` the same way, and
for a stronger reason: an attempt that timed out is the failure *most* likely to have
reached the server and been billed, so replaying a `POST` on a timeout is the replay
worth guarding hardest. Set it to `true` where you would rather have the answer.

The exception is a connection-pool checkout timeout: the request never left the process,
so it is retried on any method regardless of either setting.

None of this affects retries the server itself asked for. A `429`, `503`, or `529` is a
response: the request was received and rejected, nothing ran, and replay is safe. Those
statuses — and `Retry-After` — are honored exactly as described above regardless of
`retry_connection_errors`.

## Per-call vs. client-level retry options

Retry options can be set once on the client, and overridden per call:

```elixir
# every call from this client gets these defaults
client = TypeSafeAPI.new(api_key: key, retry: [max_retries: 4, budget: 60_000])

# this one call never retries, regardless of the client's policy
TypeSafeAPI.evaluate(client, state, questions, retry: [max_retries: 0])

# this one call opts into replaying connection errors
TypeSafeAPI.evaluate(client, state, questions, retry: [retry_connection_errors: true])
```

A per-call `retry:` keyword list layers onto the client's policy: it names the settings to
change, and every other setting keeps the value the client was built with. In the example
above the one call with `max_retries: 0` still has the client's `budget: 60_000`.

Pass a `%TypeSafeAPI.Retry{}` instead when you mean to replace the policy wholesale — a
struct is a finished policy, a keyword list is a set of changes. Both `TypeSafeAPI.new/1`'s
and `TypeSafeAPI.HTTP.post/4`'s `retry:` option accept either.

See `TypeSafeAPI.Retry` for the full moduledoc, including the option name mapping against
the official SDKs and the timeout math for `TypeSafeAPI.FanOut`.
