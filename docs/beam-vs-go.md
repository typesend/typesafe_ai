# The Go client versus the Elixir client

Both clients implement the same feature list against the same API, and both were verified
against the live API. This document covers only the differences that matter in production:
where the Go client cannot match the BEAM client's reliability or scaling characteristics,
what it does instead, and where the difference is significant. Minor differences (naming,
option shapes, bang functions) are in DESIGN.md.

## Summary

| concern                          | Elixir / BEAM                                   | Go                                                   | matters when                          |
| -------------------------------- | ----------------------------------------------- | ---------------------------------------------------- | ------------------------------------- |
| One bad state in a batch         | task crashes, others unaffected                 | panic recovered per state, others unaffected         | rarely; parity achieved               |
| Cancelling a batch               | caller kills tasks; in-flight requests abandoned | context cancels every goroutine incl. retry sleeps   | parity                                |
| Memory per in-flight request     | process heap, few KB, GC per process            | goroutine stack ~2 KB (grows as needed) + shared heap, global GC | tens of thousands in flight  |
| A slow hook or callback          | telemetry handler runs in caller; crash detaches it | hook runs in caller; panic recovered                 | parity                                |
| CPU-heavy work beside the client | preemptive scheduler, no head-of-line blocking   | preemptive since Go 1.14; tight loops rarely stall   | parity in practice                    |
| Connection pool                  | Finch pool, per-host, sized by Req               | http.Transport, tuned defaults (64 idle per host)    | parity after tuning                   |
| Supervision and restart          | host app's supervision tree restarts the caller | none; the host handles process death                 | significant: see below                |
| Hot code upgrade                 | possible for the host app                       | not possible; deploy restarts the process            | significant for some ops teams        |
| Distribution                     | tasks can run on other nodes                    | none: one process on one host                        | significant only if you shard batches across nodes |
| Back-pressure and streaming      | `Task.async_stream` pulls demand-driven and yields results as they complete | fixed pool of MaxConcurrency workers pulls from the input, `EvaluateStream` yields (index, Outcome) as each state completes | parity |

## Where parity was achieved, and how

**Per-state isolation.** On the BEAM, each state in `evaluate_many` runs in its own process;
a crash there is a single `{:exit, reason}` in the results. Go has no process boundary, so a
panic in one goroutine kills the whole program. The Go client recovers panics inside each
state's goroutine and returns them as an `ErrUnexpected` outcome with the stack trace, and
recovers panics in telemetry hooks so a metrics bug cannot fail a request. This is the
same observable behaviour, achieved by discipline in the library rather than by the
runtime. One honest difference: a BEAM process's heap is discarded with the process, so a
crash cannot leave partial mutation behind. `recover` in Go only stops the panic from
propagating; any package-level or shared state the panicking goroutine had already mutated
before panicking is left exactly as it was. This client keeps no such shared, mutable state
of its own (each call's state lives on its own goroutine's stack), so a panic mid-state has
nothing of the client's to corrupt, but the same is not true in general for arbitrary Go
code recovered this way.

**Cancellation.** `Task.async_stream` with `on_timeout: :kill_task` kills a slow state.
Go's `EvaluateMany` gives every state its own `context.WithTimeout` (default: retry budget
plus one attempt), and the retry sleep selects on the context, so a cancelled batch stops
waiting immediately instead of finishing a 20 second `Retry-After` sleep. Cancellation
in Go is cooperative, but every blocking point in this client cooperates.

**Connection pooling.** Go's `http.DefaultTransport` keeps two idle connections per host,
which at `MaxConcurrency: 8` means most requests open a fresh TLS connection. The client's
`DefaultTransport` keeps 64 idle connections per host with keep-alive. A test asserts that
40 requests at concurrency 8 open at most 16 connections (goroutines racing for the idle
pool can open a few more than the theoretical minimum of 8; without pooling this climbs
toward 40). Finch gives the Elixir client the same property by default.

**Bounded memory.** Response bodies are read through a limit (16 MB by default) so a
misbehaving upstream cannot exhaust memory. The Elixir client relies on Req's defaults here;
the Go client is stricter.

**Retry budget, jitter, `Retry-After`, telemetry on every outcome, ordered results, local
validation, request ids.** Identical semantics; the tests mirror each other.

