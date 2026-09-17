# Report: Go versus Elixir/BEAM for API clients like this one

## Summary

Two real implementations of the same TypeSafe AI client, one in Go and one in Elixir, were argued by dedicated advocates over three rounds and judged against the code in both. The verdict: Go wins, "on a narrower margin than its own rhetoric suggested," at medium confidence. Go won not because its technical case was stronger across the board but because it made fewer factual errors, conceded its worst finding before being forced to, and kept its argument on properties of the client library rather than the host runtime. Elixir landed the debate's single most damaging technical finding, a Go retry policy that compiles, validates, and silently retries nothing, but lost ground by making claims the code contradicted, including one it never retracted, and by conceding only after being itemized rather than volunteering. The judgment's central framing: a client library follows its host application's language, so the deciding factors are dependency surface, deployment shape, and concrete code defects, not the BEAM's supervision and hot-upgrade properties, which belong to the host application.

## The question and the two clients

The debate asked, for a client library like this one specifically, whether Go or Elixir/BEAM is the better implementation language, argued over two real implementations of the same TypeSafe AI decision-API client (the Go client is a feature-for-feature port of the Elixir one).

The **Go client** is a small standard-library-only package (three-line go.mod) built around a `context.Context`-threaded `Evaluate`/`EvaluateMany` API, a sealed `Question` interface, typed `Result` accessors (`Noul`, `Choice`, `Score`), and a `RetryPolicy` struct with a `validate()` method. It compiles to a static binary with no runtime dependencies beyond the standard library.

The **Elixir client** is built on `Req`/`Finch`/`Mint` for HTTP, uses `:telemetry.span` for observability, represents choice options and questions as ordered structures backed in part by maps, and includes a hand-built atom-key registry (`lib/typesafe/keys.ex`) to avoid exhausting the BEAM's atom table on server-controlled strings. Its fan-out primitive, `TypeSafe.FanOut.evaluate_many/4`, runs on `Task.async_stream`.

## The arguments, by theme

### Dependency surface

Go pointed to its three-line go.mod against Elixir's mix.lock closure of nine packages plus plug/plug_crypto for test stubs, plus `:inets` pulled in solely for `:httpd_util.convert_request_date/1`, a job Go does with the stdlib `http.ParseTime`. Go called Jason "a dead dependency shipped into every consumer's release," quoting Elixir's own DESIGN.md conceding it is unused.

Elixir countered that "zero dependencies" is illusory: Go inherits `net/http`'s bad defaults, and client.go's "30-line" `DefaultTransport()` proves it, "you vendored the dependency and had to correct it." Go answered that `DefaultTransport()` is fifteen lines, sits in the repository, and is asserted by a test.

The judge verified go.mod is three lines and mix.lock's runtime closure is nine packages plus the optional plug pair, with `:inets` present for one call and Jason transitive and uncalled. It called Go's "eleven packages" a small overstatement and Elixir's vendoring rebuttal "weak," since `DefaultTransport()` is 15 lines, not 30. **Go prevailed.**

### Compile-time versus runtime guarantees

Go argued its unexported-method `Question` interface makes decoding total by construction and typed accessors plus `*typesafe.Error` make failure handling exhaustive, while Elixir's equivalent is Dialyzer, "optional, success-typing rather than sound," a separate cached-PLT CI job.

Elixir's rebuttal cut deep: `Description = any` and `State = any` alias to `any`, so `typesafe.Noul(42)` compiles, and `validateState` rejects only four types by name, letting `int32` reach the API. Worse, the accessor Go called a safety win, `r.Noul("depatrment")`, returns a typed nil that panics at the use site with no id in the message, whereas Elixir's `result.answers.dept` raises a KeyError naming `:dept` at the mistaken line. `Outcome`'s "exactly one of Result or Err is set" invariant is not compiler-held, unlike Elixir's `{:ok, _} | {:error, _}`.

Go conceded the `any` aliases and the `int32` leak, holding ground only on timing: `go build` runs on every save; Dialyzer sits outside the inner loop entirely.

The judge ruled for **Elixir, narrowly**, verifying the aliases, the `int32` leak, the typed-nil hazard, and the unenforced `Outcome` invariant, noting Go's claim of exhaustive typed safety "was overstated."

### The zero-value RetryPolicy hazard

Elixir's sharpest finding: `WithRetry(typesafe.RetryPolicy{MaxRetries: 5})` compiles, passes `validate()` (which only checks non-negativity), and yields a policy with `Statuses` nil, both retry-on-error flags false, and `Budget` zero. `retryable()` then returns false for every status and error: "five retries configured, zero retries performed, no budget, no warning." By contrast `TypeSafe.Retry.new(max_retries: 5)` merges into documented defaults and raises on an unrecognized key.

Go conceded immediately and unprompted: "correct, and the strongest thing said so far... `validate()` should reject a policy with `MaxRetries > 0` and no `Statuses`. That is a fixable bug." It called Elixir's approach "a quiet runtime raise traded for a loud compile error," but Elixir replied that a loud failure at first execution beats a silent multi-month failure that "shows up as an availability number nobody can explain."

