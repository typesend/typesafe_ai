defmodule TypeSafe.FanOut do
  @moduledoc """
  Evaluate many states against one question set, concurrently.

  The question set is validated and encoded once; each state then gets its own
  `TypeSafe.evaluate/4` call in a task. Results come back in input order by
  default, one `{:ok, result}` or `{:error, error}` per state, so a single
  failure never hides the other results.

  ## Concurrency

  `max_concurrency` defaults to 8. That number is a guess: TypeSafe has not
  published rate limits or an SLA at the time of writing. Raise it if your
  account allows, and watch for `:rate_limited` errors (the retry policy
  absorbs short bursts of 429s before they surface).

  Each task is bounded by `timeout`, which must cover the whole retry budget of
  a single call. The default is the client's retry budget plus one attempt's
  timeout, or 60 seconds when the budget is disabled.

  `:timeout` here is the *task* timeout, not the single-attempt HTTP timeout.
  Use `:attempt_timeout` for the latter; it defaults to the client's timeout.

  ## When retries run out

  A state whose retries are exhausted is not special. It comes back as an
  ordinary `{:error, %TypeSafe.Error{type: :rate_limited, retry_after_ms: ms}}`
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
  """

  alias TypeSafe.{Client, Error, Question, Result, SystemOne}

  @schema NimbleOptions.new!(
            max_concurrency: [
              type: :pos_integer,
              default: 8,
              doc: "Maximum number of in-flight requests. A guess; see the module docs."
            ],
            timeout: [
              type: {:or, [:pos_integer, {:in, [:infinity]}]},
              doc:
                "Per-state task timeout in milliseconds, covering every retry of that state. " <>
                  "Defaults to the retry budget plus one attempt timeout, or 60 000 when the " <>
                  "budget is disabled."
            ],
            attempt_timeout: [
              type: :pos_integer,
              doc: "Timeout in milliseconds for one HTTP attempt; defaults to the client's."
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
  `TypeSafe.SystemOne.options_schema/0`.

  #{NimbleOptions.docs(@schema)}
  """
  @spec options_schema() :: NimbleOptions.t()
  def options_schema, do: @schema

  @doc """
  Evaluates each state in `states` against `questions`.

  Returns a list of outcomes (in input order unless `ordered: false`), or
  `{:error, error}` when the question set itself is invalid.

  ## Options

  #{NimbleOptions.docs(@schema)}

  Every other option (`:model`, `:retry`, `:req_options`, `:telemetry`) is
  passed to each call; see `TypeSafe.SystemOne.options_schema/0`.
  """
  @spec evaluate_many(Client.t(), Enumerable.t(), Question.input(), keyword()) ::
          [outcome()] | {:error, Error.t()}
  def evaluate_many(%Client{} = client, states, questions, opts \\ []) do
    {own, call_opts} = Keyword.split(opts, @own_options)
    opts = NimbleOptions.validate!(own, @schema)

    call_opts =
      call_opts
      |> put_attempt_timeout(opts)
      |> SystemOne.validate_options!()

    with {:ok, prepared} <- SystemOne.prepare(questions) do
      timeout = Keyword.get_lazy(opts, :timeout, fn -> default_timeout(client, call_opts) end)

      states
      |> Task.async_stream(
        fn state -> SystemOne.run(client, state, prepared, call_opts) end,
        max_concurrency: opts[:max_concurrency],
        ordered: opts[:ordered],
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(&unwrap/1)
      |> maybe_raise(opts[:on_error])
    end
  end

  defp unwrap({:ok, outcome}), do: outcome

  defp unwrap({:exit, :timeout}) do
    {:error, %Error{type: :timeout, message: "evaluate_many task timed out"}}
  end

  defp unwrap({:exit, reason}) do
    {:error, %Error{type: :unexpected, message: "evaluate_many task exited: #{inspect(reason)}"}}
  end

  defp maybe_raise(outcomes, :collect), do: outcomes

  defp maybe_raise(outcomes, :raise) do
    case Enum.find(outcomes, &match?({:error, _}, &1)) do
      nil -> outcomes
      {:error, error} -> raise error
    end
  end

  defp put_attempt_timeout(call_opts, opts) do
    case Keyword.fetch(opts, :attempt_timeout) do
      {:ok, attempt_timeout} -> Keyword.put(call_opts, :timeout, attempt_timeout)
      :error -> call_opts
    end
  end

  defp default_timeout(client, call_opts) do
    retry = Keyword.get(call_opts, :retry, client.retry)
    attempt_timeout = Keyword.get(call_opts, :timeout, client.timeout)

    case retry.budget do
      nil -> 60_000
      budget -> budget + attempt_timeout
    end
  end
end