## Where the difference is significant

**Fault tolerance is a property of the host, not the client.** A client library does not
supervise anything. On the BEAM, the process calling `TypeSafe.evaluate/4` is itself
supervised: if it crashes for an unrelated reason, its supervisor restarts it with a clean
state, and the rest of the application does not notice. In Go, the goroutine calling
`client.Evaluate` has no supervisor; an unrecovered panic anywhere in the program takes the
process down, and recovery is the deployment platform's job (Kubernetes restarts, systemd,
a process manager). The Go client cannot change this. It matters when the surrounding
application does many other things with varying reliability: the BEAM contains failures to
the failing subsystem, Go contains them to the failing process. For a service whose only
job is to call TypeSafe, the difference is small. For a large monolith it is large.

**Memory under extreme fan-out.** A BEAM process is a few KB with its own heap and
per-process garbage collection, so 100,000 in-flight evaluations are unremarkable. A
goroutine starts at about 2 KB of stack (growing as needed) and shares one heap with a
stop-the-world (short, concurrent) collector. At the concurrency this API can absorb today
(unpublished, but `MaxConcurrency: 8` is the default in both clients), neither runtime is
anywhere near its limit, and Go's per-request memory is competitive. The gap appears only
at fan-outs of tens of thousands of simultaneous calls, which the API would rate-limit long
before the runtime struggled. Either way, `EvaluateMany` and `EvaluateStream` run a fixed
pool of `MaxConcurrency` goroutines rather than one goroutine per state, so admission, not
just in-flight requests, is bounded: a million-state input does not start a million
goroutines.

**Operational model.** BEAM applications support hot code upgrades, live introspection
(`:observer`, remote shells into a running node), and tracing of individual processes
without redeploying. Go applications are inspected with `pprof`, logs, and metrics, and
changed by redeploying a static binary. Teams already running BEAM get the former for free;
teams running Go get simpler deployment (one binary, no runtime to install) and a smaller
resource footprint. This is a difference in what the surrounding team is set up to do,
not in the client.

**Scheduling under CPU-bound neighbours.** The BEAM's scheduler is preemptive at the
reduction level, so a CPU-heavy computation in one process cannot delay the client's
network work in another. Go has been preemptive since 1.14 (asynchronous preemption), so
the classic tight-loop starvation is gone in practice; extremely allocation-heavy work can
still cause GC pauses that a BEAM process would not see. For an API client whose work is
overwhelmingly network waits, this is not a practical concern.

## What the Go client does better

- **Static typing at compile time.** Question and answer shapes are checked by the
  compiler; a typo in an option key or a wrong answer type is caught before the test runs.
  The Elixir client has Dialyzer and pattern matching, which catch most of the same
  mistakes, but later.
- **Deployment.** One static binary with no runtime dependency; the client itself has zero
  third-party dependencies.
- **Memory bound on responses.** Explicit and configurable.

## What changed after the debate

An earlier draft of this document and the client it described understated a few gaps.
Since then: `RetryPolicy`'s zero value became the default policy instead of a policy that
silently disabled backoff and the budget; `EvaluateMany` and `EvaluateStream` moved from an
unbounded goroutine-per-state semaphore to a fixed worker pool, so admission is bounded, not
just concurrency; `EvaluateStream` was added so a caller no longer has to hold a whole batch
in memory or wait for the slowest state before seeing any result; `CallOptions.Metadata`
was added so telemetry can be labelled without a wrapper type; and state validation now
rejects every scalar Go kind (not just a hand-picked list) so a bare `int` or `bool` passed
as `state` fails locally instead of reaching the server. These are called out here because
the rest of this document compares the two clients as they are today, not as they were
during that review.

## Practical guidance

- If the host application is already on the BEAM, use the Elixir client. Its reliability
  comes from the runtime and costs nothing.
- If the host application is Go, the Go client gives the same semantics for everything a
  client library can control: retries, budgets, isolation of batch failures, cancellation,
  pooling, telemetry, and bounded memory. What it cannot give you is supervision of the
  caller, which is the platform's job in Go.
- Do not choose a language for an API client on the basis of this table. Choose it for the
  application around the client; both clients are designed to disappear into whichever
  runtime the team already operates.