The judge called this theme **decisive for Elixir**: "`validate()` checks only sign and jitter; `RetryPolicy{MaxRetries: 5}` retries nothing and has no budget... Go conceded." The concession log separately flags this as Go's most damaging, and earliest, concession.

### Ordering traps: Choice map vs Questions map

Go noted `TypeSafe.Question.Choice.new/2` accepts a map, and Elixir maps stop preserving insertion order past 32 keys while Choice allows up to 255 options; `validate/1` checks count, type, and uniqueness, "never provenance." A large Choice built from a map silently reorders model input, guarded only by prose.

Elixir conceded the fact but turned it around: Go's own `Questions` type is `map[string]Question`, and its `encode()` returns a map that `json.Marshal` emits in sorted key order, so "the Go client cannot express question order at all." Elixir built `TypeSafe.JSON.OrderedObject` for its own top level; Go "stopped one level short."

Go conceded this but argued severity differs: question order is deterministic and both READMEs document that questions in a request are independent, whereas the Choice bug "changes what the model sees."

The judge called this a **draw, with a slight Go edge on severity**: "Choice order is documented as what the model sees; question ids are documented as independent and answers bind by id."

### Fan-out admission and result streaming

Elixir: `FanOut.evaluate_many/4` feeds an `Enumerable.t()` into `Task.async_stream` with `max_concurrency: 8`, back-pressure by construction; Go's `EvaluateMany` requires a materialized `[]State` and launches a goroutine per state before any semaphore is consulted, "a million states is a million goroutines blocked," roughly 8 KB of stack each. Elixir also claimed `ordered: false` lets callers "consume results as they finish."

Go's rebuttal: `evaluate_many/4` pipes into `Enum.map(&unwrap/1)`, so the output is fully materialized, "yours streams admission only." Worse, `maybe_raise(outcomes, :raise)` raises the first error only after collecting every outcome, discarding paid-for results, where `FirstError(outcomes)` keeps them. Go corrected its own doc's 8 KB figure to the actual 2 KB, and conceded eager admission is "a real inefficiency."

Elixir conceded output materializes, `:raise` discards results, and the stack figure is 2 KB, but held structural admission control is the more important property: "handing the user back the concurrency problem is the thing a client exists to prevent."

The judge scored this a **draw**: "Elixir right on admission... Go right on results... Elixir's 'consume results as they finish' was misleading. 8 KB stack figure... is wrong (2 KB)."

### Isolation and cancellation

Elixir argued `recover` does not catch what actually kills Go processes, a concurrent map write, a nil map assignment, stack exhaustion, or a hook-spawned goroutine's panic, all fatal to the whole process; on the BEAM "a task that dies dies alone." Cancellation is preemptive on the BEAM (`on_timeout: :kill_task` kills mid-sleep) versus cooperative in Go, dependent on every future patch selecting on `ctx.Done()`.

Go answered that a nil map entry assignment is an ordinary panic that `recover` *does* catch; it agreed concurrent map writes and stack exhaustion escape recovery, framing the former as a data race caught by `go test -race`, and noted the BEAM is not immune to whole-node failure either. Elixir corrected Go's claim that `on_timeout: :kill_task` "abandons the socket": NimblePool reclaims the connection on task death "whether the dying code cooperated or not."

The judge ruled for **Go, on decision relevance**: "Elixir's claim that recover does not catch a nil map assignment is false... Every Go blocking point selects on ctx, with tests." Elixir "never retracted the false nil-map claim."

### Telemetry

Elixir: `:telemetry.span` lets any number of handlers attach and detach at runtime; Go has one `Hooks` value fixed at `New`, `Hooks.response` silently discards panics via `recover()` with no log and no detach, and `CallOptions` carries no telemetry metadata for tenant or trace labeling.

Go's answer: BEAM detachment is "global and permanent for the life of the node," so one bad handler kills observability until a redeploy, whereas Go's recover drops only that call's telemetry; Go agreed the recover should log and noted `CallOptions.Header` reaches hooks via `RequestInfo`. Elixir corrected that `:telemetry` actually logs a detachment; its main point was structural, that a wrapping library cannot install its own hooks without owning construction.

The judge ruled for **Elixir**: "Single Hooks struct fixed at New; panics swallowed with no log; no per-call metadata field... Go's ':telemetry leaves observability silently off' is wrong: it logs the detachment."

### Testing fidelity

Elixir: `TypeSafe.Retry` exposes `sleep_fun`/`clock_fun` for testing with a fake clock, versus Go's unexported `sleep`/`now`, so external tests "sleep for real"; `TypeSafe.Test` stubs in-process via `Req.Test` with Mox ownership, versus a real `httptest.Server` per Go test.

Go's rebuttal: `sleep_fun`/`clock_fun` are `doc: false`, "not a supported testing API," and `Req.Test` replaces the adapter so Elixir's tests "never exercise Finch, connection reuse, real header parsing, or TLS," whereas `typesafetest.NewServer` runs the real transport and asserts that 40 requests at concurrency 8 open at most 8 connections. Elixir conceded the clock-hooks claim "overstated it" and that Go's test is better than its own.

