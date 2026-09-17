# typesafe_ai (Go)

Unofficial Go client for the TypeSafe AI API. Not affiliated with or endorsed by TypeSafe AI.

Sign up for an API key at [typesafe.ai](https://typesafe.ai). No key yet? Skip to
[Testing your code](#testing-your-code): `typesafetest` runs every example on this page
offline, no key or network required.

TypeSafe's [System One](https://docs.typesafe.ai/concepts/system-one) models are small,
fast models built for calibrated decisions, not text generation: they answer typed
questions about a piece of state and return probabilities instead of prose. You ask three
kinds of question:

| question | asks for                                  | answer                                           |
| -------- | ----------------------------------------- | ------------------------------------------------ |
| Noul     | yes or no                                 | probability of yes                               |
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

```go
import typesafe "github.com/typesend/typesafe_ai"

client, err := typesafe.New() // reads TYPESAFE_API_KEY, TYPESAFE_BASE_URL, TYPESAFE_DEFAULT_MODEL
if err != nil {
	return err
}

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

res.Model                    // "jev-1.13.0" (what "jev-latest" resolved to)
res.Usage.InputTokens        // 312
res.RequestID                // "req_..." for support tickets

res.Noul("urgent").Noul      // 0.92
d := res.Choice("dept")
d.Choice                     // "technical"
d.Probabilities["billing"]   // 0.08
d.Confidence()               // 0.82

a := res.Score("anger")
a.Score, a.Level, a.Label    // 1.6, 2, "Very angry"
a.Levels                     // [{Calm 0.05} {Frustrated 0.3} {Very angry 0.65}]
a.Normalized()               // 0.8: score divided by the top level index

typesafe.Gate(d, 0.8, 0.5)   // GateAct, GateReview, or GateEscalate
```

The typed accessors (`Noul`, `Choice`, `Score`) return nil when the id is absent or the
answer is another type; a type switch over `res.Answers[id]` works too.

### Where to build the client

`typesafe.New` returns an immutable struct with no goroutines and no connection state of
its own (the `http.Client` inside holds the pool). Build one at startup and share it. Pass
`typesafe.WithHTTPClient` for proxies, custom transports, or pool tuning; its `Timeout`
field is ignored in favour of `typesafe.WithTimeout`, which bounds one attempt.

## Many states, one question set

```go
outcomes, err := client.EvaluateMany(ctx, states, questions, typesafe.ManyOptions{MaxConcurrency: 8})
// err is only set when the question set itself is invalid
for i, o := range outcomes {
	if o.Err != nil {
		log.Printf("state %d: %v", i, o.Err)
		continue
	}
	use(o.Result)
}
```

Results come back in input order; a failed state never hides the others. The question set
is validated and encoded once. `MaxConcurrency` defaults to 8, which is a guess: TypeSafe
has not published rate limits. Cancel `ctx` to stop early.

## Errors and retries

Every failure is a `*typesafe.Error` with a `Type` you can switch on: `ErrAuth`,
`ErrValidation`, `ErrRateLimited`, `ErrOverloaded`, `ErrTimeout`, `ErrConnection`, or
`ErrUnexpected`. Local validation failures (a Score with one level, a Choice with one
option) have `Status == 0` and never reach the network. `Body` holds the decoded error
body, `RequestID` the `x-typesafe-request-id` header, and `RetryAfter` the server's
requested wait even after retries are exhausted.

Retries mirror the official SDKs: two retries with exponential backoff and jitter; 408,
429, and 5xx retried; `retry-after-ms` and `Retry-After` honoured; connection and timeout
errors retried; and a 30 second total budget per call that includes every attempt and
delay. The budget gates the decision to start a retry, not an in-flight attempt, so the
worst case is roughly budget plus one attempt timeout (`typesafe.WorstCaseDuration`).

```go
p := typesafe.DefaultRetryPolicy()
p.MaxRetries = 4
p.Budget = 60 * time.Second
client, _ := typesafe.New(typesafe.WithRetry(p))

client.Evaluate(ctx, state, questions, typesafe.CallOptions{Retry: &noRetry, Timeout: 5 * time.Second})
```

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

## The raw layer

```go
body, err := client.Post(ctx, "/v1/systemone", map[string]any{
	"state": "...", "model": "jev-latest",
	"questions": map[string]any{"q": map[string]any{"type": "noul", "instructions": "?"}},
})
resp, err := client.Do(ctx, http.MethodGet, "/v1/models", nil) // *Response with headers and RequestID
```

Same auth, retries, and hooks; no structs. Fields this package does not model yet mean
moving that call to the raw layer: there is no extra-body escape inside `Evaluate`.

## Writing good questions

- Ask everything your decision needs in one call; questions are evaluated in parallel and
  extra questions add tokens, not latency. Ignore the answers you do not need.
- One snap judgment per question. Split compound judgments and combine them in code.
- Give a Choice an `other` option when its options may not cover every input.
- Questions in one request are independent; a judgment that depends on another answer
  needs a second call.
- The only real ceiling is the shared token budget, roughly 32,000 tokens per request. A
  Choice needs 2 to 255 options and a Score 2 to 10 levels, both enforced locally.

## Reliability and scaling

Every state in `EvaluateMany` runs under its own timeout with panics recovered, retry
sleeps stop on context cancellation, the default transport keeps connections alive for
fan-out, telemetry hooks cannot fail a request, and response bodies are bounded.
[docs/beam-vs-go.md](docs/beam-vs-go.md) explains where the Go client matches the
Elixir client's BEAM-backed guarantees and where it cannot.

## Patterns

[docs/patterns.md](docs/patterns.md) translates TypeSafe's three recommended patterns
into Go: speculative fan-out, confidence-gated routing, and composite scoring.

## Security

The API key is redacted from `String()` and `%#v`, and never appears in hook data or error
bodies, which only carry what the server sent.

## License

MIT. See the LICENSE file.
