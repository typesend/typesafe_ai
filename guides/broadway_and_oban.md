# Broadway and Oban

Two ways to run System One evaluations at volume: a `Broadway` pipeline that
classifies a stream of messages in batches, and an `Oban` worker that
evaluates one record per job. Both wrap the same two ideas: build the
question set once, and turn a `TypeSafeAPI.Error` into the right instruction
for your queue instead of a generic retry.

Neither `:broadway` nor `:oban` is a dependency of this library. The code
below is written against their public APIs; the logic that actually touches
`typesafe_api` is pulled out into plain functions so it can be tested without
either dependency, and the test suite for this library does exactly that
(`test/typesafe_api/guides/broadway_and_oban_test.exs`).

## Pattern 1: Broadway, batched

Broadway already groups messages into batches for you; the job here is to
turn one batch into one `evaluate_many/4` call instead of N single calls, and
to build the question set once instead of once per batch.

```elixir
defmodule MyApp.Classifier do
  use Broadway

  @questions [
    category:
      TypeSafeAPI.choice("Classify this support message",
        bug_report: "Something is broken or producing errors",
        billing: "Charges, invoices, refunds, subscriptions",
        other: "Anything else"
      ),
    urgent: TypeSafeAPI.noul("Does this convey urgency?")
  ]

  def start_link(_opts) do
    # Validates and encodes @questions once, at boot, so a malformed
    # question set fails the deploy instead of the first batch. The prepared
    # value itself isn't threaded through Broadway: `evaluate_many/4` still
    # does its own (much cheaper) prepare per batch, not per message, which
    # is the granularity that actually matters for throughput.
    case TypeSafeAPI.SystemOne.prepare(@questions) do
      {:ok, _prepared} -> :ok
      {:error, error} -> raise error
    end

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {MyApp.Producer, []},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 4]
      ],
      batchers: [
        default: [batch_size: 8, batch_timeout: 2_000, concurrency: 4]
      ]
    )
  end

  @impl Broadway
  def handle_message(_processor, message, _context) do
    Broadway.Message.put_batcher(message, :default)
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, _context) do
    client = MyApp.TypeSafe.client()
    states = Enum.map(messages, & &1.data.body)

    outcomes = MyApp.Classifier.Core.classify_batch(client, @questions, states)

    Enum.zip(messages, outcomes)
    |> Enum.map(fn
      {message, {:ok, result}} ->
        Broadway.Message.update_data(message, fn data -> Map.put(data, :answers, result.answers) end)

      {message, {:error, error}} ->
        Broadway.Message.failed(message, Exception.message(error))
    end)
  end
end
```

`batch_size` is aligned with the processor's `max_concurrency` for
`evaluate_many/4`, not the other way around: a batch of 8 fans out at most 8
concurrent HTTP requests, matching `TypeSafeAPI.FanOut`'s own default of 8.
Raising `batch_size` without raising `max_concurrency` just serializes part
of the batch; raising `max_concurrency` without raising `batch_size` wastes
concurrency the batcher never hands you.

The part worth testing on its own — the call to `evaluate_many/4` — is a
one-line wrapper:

```elixir
defmodule MyApp.Classifier.Core do
  @moduledoc false

  def classify_batch(client, questions, states, opts \\ []) do
    opts = Keyword.merge([max_concurrency: 8, on_error: :collect], opts)
    TypeSafeAPI.evaluate_many(client, states, questions, opts)
  end
end
```

`on_error: :collect` (the default) is what makes `handle_batch/4`'s
`Enum.zip/2` above safe: every message gets an outcome in the same position
it went in, success or failure, so one bad state in a batch of eight never
takes the other seven down with it. Using `on_error: :raise` here would turn
one failed classification into a batch-wide crash, which Broadway would then
retry as a whole batch — usually not what you want when seven of eight
succeeded.

### Back-pressure

`evaluate_many/4`'s `max_concurrency` bounds requests *within* one batch, not
across batches. If your producer hands out batches faster than TypeSafe can
answer them, you get concurrent batches each running their own pool of
requests, and the real concurrency is `batch_concurrency * max_concurrency`.
Keep that product close to the number you'd pick for a single top-level
`max_concurrency`, and lean on the batcher's own `concurrency` setting (not
`evaluate_many/4`'s) as the primary throttle — it's the one Broadway can
apply back-pressure through, by slowing the producer when batchers are full.

A `:rate_limited` or `:overloaded` outcome inside a batch has already
exhausted the client's own retry budget (`TypeSafeAPI.Retry`, 30 seconds by
default) before `evaluate_many/4` returned it — it's not a signal to retry
immediately again. `error.retry_after_ms` says how long TypeSafe asked
everyone to wait; the simplest back-pressure response is to track the
largest `retry_after_ms` across a batch's failures and pause the producer
for that long before requesting the next one, rather than retrying failed
messages inline.