The judge ruled for **Go**: "`sleep_fun`/`clock_fun` are `doc: false`... `typesafetest` drives the real transport with a connection-count assertion that has no Elixir counterpart," noting "Elixir's Mox-style async ownership is a real ergonomic advantage."

### Ops, hiring, on-call

Go's closer: one static binary needs no ERTS or OTP release; onboarding an engineer to review Go's retry loop "takes an afternoon"; the BEAM's supervision and hot-upgrade strengths are properties of the host application, "paid for in hiring pool, in a second observability stack, and in an on-call rotation that must know what a linked process is." Elixir leaned on remote-shell debugging and live `:telemetry.attach/4`, "no redeploy."

The judge ruled for **Go, but with low decision relevance**: "Static binary vs OTP release is real; 'hiring pool an order of magnitude smaller' is unsupported; remote shell and live `:telemetry.attach` are host properties, as Go's own docs say." This theme is explicitly the one the judge flagged as Go's weakest showing, "unevidenced and undercut by its own beam-vs-go.md."

## Concessions

**Go's concessions:** the zero-value `RetryPolicy` hazard, the 8 KB-to-2 KB stack correction, and that the silent recover should log (all Round 2, volunteered); the question-alphabetization defect (Round 3, partly forced); the `any` type aliases and the `int32` leak (Round 3, forced).

**Elixir's concessions:** the Choice-map ordering trap and the `:inets` dependency (Round 2, forced). In Round 3, after Go itemized each point, Elixir conceded output-list materialization, that `:raise` discards results, the overstated clock-hooks claim, the stack figure, the `:inets`/Jason warts, Go's better connection-reuse test, and the simpler static-binary deploy. It "never retracted the false nil-map claim."

The judge's reading: "Go volunteered its most damaging concession in Round 2 before being forced; Elixir's concessions arrived in Round 3 only after Go had itemised each one." This timing asymmetry was one of three factors the judge cites for the verdict.

## Factual errors, as the judge found them

**Go's errors:** "eleven packages" (overstated); ":telemetry silently off" (wrong, it logs); "abandoning the in-flight request" (overstated); Dialyzer "will not run locally" (speculation); the unsupported hiring-pool figure; its own docs' incorrect 8 KB stack size.

**Elixir's errors:** `recover` does not catch a nil map assignment (false, never retracted); the 8 KB stack figure; "any user can test with a fake clock" (overstated); "30-line `DefaultTransport()`" (it is 15); "`ordered: false` consumes results as they finish" (misleading); "Go's answer is a rebuild" (ignores pprof and metrics).

## Why the winner won, and what would have flipped it

The judge names three deciding factors. First, **accuracy**: "the Elixir side made more claims that the code or the language contradicts, and never retracted the first," specifically the nil-map/recover error; Go's errors were fewer and "corrected when pressed." Second, **concession**: Go volunteered its worst finding before being forced to; Elixir's came only in Round 3, after being itemized. Third, **decision relevance**: both sides agreed a client library follows its host language, so the properties that matter are local to the library, not the BEAM's supervision and hot-upgrade properties, which "accrue to the host application," a point Go's own documentation had already conceded.

The judge is explicit this was close: "the zero-value hazard and the telemetry findings are strong enough that a stricter weighting of technical findings alone could have gone the other way." Weighted purely on merits, those two findings, both scored for Elixir, could plausibly have swung the outcome. What would have flipped it: retracting the nil-map error once shown false, and offering the other concessions earlier and unforced.

## What this means for the choice

The judgment's central point: a client library follows its host application's language. If a team's service is already built on the BEAM, supervised, hot-upgraded, an Elixir client fits that host, and its dependency closure and atom-safety subsystem are part of the cost of already being on that platform. If a team's service is Go, or anything not committed to the BEAM, a Go client avoids importing a second runtime, a second observability stack, and an on-call rotation that must understand links, monitors, and the atom table.

For a principal engineer, the debate narrows the decision to properties local to the library: dependency closure size, the precision of a `validate()` function against real defaults (both sides had a weak spot), how faithfully tests exercise the real transport rather than a stubbed adapter, and how configurable observability is per call versus fixed at construction. The BEAM's most celebrated properties, preemptive cancellation and process-isolated failure, are real and verified, but the judge weighted them as belonging to whichever application hosts the client, not the client itself.

## After the debate

The debate and judgment above concern two specific code snapshots as argued. Both codebases have since been fixed. In Go: the retry policy is now zero-value safe, zero fields mean documented defaults and negative values explicitly disable a feature; fan-out uses a bounded worker pool instead of one goroutine per state up front; `EvaluateStream` yields results as they complete; per-call metadata reaches telemetry hooks; state validation rejects every scalar kind it does not accept, closing the `int32` leak. In Elixir: a `Choice` built from a map of more than 32 options now raises instead of silently reordering what the model sees, and `:inets` has been removed. None of this changes the verdict above, a record of the debate as argued over the snapshots that existed at the time.
