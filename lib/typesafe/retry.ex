defmodule TypeSafe.Retry do
  @moduledoc """
  Retry policy mirroring the official TypeSafe SDKs, implemented as a Req step.

  Req ships its own retry step, but it counts attempts, not wall time. The
  official SDKs enforce a *total* budget per call (30 seconds by default)
  covering the first attempt, every retry, and every delay in between. That
  budget is the difference between "a slow request" and "a request that pins a
  worker for two minutes while the API is overloaded", so this module replaces
  Req's step with one that knows about the deadline.

  ## Defaults

  | option                     | default             | meaning                                    |
  | -------------------------- | ------------------- | ------------------------------------------ |
  | `max_retries`              | `2`                 | retries after the first attempt            |
  | `backoff_initial`          | `500` ms            | first delay, doubled each retry            |
  | `backoff_max`              | `5_000` ms          | ceiling for the exponential delay          |
  | `backoff_jitter`           | `0.25`              | fraction randomly subtracted from a delay  |
  | `statuses`                 | `408, 429, 500-599` | HTTP statuses that trigger a retry         |
  | `respect_retry_after`      | `true`              | honor `retry-after-ms` and `Retry-After`   |
  | `retry_connection_errors`  | `true`              | retry when the server cannot be reached    |
  | `retry_timeout_errors`     | `true`              | retry when a single attempt times out      |
  | `budget`                   | `30_000` ms         | total wall time per call; `nil` disables   |

  When both `retry-after-ms` and `Retry-After` are present, `retry-after-ms`
  wins, matching the Python SDK. `Retry-After` may be seconds or an HTTP date.

  A retry whose delay would reach or exceed the remaining budget is not
  attempted; the last error is returned instead. Delays are milliseconds.

  ## Timeouts and retries, end to end

  The defaults are a 10 s timeout per attempt (the client's `timeout`), two
  retries, 500 ms then 1 s of backoff with up to 25% jitter subtracted, and a
  30 s budget.

  Three 529s in a row, each answered quickly:

  | time    | what happens                                                    |
  | ------- | --------------------------------------------------------------- |
  | 0.0 s   | attempt 1 goes out                                               |
  | 0.4 s   | 529 back; retry 1 allowed, sleep 375 to 500 ms                   |
  | 0.9 s   | attempt 2 goes out                                               |
  | 1.3 s   | 529 back; retry 2 allowed, sleep 750 ms to 1 s                   |
  | 2.3 s   | attempt 3 goes out                                               |
  | 2.7 s   | 529 back; `max_retries` reached, so the call returns             |

  The caller gets `{:error, %TypeSafe.Error{type: :overloaded, status: 529}}`
  after under 3 seconds. The budget never came into it.

  A single 429 carrying `Retry-After: 20` is different. The header wins over
  backoff, so the delay is 20 000 ms. At, say, 0.4 s elapsed the budget check
  passes (0.4 s + 20 s is under 30 s), the step sleeps 20 seconds, and attempt
  2 goes out at 20.4 s. If that attempt also comes back 429 at 20.8 s, the
  next delay is another 20 s, 20.8 s + 20 s is past the 30 s budget, and the
  call returns the 429 rather than retrying. `retry_after_ms` is still on the
  error, so the caller can back off itself.

  Note what the budget does and does not stop. It gates the *decision to start
  a retry*: elapsed time plus the next delay must be under the budget. It does
  not interrupt an attempt already in flight, and it does not shorten that
  attempt's own timeout. A retry started just inside the budget can therefore
  run its full 10 s on top, so the worst case for a call is roughly budget
  plus one attempt timeout, 40 s with the defaults. That is exactly the number
  `TypeSafe.FanOut` uses for its default per-state task timeout.

  ## Option names in the official SDKs

  The behaviour matches the official SDKs; the names and units do not. Every
  duration here is milliseconds.

  | official SDK option     | here                      | notes                                     |
  | ----------------------- | ------------------------- | ----------------------------------------- |
  | `max_retries`           | `max_retries`             | same meaning                              |
  | `backoff_initial`       | `backoff_initial`         | milliseconds, not seconds                 |
  | `backoff_max`           | `backoff_max`             | milliseconds, not seconds                 |
  | `backoff_jitter`        | `backoff_jitter`          | same fraction, 0 to 1                     |
  | `http_statuses`         | `statuses`                | list of integers                          |
  | `respect_retry_after`   | `respect_retry_after`     | same meaning                              |
  | `api_connection_error`  | `retry_connection_errors` | boolean instead of an error class         |
  | `api_timeout_error`     | `retry_timeout_errors`    | boolean instead of an error class         |
  | `timeout`               | `:timeout` on the client  | one attempt, not the whole call           |
  |                         | `budget`                  | the whole call; no SDK equivalent         |

  Unlike the JS SDK there is no cap on how long a server-requested wait may
  be. A `Retry-After` of five minutes is honoured as sent; the only thing that
  bounds it is the budget, which refuses to start a retry that cannot finish
  inside it. Set a smaller `budget`, or `respect_retry_after: false`, if you
  need a tighter bound.

  ## Building a policy

      TypeSafe.Retry.new(max_retries: 5, budget: 60_000)
      TypeSafe.Retry.new(max_retries: 0)   # never retry

  Pass the result as `retry:` to `TypeSafe.new/1` or to a single call.
  """

  @default_statuses Enum.to_list(500..599) ++ [408, 429]

  @schema NimbleOptions.new!(
            max_retries: [
              type: :non_neg_integer,
              default: 2,
              doc: "Maximum retries after the initial attempt; `0` disables retries."
            ],
            backoff_initial: [
              type: :non_neg_integer,
              default: 500,
              doc: "First backoff delay in milliseconds, doubled each retry."
            ],
            backoff_max: [
              type: :non_neg_integer,
              default: 5_000,
              doc: "Maximum backoff delay in milliseconds; `0` disables backoff."
            ],
            backoff_jitter: [
              type: {:custom, __MODULE__, :validate_fraction, []},
              default: 0.25,
              doc: "Fraction of each backoff delay randomly subtracted, between 0 and 1."
            ],
            statuses: [
              type: {:list, :pos_integer},
              default: @default_statuses,
              doc: "HTTP status codes that are retried."
            ],
            respect_retry_after: [
              type: :boolean,
              default: true,
              doc: "Whether to honor `Retry-After` and `retry-after-ms` response headers."
            ],
            retry_connection_errors: [
              type: :boolean,
              default: true,
              doc: "Whether to retry when the request cannot reach the server."
            ],
            retry_timeout_errors: [
              type: :boolean,
              default: true,
              doc: "Whether to retry when a single attempt times out."
            ],
            budget: [
              type: {:or, [:non_neg_integer, nil]},
              default: 30_000,
              doc:
                "Total budget in milliseconds per call, including the first attempt and " <>
                  "all delays. `nil` disables the limit."
            ],
            sleep_fun: [type: {:fun, 1}, default: &Process.sleep/1, doc: false],
            clock_fun: [type: {:fun, 0}, default: &__MODULE__.monotonic_ms/0, doc: false]
          )

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          backoff_initial: non_neg_integer(),
          backoff_max: non_neg_integer(),
          backoff_jitter: float(),
          statuses: MapSet.t(pos_integer()),
          respect_retry_after: boolean(),
          retry_connection_errors: boolean(),
          retry_timeout_errors: boolean(),
          budget: non_neg_integer() | nil,
          sleep_fun: (non_neg_integer() -> term()),
          clock_fun: (-> integer())
        }

  defstruct max_retries: 2,
            backoff_initial: 500,
            backoff_max: 5_000,
            backoff_jitter: 0.25,
            statuses: MapSet.new(@default_statuses),
            respect_retry_after: true,
            retry_connection_errors: true,
            retry_timeout_errors: true,
            budget: 30_000,
            sleep_fun: &Process.sleep/1,
            clock_fun: &__MODULE__.monotonic_ms/0

  @doc """
  The `NimbleOptions` type for a `:retry` option: a keyword list for `new/1`
  or a ready policy. Shared by every schema that accepts one.
  """
  @spec option_type() :: {:or, [atom() | {:struct, module()}]}
  def option_type, do: {:or, [:keyword_list, {:struct, __MODULE__}]}

  @doc """
  Builds a policy from a keyword list, validating every option.

  Accepts an existing `%TypeSafe.Retry{}` unchanged so callers can pass either.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec new(t() | keyword()) :: t()
  def new(%__MODULE__{} = policy), do: policy

  def new(opts) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    struct!(__MODULE__, Keyword.update!(opts, :statuses, &MapSet.new/1))
  end

  @doc false
  @spec validate_fraction(term()) :: {:ok, float()} | {:error, String.t()}
  def validate_fraction(value) when is_number(value) and value >= 0 and value <= 1 do
    {:ok, value / 1}
  end

  def validate_fraction(value) do
    {:error, "expected a number between 0 and 1, got: #{inspect(value)}"}
  end

  @doc false
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc """
  Attaches the retry policy to a `Req.Request`.

  Disables Req's built-in retry step and registers this module's step for both
  responses and exceptions. The retry count is exposed afterwards through
  `retry_count/1`.
  """
  @spec attach(Req.Request.t(), t()) :: Req.Request.t()
  def attach(%Req.Request{} = request, %__MODULE__{} = policy) do
    request
    |> Req.merge(retry: false)
    |> Req.Request.put_private(:typesafe_retry, policy)
    |> Req.Request.put_private(:typesafe_retry_count, 0)
    |> Req.Request.append_request_steps(typesafe_retry_start: &start/1)
    |> Req.Request.append_response_steps(typesafe_retry: &step/1)
    |> Req.Request.append_error_steps(typesafe_retry: &step/1)
  end

  @doc """
  Number of retries performed on a request that has been run.
  """
  @spec retry_count(Req.Request.t()) :: non_neg_integer()
  def retry_count(%Req.Request{} = request) do
    Req.Request.get_private(request, :typesafe_retry_count, 0)
  end

  @doc """
  Whether the policy would retry the given response or exception.
  """
  @spec retryable?(t(), Req.Response.t() | Exception.t()) :: boolean()
  def retryable?(%__MODULE__{statuses: statuses}, %Req.Response{status: status}) do
    MapSet.member?(statuses, status)
  end

  def retryable?(%__MODULE__{retry_timeout_errors: flag}, %Req.TransportError{reason: :timeout}) do
    flag
  end

  def retryable?(%__MODULE__{retry_connection_errors: flag}, %Req.TransportError{}), do: flag
  def retryable?(%__MODULE__{retry_connection_errors: flag}, %Req.HTTPError{}), do: flag
  def retryable?(%__MODULE__{}, _other), do: false

  @doc """
  The delay in milliseconds before retry number `attempt` (1-based), given the
  response or exception that triggered it.

  Uses the server's `retry-after-ms` or `Retry-After` header when present and
  `respect_retry_after` is set; otherwise exponential backoff with jitter.
  """
  @spec delay(t(), Req.Response.t() | Exception.t(), pos_integer()) :: non_neg_integer()
  def delay(%__MODULE__{respect_retry_after: true} = policy, %Req.Response{} = response, attempt) do
    case retry_after_ms(response) do
      nil -> backoff(policy, attempt)
      ms -> ms
    end
  end

  def delay(%__MODULE__{} = policy, _response_or_exception, attempt), do: backoff(policy, attempt)

  @doc """
  Exponential backoff with jitter for retry number `attempt` (1-based).

  The delay starts at `backoff_initial`, doubles each retry, and is capped at
  `backoff_max`. Jitter subtracts up to `backoff_jitter` of the delay, so the
  result is always between `delay * (1 - jitter)` and `delay`.
  """
  @spec backoff(t(), pos_integer()) :: non_neg_integer()
  def backoff(%__MODULE__{backoff_initial: initial, backoff_max: max}, _attempt)
      when initial == 0 or max == 0 do
    0
  end

  def backoff(%__MODULE__{} = policy, attempt) when is_integer(attempt) and attempt >= 1 do
    exponential = min(policy.backoff_initial * Integer.pow(2, attempt - 1), policy.backoff_max)
    jittered = exponential * (1 - :rand.uniform() * policy.backoff_jitter)
    min(exponential, round(jittered))
  end

  @doc """
  Reads the server's requested wait from `retry-after-ms` (milliseconds) or
  `Retry-After` (seconds or an HTTP date). Returns `nil` if neither is usable.
  """
  @spec retry_after_ms(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after_ms(%Req.Response{} = response) do
    with nil <- parse_retry_after_ms(TypeSafe.HTTP.first_header(response, "retry-after-ms")) do
      parse_retry_after(TypeSafe.HTTP.first_header(response, "retry-after"))
    end
  end

  # -- Req steps ---------------------------------------------------------------

  defp start(request) do
    policy = Req.Request.get_private(request, :typesafe_retry)

    if Req.Request.get_private(request, :typesafe_started_at) do
      request
    else
      Req.Request.put_private(request, :typesafe_started_at, policy.clock_fun.())
    end
  end

  defp step({request, response_or_exception}) do
    policy = Req.Request.get_private(request, :typesafe_retry)
    retries_done = retry_count(request)

    if retries_done < policy.max_retries and retryable?(policy, response_or_exception) do
      attempt = retries_done + 1
      delay = delay(policy, response_or_exception, attempt)

      if within_budget?(policy, request, delay) do
        policy.sleep_fun.(delay)

        request =
          request
          |> Req.Request.put_private(:typesafe_retry_count, attempt)
          |> Req.Request.put_header("x-typesafe-retry-count", Integer.to_string(attempt))

        {request, response_or_exception} = Req.Request.run_request(%{request | halted: false})
        Req.Request.halt(request, response_or_exception)
      else
        {request, response_or_exception}
      end
    else
      {request, response_or_exception}
    end
  end

  defp within_budget?(%__MODULE__{budget: nil}, _request, _delay), do: true

  defp within_budget?(%__MODULE__{budget: budget} = policy, request, delay) do
    started_at = Req.Request.get_private(request, :typesafe_started_at)
    elapsed = policy.clock_fun.() - started_at
    elapsed + delay < budget
  end

  # -- header parsing ----------------------------------------------------------

  defp parse_retry_after_ms(nil), do: nil

  defp parse_retry_after_ms(value) do
    case parse_number(value) do
      {:ok, ms} when ms >= 0 -> round(ms)
      _ -> nil
    end
  end

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) do
    case parse_number(value) do
      {:ok, seconds} when seconds >= 0 -> round(seconds * 1000)
      {:ok, _negative} -> nil
      :error -> parse_http_date(value)
    end
  end

  defp parse_number(""), do: {:ok, 0}

  defp parse_number(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  # RFC 7231 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT". Parsed here rather
  # than with :httpd_util so the library does not depend on :inets.
  @http_date ~r/^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
          |> Enum.with_index(1)
          |> Map.new()

  defp parse_http_date(value) do
    with [_, day, month, year, hour, minute, second] <- Regex.run(@http_date, value),
         {:ok, month_number} <- Map.fetch(@months, month),
         {:ok, date} <- Date.new(String.to_integer(year), month_number, String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
         {:ok, target} <- DateTime.new(date, time, "Etc/UTC") do
      target |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(0)
    else
      _ -> nil
    end
  end
end
