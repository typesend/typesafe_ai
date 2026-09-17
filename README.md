# typesafe_ai (Go)

Unofficial Go client for the TypeSafe AI API. Not affiliated with or endorsed by TypeSafe AI.

TypeSafe AI is a hosted API that answers typed questions about a piece of text or
structured data — yes/no, multiple-choice, or a position on a scale — and returns
calibrated probabilities instead of freeform prose, so the answer can drive code directly.

Sign up for an API key at [typesafe.ai](https://typesafe.ai). No key yet? Skip to
[Testing your code](#testing-your-code): `typesafetest` runs every example on this page
offline, no key or network required.

TypeSafe's [System One](https://docs.typesafe.ai/concepts/system-one) models are small,
fast models built for calibrated decisions, not text generation: they answer typed
questions about a piece of state and return probabilities instead of prose. You ask three
kinds of question:

| question | asks for                                  | answer                                           |
| -------- | ------------------------------------------ | ------------------------------------------------ |
| Noul     | yes or no (Noul is TypeSafe's name for it) | probability of yes                               |
| Choice   | one option from a set you define          | the option, a probability per option, confidence |
| Score    | a position on an ordered scale you define | a score, a probability per level, confidence     |

`state` is what the questions are about: a string, or JSON-shaped data. `confidence` is a
number from 0 to 1 saying how peaked the probability distribution is; the API returns none
for Noul answers, so `NoulAnswer.Confidence()` uses `max(noul, 1-noul)` as a local
convention.

This module lives on the `go-sdk` branch of the repository; the Elixir client lives on
`main`. Standard library only, no dependencies.

## Installation

```sh
go get github.com/typesend/typesafe_ai@go-sdk
```

Requires Go 1.23 or later.

## Quick start

Build one `*typesafe.Client` at startup and share it across goroutines; see
[Where to build the client](#where-to-build-the-client) below.

```go
import typesafe "github.com/typesend/typesafe_ai"

client, err := typesafe.New() // reads TYPESAFE_API_KEY, TYPESAFE_BASE_URL, TYPESAFE_DEFAULT_MODEL
if err != nil {
	return err
}

// ctx is an ordinary context.Context: the one already flowing through your
// request handler or job, or context.Background() at the top level.
res, err := client.Evaluate(ctx, "Help! My payouts have been failing for 3 days.",
	typesafe.Questions{
		"urgent": typesafe.Noul("Does this convey urgency?",
			typesafe.WhenTrue("Explicitly time-sensitive"),
			typesafe.WhenFalse("No urgency expressed")),
		"dept": typesafe.Choice("Which team should handle this?",
			typesafe.Opt("billing", "Payments, invoicing, refunds"),
			typesafe.Opt("technical", "Bugs, outages, integrations"),
			typesafe.Opt("sales", nil)),
		"anger": typesafe.Score("How frustrated is the customer?",
			"Calm", "Frustrated", "Very angry"),
	})
if err != nil {
	var apiErr *typesafe.Error
	if errors.As(err, &apiErr) {
		log.Printf("%s (request %s)", apiErr, apiErr.RequestID)
		if apiErr.Type == typesafe.ErrRateLimited {
			time.Sleep(apiErr.RetryAfter)
		}
	}
	return err
}

fmt.Println(res.Model)             // "jev-1.13.0" (what "jev-latest" resolved to)
fmt.Println(res.Usage.InputTokens) // 312
fmt.Println(res.RequestID)         // "req_..." for support tickets

fmt.Println(res.Noul("urgent").Noul) // 0.92

d := res.Choice("dept")
fmt.Println(d.Choice)                  // "technical"
fmt.Println(d.Probabilities["billing"]) // 0.08
fmt.Println(d.Confidence())             // 0.82

a := res.Score("anger")
fmt.Println(a.Score, a.Level, a.Label) // 1.6 2 "Very angry"
fmt.Println(a.Levels)                  // [{Calm 0.05} {Frustrated 0.3} {Very angry 0.65}]
fmt.Println(a.Normalized())            // 0.8: score divided by the top level index

fmt.Println(typesafe.Gate(d, 0.8, 0.5)) // GateAct, GateReview, or GateEscalate
```

The typed accessors (`Noul`, `Choice`, `Score`) return nil when the id is absent or the
answer is another type; a type switch over `res.Answers[id]` works too.

### Level (argmax) vs Score (weighted)

`ScoreAnswer.Level` and `ScoreAnswer.Score` can disagree. `Level` is the argmax: whichever
level has the single highest probability. `Score` is the probability-weighted position
across every level (`sum(index * probability)`), which can land between two levels. For a
distribution like `{0: 0.45, 1: 0.10, 2: 0.45}`, `Level` picks index 0 (ties go to the
lower index) while `Score` comes out near 1.4 — nowhere near either mode. Use `Level` and
`Label` when you want a single discrete category; use `Score` (or `Normalized`, in
[Composite scoring](docs/patterns.md#composite-scoring)) when you want a number that
reflects the whole distribution, and check `Confidence()` either way before trusting a
distribution that isn't unimodal.

### Where to build the client

`typesafe.New` returns an immutable struct with no goroutines and no connection state of
its own (the `http.Client` inside holds the pool). Build one at startup and share it. Pass
`typesafe.WithHTTPClient` for proxies, custom transports, or pool tuning; its `Timeout`
field is ignored in favour of `typesafe.WithTimeout`, which bounds one attempt.

### Validate question sets at startup

A question set only needs building and validating once, even if it is evaluated many
times. `typesafe.Prepare` runs the same checks `Evaluate` runs (a Score with one level, a
Choice with a duplicate key, and so on) and returns a `*Prepared` to reuse:

```go
var triageQuestions = typesafe.Questions{ /* ... */ }

var prepared = func() *typesafe.Prepared {
	p, err := typesafe.Prepare(triageQuestions)
	if err != nil {
		panic(err) // a malformed question set is a programmer error, caught at startup
	}
	return p
}()

func triage(ctx context.Context, client *typesafe.Client, ticket string) (*typesafe.Result, error) {
	return client.EvaluatePrepared(ctx, ticket, prepared)
}
```

`Questions.Validate() error` runs the same checks without building a `*Prepared`, for an
init-time smoke test (`if err := triageQuestions.Validate(); err != nil { ... }`) when you
would rather keep evaluating with the plain `Questions` map via `Evaluate`.

### Models

`client.Models(ctx)` lists what the account can use, including the resolved id behind
`jev-latest`:

```go
models, err := client.Models(ctx)
for _, m := range models {
	fmt.Println(m.Name, m.Description, m.RawReleaseDate)
}
```

`typesafe.DefaultModel` ("jev-latest") is what `New` uses when `WithModel` and
`TYPESAFE_DEFAULT_MODEL` are both unset; the server resolves it to a specific versioned id
such as `jev-1.13.0` on every call, which is what `Result.Model` reports back. Pin a
version with `typesafe.WithModel("jev-1.13.0")` or `CallOptions.Model` if you need
reproducible behaviour across a model upgrade.

## Many states, one question set

```go
outcomes, err := client.EvaluateMany(ctx, states, questions, typesafe.ManyOptions{MaxConcurrency: 8})
// err is only set when the question set itself is invalid
for i, o := range outcomes {
	if o.Err != nil {
		log.Printf("state %d: %s", i, o.Err.Type)
		continue
	}
	use(o.Result)
}
```

Results come back in input order; a failed state never hides the others. The question set
is validated and encoded once. `MaxConcurrency` defaults to 8, which is a guess: TypeSafe
has not published rate limits. A fixed pool of `MaxConcurrency` workers processes the
input, so admission (not just in-flight requests) is bounded even for a very large slice.
Cancelling `ctx` stops unstarted states immediately and ends in-flight calls, including
retry sleeps; `EvaluateMany` returns once every worker has unwound, not the instant `ctx`
is cancelled.

For input too large to hold in memory, or to start acting on results before the slowest
state finishes, use `EvaluateStream` instead: it takes an `iter.Seq[typesafe.State]` and
returns an `iter.Seq2[int, typesafe.Outcome]` that yields as each state completes.

```go
for i, o := range client.EvaluateStream(ctx, states, questions, typesafe.ManyOptions{MaxConcurrency: 8}) {
	if o.Err != nil {
		log.Printf("state %d: %s", i, o.Err.Type)
		continue
	}
	use(o.Result)
	if enough(o.Result) {
		break // stops pulling from states and cancels the rest
	}
}
```

An invalid question set is reported as a single outcome at index `-1` rather than an error
return, since `EvaluateStream`'s signature has no room for one.

### Rate limits with many states

TypeSafe has not published a rate limit, so treat 429 as something that will eventually
happen at scale, not an error condition to special-case away:

- The client already retries 429 using the server's `Retry-After` (or `retry-after-ms`);
  you do not need to sleep and retry yourself for an isolated 429.
- When a batch comes back with some failures, resend only the failed states — keep the
  index alongside each `Outcome` and build a new `[]State` (or `iter.Seq`) from the ones
  where `o.Err != nil`, rather than re-running the whole batch.
- For very large inputs, prefer `EvaluateStream` over `EvaluateMany`: a rate limit or
  outage shows up as failed outcomes as they stream in, instead of only after the entire
  batch has been buffered.
- If 429s are frequent, lower `MaxConcurrency` before raising `RetryPolicy.Budget`; the
  budget only helps a request that started, it does not reduce how many you start at once.

## Errors and retries

Every failure is a `*typesafe.Error` with a `Type` you can switch on: `ErrAuth`,
`ErrValidation`, `ErrRateLimited`, `ErrOverloaded`, `ErrTimeout`, `ErrConnection`, or
`ErrUnexpected`. Local validation failures (a Score with one level, a Choice with one
option) have `Status == 0` and never reach the network. `Body` holds the decoded error
body, `RequestID` the `x-typesafe-request-id` header, and `RetryAfter` the server's
requested wait even after retries are exhausted.

A 422 body is joined field by field, so a validation failure reads like:

```
typesafe: validation (HTTP 422): questions.dept.criteria: at least 2 options are required; state: field required
```

Retries mirror the official SDKs: two retries with exponential backoff and jitter; 408,
429, and 5xx retried; `retry-after-ms` and `Retry-After` honoured (there is no cap on a
server-supplied delay other than the overall budget); connection and timeout errors
retried; and a 30 second total budget per call that includes every attempt and delay. The
budget gates the decision to start a retry, not an in-flight attempt, so the worst case is
roughly budget plus one attempt timeout (`typesafe.WorstCaseDuration`).

A 408 is retried like any other retryable status, but a 408 is a real HTTP response with no
recognised error type of its own, so once retries are exhausted the error you get back has
`Type == typesafe.ErrUnexpected` (with `Status == 408`), not `ErrTimeout`. `ErrTimeout` is
reserved for a request that never got a response at all (the client's own attempt timeout
or the caller's context expiring).

`RetryPolicy`'s zero value is the default policy: every zero field means "use the default"
rather than "disable this", so `RetryPolicy{MaxRetries: 5}` is a correct way to change one
setting and leave the rest at their defaults. Use `MaxRetries: -1` (or `typesafe.NoRetry()`)
to disable retries and `Budget: -1` to disable the budget:

```go
p := typesafe.DefaultRetryPolicy()
p.MaxRetries = 4
p.Budget = 60 * time.Second
client, _ := typesafe.New(typesafe.WithRetry(p))

noRetry := typesafe.NoRetry()
client.Evaluate(ctx, state, questions, typesafe.CallOptions{Retry: &noRetry, Timeout: 5 * time.Second})
```

`CallOptions.Header` can add request headers, but not override `Authorization`,
`Content-Type`, `Accept`, or `User-Agent`; those stay under the client's control so retries
and auth keep working regardless of what a caller passes in.

### The four timeouts

A single call has up to four different time limits stacked on top of each other, and it is
easy to set one without noticing another already applies. With the defaults (10s attempt
timeout, 30s retry budget):

1. **`CallOptions.Timeout` / `WithTimeout`** bounds one HTTP attempt (10s by default).
   Every retry gets its own fresh attempt timeout.
2. **`RetryPolicy.Budget`** bounds the whole call across every attempt and delay (30s by
   default). It gates the decision to *start* another retry, so the true worst case is
   `Budget` plus one more attempt timeout — about 40s with the defaults
   (`typesafe.WorstCaseDuration`).
3. **`ManyOptions.Timeout`** (used only by `EvaluateMany`/`EvaluateStream`) bounds one
   state's whole call, retries included. It defaults to that same worst case
   (`WorstCaseDuration` of the effective policy), so a legitimate retry sequence is never
   cut short by the per-state timeout. If you set `ManyOptions.Timeout` explicitly to less
   than `WorstCaseDuration(effectiveTimeout, effectivePolicy)`, a state that would otherwise
   have succeeded on its last retry instead comes back as `ErrTimeout` — the per-state
   timeout wins over the budget.
4. **`ctx`** bounds everything: it is checked before starting each attempt and each retry
   sleep, and is never retried past. A `ctx` deadline shorter than the budget effectively
   lowers the budget for that call.

## Telemetry

`typesafe.WithHooks` installs two callbacks. `OnResponse` fires once per call with status,
duration, retry count, token usage, request id, and `Err`. Every failure, including rate
limits and timeouts, arrives through `OnResponse` with `Err` set; there is no separate
exception path.

```go
hooks := typesafe.Hooks{OnResponse: func(i typesafe.ResponseInfo) {
	metrics.Observe("typesafe.request", i.Duration, "status", i.Status, "retries", i.RetryCount)
	if i.InputTokens >= 0 {
		metrics.Add("typesafe.tokens", i.InputTokens+i.OutputTokens)
	}
	if i.Err != nil {
		log.Printf("typesafe %s: %v", i.Path, i.Err)
	}
}}
```

`CallOptions.Metadata` (a `map[string]any`) flows through unchanged as
`RequestInfo.Metadata`, for labelling metrics with a tenant, trace id, or feature name
without inventing a wrapper type of your own.

## Testing your code

`typesafetest` stubs the API by question id and builds wire-accurate responses, so the
decoded structs are identical to real ones:

```go
func TestRoutesBillingTickets(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{
		"dept":   typesafetest.ChoiceOf("billing", 0.9),
		"urgent": typesafetest.NoulOf(0.3),
		"anger":  typesafetest.ScoreOf(1, 0.8),
	})
	client := srv.Client()

	got, err := triage.Run(ctx, client, "Where is my refund?")
	// ...
}
```

A request for a question without a stub fails the test. `srv.StubError`, `srv.StubModels`,
and `srv.Handle` cover errors, the models endpoint, and anything custom; `srv.Requests()`
and `srv.Bodies()` expose what was sent.

A few things worth knowing:

- Call `typesafetest.NewServer(t)` once per test case, not once for a whole test file or
  suite; it starts a real `httptest.Server` and registers `t.Cleanup` to close it, so
  sharing one across cases makes their stubs interfere.
- `srv.Stub` replaces the entire answer set, not just the ids you pass; a second call to
  `srv.Stub` (or `srv.Handle`) with a partial set drops the stubs from the first call
  rather than merging with them.
- A `*Server` is not safe to share across parallel subtests (`t.Run(..., func(t *testing.T)
  { t.Parallel(); ... })`): its stub is one shared handler, so two subtests racing to
  `Stub` different answers will see each other's. Call `typesafetest.NewServer(t)` inside
  each parallel subtest instead of hoisting it to the parent.

## The raw layer

```go
resp, err := client.Do(ctx, http.MethodGet, "/v1/models", nil) // *Response with headers and RequestID

// The typed layer has no Choice/Score/Noul equivalent for "bounding_box", a
// question type the API accepts but this package does not model yet.
body, err := client.Post(ctx, "/v1/systemone", map[string]any{
	"state": "a photo description", "model": "jev-latest",
	"questions": map[string]any{
		"subject": map[string]any{"type": "bounding_box", "instructions": "Locate the main subject"},
	},
})
```

Same auth, retries, and hooks; no structs. Fields this package does not model yet mean
moving that call to the raw layer: there is no extra-body escape inside `Evaluate`.

## Writing good questions

- Ask everything your decision needs in one call; questions are evaluated in parallel and
  extra questions add tokens, not latency. Ignore the answers you do not need.
- One snap judgment per question. Split compound judgments and combine them in code.
- Give a Choice an `other` option when its options may not cover every input.
- Questions in one request are independent; a judgment that depends on another answer
  needs a second call. Question order is not meaningful to the API either way: `Questions`
  is a Go map, so ids are sent in alphabetical order on the wire, ids are never sent to the
  model at all, and each question is answered independently of how the others were phrased.
  (This is unlike a Choice's *option* order, which the client preserves exactly as you
  wrote it, because the model does see that order.)
- The only real ceiling is the shared token budget, roughly 32,000 tokens per request. A
  Choice needs 2 to 255 options and a Score 2 to 10 levels, both enforced locally.

## Reliability and scaling

Every state in `EvaluateMany`/`EvaluateStream` runs under its own timeout with panics
recovered, retry sleeps stop on context cancellation, the default transport keeps
connections alive for fan-out, telemetry hooks cannot fail a request, and response bodies
are bounded. [docs/beam-vs-go.md](docs/beam-vs-go.md) explains where the Go client matches
the Elixir client's BEAM-backed guarantees and where it cannot, and
[docs/debate-report.md](docs/debate-report.md) records a judged adversarial debate between
the two clients.

## Patterns

[docs/patterns.md](docs/patterns.md) translates TypeSafe's three recommended patterns
into Go: speculative fan-out, confidence-gated routing, and composite scoring.

## Security

The API key is redacted from `String()` and `%#v`, and never appears in hook data or error
bodies, which only carry what the server sent.

## License

MIT. See the LICENSE file.
