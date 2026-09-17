# Design notes (Go client)

This is a port of the Elixir client on the `main` branch, feature for feature, into
idiomatic Go with no dependencies. The wire facts (endpoints, limits, error shapes, header
names) were verified against the live API on 2026-09-17; see the Elixir DESIGN.md for the
full list. What differs here is how the same behaviour is expressed in Go.

## Same behaviour, Go shapes

- **Client is a struct, not a process.** Functional options (`WithAPIKey`, `WithRetry`),
  immutable after `New`, safe to share. The `http.Client` inside owns the connection pool;
  `WithHTTPClient` is the escape hatch for transports and proxies.
- **Contexts, not timeouts on the client alone.** Every call takes a `context.Context`.
  `WithTimeout` bounds one attempt; the retry budget bounds the call; the caller's context
  bounds everything and is never retried past.
- **Questions are a closed interface.** `Noul`, `Choice`, `Score` constructors return
  concrete types; the `Question` interface has unexported methods so the set cannot grow
  from outside the package, which keeps `Evaluate`'s decoding total.
- **No atom problem, so no key registry.** Go strings round-trip naturally. Choice option
  order is preserved with a custom `MarshalJSON` on an ordered pair slice, since Go maps
  randomise key order.
- **Answers are an interface plus typed accessors.** `Result.Noul(id)`, `Choice(id)`,
  `Score(id)` return nil on absence or type mismatch; a type switch over `Answers` works
  too. `Gate` is a package function over the `Answer` interface.
- **Errors are values.** One `*Error` type with a `Type` field, `Unwrap` for
  `errors.Is(err, context.DeadlineExceeded)`, and `errors.As` as the idiom.
- **Telemetry is two callbacks**, not an event bus. Go has no `:telemetry`; `Hooks` is
  the smallest thing that lets a caller feed Prometheus or OpenTelemetry. Failures arrive
  through `OnResponse` with `Err` set, mirroring the Elixir `:stop` event with
  `metadata.error`.
- **`EvaluateMany` uses a semaphore and a WaitGroup**, returns outcomes in input order,
  and reports the question-set validation error once, before any request.
- **`typesafetest` is a real HTTP server** (`httptest`), so the client under test runs its
  full transport, retry, and decode path. Unstubbed questions fail the test.
- **Milliseconds become `time.Duration`.** Same defaults as the official SDKs.
- **Retry clock injection is unexported.** Tests in-package set `sleep` and `now`; there
  is no public hook for it.

## Deliberate differences from the Elixir client

- No `evaluate!` equivalent: Go has no bang convention; panics are reserved for programmer
  errors like `Gate(act < review)`.
- `Score` labels for structured levels are a truncated JSON rendering rather than
  `inspect/1` output.
- `ManyOptions` has no `OnError: :raise`; use `typesafe.FirstError(outcomes)`.
- The raw layer's `Do` takes a method string rather than separate get/post variants, since
  `net/http` already names them.

## Branch layout

The Go module is the root of the `go-sdk` orphan branch, so `go get
github.com/typesend/typesafe_ai@go-sdk` works without a subdirectory. Tags for Go releases
are prefixed `go/` (for example `go/v0.1.0-alpha.1`) to keep them apart from the Elixir
package's tags on `main`.

## Things worth revisiting

- Rate limits are unpublished; `MaxConcurrency` defaults to 8 as a guess.
- The API exposes a `bounding_box` question type not in the public docs. Not modelled.
- `Hooks` could grow an `OnRetry` callback if per-attempt visibility is wanted.