## Pattern 2: Oban, one record per job

Where Broadway amortizes the question set and HTTP round trip across a
batch, Oban's unit is one job. The interesting part is entirely in how a
`TypeSafeAPI.Error` becomes an Oban return value, since Oban's own retry
loop and this library's retry policy both exist and need to not multiply.

```elixir
defmodule MyApp.ClassifyWorker do
  use Oban.Worker, queue: :classify, max_attempts: 5

  @questions [
    urgent: TypeSafeAPI.noul("Does this convey urgency?")
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id, "body" => body}}) do
    client = MyApp.TypeSafe.client()

    case TypeSafeAPI.evaluate(client, body, @questions) do
      {:ok, result} ->
        MyApp.Tickets.apply_answers(id, result.answers)
        :ok

      {:error, error} ->
        MyApp.ClassifyWorker.Core.to_oban_result(error)
    end
  end
end
```

```elixir
defmodule MyApp.ClassifyWorker.Core do
  @moduledoc false

  alias TypeSafeAPI.Error

  @default_snooze_seconds 30

  @doc """
  Maps a `TypeSafeAPI.Error` to an `Oban.Worker.result/0`.

    * `:rate_limited` / `:overloaded` - `{:snooze, seconds}`. TypeSafe has
      already told the client (and, transitively, this job) to slow down;
      snoozing keeps the job in the queue at the position its scheduled time
      implies, rather than burning an Oban attempt (and its exponential
      backoff) on something that was never going to succeed sooner.
    * `:validation` / `:auth` - `{:cancel, reason}`. A malformed question, a
      state the API rejects, or a bad API key will not start working on
      attempt 2; cancelling stops Oban from retrying a job that cannot
      succeed and surfaces it for a human instead.
    * everything else (`:server_error`, `:timeout`, `:connection`,
      `:unexpected`) - `{:error, reason}`, an ordinary retryable failure
      using Oban's own backoff.
  """
  @spec to_oban_result(Error.t()) ::
          {:snooze, pos_integer()} | {:cancel, String.t()} | {:error, String.t()}
  def to_oban_result(%Error{type: type, retry_after_ms: retry_after_ms} = error)
      when type in [:rate_limited, :overloaded] do
    seconds =
      case retry_after_ms do
        ms when is_integer(ms) and ms > 0 -> ceil(ms / 1000)
        _ -> @default_snooze_seconds
      end

    {:snooze, seconds}
  end

  def to_oban_result(%Error{type: type} = error) when type in [:validation, :auth] do
    {:cancel, Exception.message(error)}
  end

  def to_oban_result(%Error{} = error) do
    {:error, Exception.message(error)}
  end
end
```

### Aligning the two retry budgets

`TypeSafeAPI.Retry` and Oban's job retries both exist to absorb transient
failures, and left at their defaults they compound: a `529` gets retried up
to twice inside a single `evaluate/4` call (roughly 30 seconds of budget),
and *then*, if that's still not enough, the job itself gets retried by Oban
with its own backoff, up to `max_attempts` times. That's not wrong, but it
means a sustained outage costs `max_attempts * (client budget + backoff)`
before a job gives up, which can be a long time at Oban's defaults.

Two ways to keep that intentional instead of accidental:

  * **Let the client absorb the seconds, let Oban absorb the minutes.**
    Keep `TypeSafeAPI.Retry`'s default budget (it exists to smooth over a
    single blip) and use it as the fast path, but treat `{:snooze, seconds}`
    above as the primary tool for anything the client's own budget couldn't
    fix — it costs no Oban attempt at all, so `max_attempts` is left to
    cover real failures (`:server_error`, `:timeout`, `:connection`,
    `:unexpected`).
  * **Or turn the client's retries off** (`retry: [max_retries: 0]` on the
    worker's client) and let Oban own every retry decision, including the
    backoff after a `429` or `529` that isn't snoozed. This trades away the
    sub-second retries that fix a blip in place, in exchange for one clear
    owner of "when does this run again."

Either is fine; what's worth avoiding is the default-on-default combination
where both layers independently decide to wait and neither knows about the
other's wait.

## Testing both without the dependency

`test/typesafe_api/guides/broadway_and_oban_test.exs` exercises
`MyApp.Classifier.Core.classify_batch/4` and
`MyApp.ClassifyWorker.Core.to_oban_result/1` against `TypeSafeAPI.Test`
stubs, the same way you'd test them in an app that does depend on Broadway
and Oban: the queue library's callback (`handle_batch/4`, `perform/1`) stays
a thin, mostly-untested wrapper, and the logic that decides what to send and
how to interpret the answer is a plain function you can call directly.
