defmodule TypeSafeAPI.FanOut do
  @moduledoc """
  Evaluate many states against one question set, concurrently.

  The question set is validated and encoded once; each state then gets its own
  `TypeSafeAPI.evaluate/4` call in a task. Results come back in input order by
  default, one `{:ok, result}` or `{:error, error}` per state, so a single
  failure never hides the other results.

  ## Concurrency

  `max_concurrency` defaults to 8. That number is a guess: TypeSafe has not
  published rate limits or an SLA at the time of writing. Raise it if your
  account allows, and watch for `:rate_limited` errors (the retry policy
  absorbs short bursts of 429s before they surface).

  Tasks run under `TypeSafeAPI.TaskSupervisor`, started by
  `TypeSafeAPI.Application`, and are *not* linked to the caller. A task that
  raises - a `Req` adapter blowing up, a state that will not JSON-encode -
  becomes one `{:error, %TypeSafeAPI.Error{type: :unexpected}}` in that state's
  position instead of killing the calling process and every other in-flight
  request with it.

  ## Two timeouts

  `:timeout` means the same thing here as in `TypeSafeAPI.evaluate/4`: the
  timeout of a single HTTP attempt, passed straight through to each call.

  `:task_timeout` is the cap on one state's whole task, every retry and every
  backoff delay included. It defaults to the call's retry budget plus one
  attempt timeout, or 60 000 ms when the budget is disabled, which is the
  longest a well-behaved call can take. A state that overruns it comes back as
  `{:error, %TypeSafeAPI.Error{type: :timeout}}`.

  ## When retries run out

  A state whose retries are exhausted is not special. It comes back as an
  ordinary `{:error, %TypeSafeAPI.Error{type: :rate_limited, retry_after_ms: ms}}`
  in that state's position, next to the states that succeeded, and the batch
  keeps going. With `on_error: :raise` that same error is raised instead, once
  every task has been collected.

  With `ordered: false` the outcomes arrive as they finish rather than in
  input order, so under `on_error: :raise` the error that raises is the first
  one to *finish*, which is not necessarily the earliest state in the input.
  If you need the failure to be reproducible, keep `ordered: true`.

  `retry_after_ms` is carried on the error so the caller can back off before
  the next batch. The per-call retry policy has already given up by the time
  you see it, so the useful move is to sleep for the longest `retry_after_ms`
  in the batch, then resend just the failed states.

  ## The one failure that is not per-state

  An invalid *question set* fails before any request is sent, so there is no
  per-state outcome to put it in. `evaluate_many/4` then returns a bare
  `{:error, %TypeSafeAPI.Error{type: :validation}}` rather than a list - the
  reason the return type is a union. Match on it, or pass `on_error: :raise`,
  which raises that error too rather than handing back a tuple from the mode
  whose whole point is not to.

  Passing a `%TypeSafeAPI.SystemOne.Prepared{}` from
  `TypeSafeAPI.SystemOne.prepare/1` instead of a question set skips both the
  re-validation and that failure mode.
  """

  alias TypeSafeAPI.{Client, Error, Question, Result, Retry, SystemOne}
  alias TypeSafeAPI.SystemOne.Prepared

  @schema NimbleOptions.new!(
            max_concurrency: [
              type: :pos_integer,
              default: 8,
              doc: "Maximum number of in-flight requests. A guess; see the module docs."
            ],
            task_timeout: [
              type: {:or, [:pos_integer, {:in, [:infinity]}]},
              doc:
                "Cap in milliseconds on one state's whole task, covering every retry and " <>
                  "delay. Defaults to the retry budget plus one attempt timeout, or 60 000 " <>
                  "when the budget is disabled. Not to be confused with `:timeout`, which is " <>
                  "one HTTP attempt, as in `TypeSafeAPI.evaluate/4`."
            ],
            ordered: [
              type: :boolean,
              default: true,
              doc: "Return results in input order. `false` yields them as they finish."
            ],
            on_error: [
              type: {:in, [:collect, :raise]},
              default: :collect,
              doc: "`:collect` returns error tuples in place; `:raise` raises the first error."
            ]
          )

  @own_options Keyword.keys(@schema.schema)

  @type outcome :: {:ok, Result.t()} | {:error, Error.t()}

  @doc """
  The options `evaluate_many/4` handles itself.

  Every other option is passed through to each individual call; see
  `TypeSafeAPI.SystemOne.options_schema/0`.

  #{NimbleOptions.docs(@schema)}
  """
  @spec options_schema() :: NimbleOptions.t()
  def options_schema, do: @schema

  @doc """
  Evaluates each state in `states` against `questions`.

  `questions` is a question set, or a `%TypeSafeAPI.SystemOne.Prepared{}` from
  `TypeSafeAPI.SystemOne.prepare/1`.

  Returns a list of outcomes (in input order unless `ordered: false`), or
  `{:error, error}` when the question set itself is invalid.

  ## Options

  #{NimbleOptions.docs(@schema)}

  Every other option (`:model`, `:timeout`, `:retry`, `:req_options`,
  `:telemetry`) is passed to each call and means what it means in
  `TypeSafeAPI.evaluate/4`; see `TypeSafeAPI.SystemOne.options_schema/0`.
  """
  @spec evaluate_many(
          Client.t(),
          Enumerable.t(),
          Question.input() | Prepared.t(),
          keyword()
        ) :: [outcome()] | {:error, Error.t()}
  def evaluate_many(%Client{} = client, states, questions, opts \\ []) do
    {own, call_opts} = Keyword.split(opts, @own_options)
    opts = NimbleOptions.validate!(own, @schema)
    call_opts = SystemOne.validate_options!(call_opts)

    case prepare(questions) do
      {:ok, prepared} -> stream(client, states, prepared, call_opts, opts)
      {:error, error} -> prepare_failed(error, opts[:on_error])
    end
  end

  defp prepare(%Prepared{} = prepared), do: {:ok, prepared}
  defp prepare(questions), do: SystemOne.prepare(questions)

  # `:raise` promises to fail fast; handing back a tuple from exactly one
  # failure mode is the kind of exception nobody writes a clause for.
  defp prepare_failed(error, :raise), do: raise(error)
  defp prepare_failed(error, :collect), do: {:error, error}

  defp stream(client, states, prepared, call_opts, opts) do
    task_timeout =
      Keyword.get_lazy(opts, :task_timeout, fn -> default_task_timeout(client, call_opts) end)

    TypeSafeAPI.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      states,
      fn state -> SystemOne.run(client, state, prepared, call_opts) end,
      max_concurrency: opts[:max_concurrency],
      ordered: opts[:ordered],
      timeout: task_timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(&unwrap/1)
    |> maybe_raise(opts[:on_error])
  end

  defp unwrap({:ok, outcome}), do: outcome

  defp unwrap({:exit, :timeout}) do
    {:error,
     %Error{
       type: :timeout,
       message: "evaluate_many task timed out; see the :task_timeout option"
     }}
  end

  defp unwrap({:exit, reason}) do
    {:error,
     %Error{
       type: :unexpected,
       message: "evaluate_many task exited: " <> Exception.format_exit(reason)
     }}
  end

  defp maybe_raise(outcomes, :collect), do: outcomes

  defp maybe_raise(outcomes, :raise) do
    case Enum.find(outcomes, &match?({:error, _}, &1)) do
      nil -> outcomes
      {:error, error} -> raise error
    end
  end

  # The longest a well-behaved call can take: the budget gates whether another
  # retry is started, so the last attempt can still run past it by its own
  # timeout. Anything longer than that is a task worth killing.
  defp default_task_timeout(client, call_opts) do
    retry = Retry.merge(client.retry, Keyword.get(call_opts, :retry, []))
    attempt_timeout = Keyword.get(call_opts, :timeout, client.timeout)

    case retry.budget do
      nil -> 60_000
      budget -> budget + attempt_timeout
    end
  end
end
