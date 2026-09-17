defmodule TypeSafeAPI.Retry do
  @moduledoc """
  Retry policy mirroring the official TypeSafe SDKs, implemented as a Req step.

  Req ships its own retry step, but it counts attempts, not wall time. The
  official SDKs enforce a *total* budget per call (30 seconds by default)
  covering the first attempt, every retry, and every delay in between. The
  budget gates whether another retry is *started*, not how long the attempt it
  starts may run, so a call can overrun it by up to one attempt timeout. Even
  so, that budget is the difference between "a slow request" and "a request
  that pins a worker for two minutes while the API is overloaded", so this
  module replaces Req's step with one that knows about the deadline.

  ## Defaults

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

  When both `retry-after-ms` and `Retry-After` are present, `retry-after-ms`
  wins, matching the Python SDK. `Retry-After` may be seconds or an HTTP date.
  A server-requested delay is clamped into `retry_after_min..retry_after_max`,
  so `retry-after: 0`, an empty header, or a date the local clock has already
  passed cannot turn the policy into a tight loop against a server that is
  already struggling, and a wildly long one cannot pin a worker.

  `retry_connection_errors` and `retry_timeout_errors` both default to `:auto`,
  which is `true` for `GET` and `false` for `POST`, since a replayed
  `POST /v1/systemone` can double-bill an evaluation. A timeout is the *most*
  likely failure to have reached the server, so it gets the same guard. A
  connection pool checkout timeout is the exception: nothing was sent, so it is
  always retried.

  A retry whose delay would reach or exceed the remaining budget is not
  attempted; the last error is returned instead. Delays are milliseconds.

  See the [errors and retries guide](errors_and_retries.md) for the full
  picture: the end-to-end retry timeline, why connection errors are not
  retried the same way as server-signalled ones, how the budget interacts
  with a single attempt's timeout, and how these option names map to the
  official SDKs'.

  ## Building a policy

      TypeSafeAPI.Retry.new(max_retries: 5, budget: 60_000)
      TypeSafeAPI.Retry.new(max_retries: 0)   # never retry

  Pass the result as `retry:` to `TypeSafeAPI.new/1` or to a single call.
  """

  @default_statuses Enum.to_list(500..599) ++ [408, 429]
  @replay_safe_methods [:get, :head, :options]

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
            retry_after_min: [
              type: :non_neg_integer,
              default: 100,
              doc:
                "Floor in milliseconds for a delay the server asked for. `retry-after: 0`, " <>
                  "an empty header and a past HTTP date all parse to zero; without a floor " <>
                  "they would retry in a tight loop while the wall-clock budget never advances."
            ],
            retry_after_max: [
              type: :non_neg_integer,
              default: 60_000,
              doc:
                "Ceiling in milliseconds for a delay the server asked for. A longer " <>
                  "`Retry-After` is clamped to this rather than pinning the caller."
            ],
            retry_connection_errors: [
              type: {:or, [:boolean, {:in, [:auto]}]},
              default: :auto,
              doc:
                "Whether to retry when the request cannot reach the server. `:auto` retries " <>
                  "on `GET` but not on `POST`, whose replay can double-bill an evaluation."
            ],
            retry_timeout_errors: [
              type: {:or, [:boolean, {:in, [:auto]}]},
              default: :auto,
              doc:
                "Whether to retry when a single attempt times out. `:auto` retries on " <>
                  "`GET` but not on `POST`, whose replay can double-bill an evaluation. " <>
                  "A connection pool checkout timeout is retried either way: nothing was sent."
            ],
            budget: [
              type: {:or, [:non_neg_integer, nil]},
              default: 30_000,
              doc:
                "Wall-clock budget in milliseconds per call. A retry is not started once " <>
                  "the elapsed time plus its delay would reach it, so a call can overrun by " <>
                  "one attempt timeout. `nil` disables the limit."
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
          retry_after_min: non_neg_integer(),
          retry_after_max: non_neg_integer(),
          retry_connection_errors: boolean() | :auto,
          retry_timeout_errors: boolean() | :auto,
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
            retry_after_min: 100,
            retry_after_max: 60_000,
            retry_connection_errors: :auto,
            retry_timeout_errors: :auto,
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

  Accepts an existing `%TypeSafeAPI.Retry{}` unchanged so callers can pass either.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec new(t() | keyword()) :: t()
  def new(%__MODULE__{} = policy), do: policy

  def new(opts) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    struct!(__MODULE__, Keyword.update!(opts, :statuses, &MapSet.new/1))
  end

  @doc """
  Layers `overrides` onto an existing policy.

  A per-call `retry: [max_retries: 1]` should change one setting, not reset
  every other one to the library default, so `TypeSafeAPI.HTTP` merges rather
  than rebuilds. Pass a `%TypeSafeAPI.Retry{}` instead of a keyword list to
  replace a policy wholesale.

      client.retry |> TypeSafeAPI.Retry.merge(max_retries: 1)

  Note the asymmetry, which is the whole point: a keyword list is a set of
  changes, a struct is a finished policy. A layer that wants to stay mergeable
  has to stay a keyword list, which is what `validate!/1` is for.
  """
  @spec merge(t() | keyword(), t() | keyword()) :: t()
  def merge(_base, %__MODULE__{} = overrides), do: overrides
  def merge(base, []), do: new(base)

  def merge(base, overrides) when is_list(overrides) do
    base
    |> new()
    |> Map.from_struct()
    |> Map.update!(:statuses, &MapSet.to_list/1)
    |> Map.to_list()
    |> Keyword.merge(overrides)
    |> new()
  end

  @doc """
  Validates a `:retry` option without turning it into a policy.

  For callers that validate per-call options once and reuse them for many
  requests: `new/1` would fill in every default, and the result could no
  longer be told apart from a policy the caller meant to impose wholesale.
  This raises on a bad option exactly as `new/1` does, and hands back
  something `merge/2` can still layer.

      iex> TypeSafeAPI.Retry.validate!(max_retries: 1)
      [max_retries: 1]
  """
  @spec validate!(t() | keyword()) :: t() | keyword()
  def validate!(%__MODULE__{} = policy), do: policy

  def validate!(opts) when is_list(opts) do
    _ = NimbleOptions.validate!(opts, @schema)
    opts
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
  Resolves method-dependent defaults against the HTTP method of a request.

  Turns `retry_connection_errors: :auto` and `retry_timeout_errors: :auto` into
  `true` for methods that are safe to replay (`GET`, `HEAD`, `OPTIONS`) and
  `false` for the rest, `POST` included. An explicit boolean is left alone.
  Called by `attach/2`.
  """
  @spec for_method(t(), atom()) :: t()
  def for_method(%__MODULE__{} = policy, method) do
    replay_safe = method in @replay_safe_methods

    %{
      policy
      | retry_connection_errors: resolve_auto(policy.retry_connection_errors, replay_safe),
        retry_timeout_errors: resolve_auto(policy.retry_timeout_errors, replay_safe)
    }
  end

  defp resolve_auto(:auto, replay_safe), do: replay_safe
  defp resolve_auto(flag, _replay_safe), do: flag

  @doc """
  Attaches the retry policy to a `Req.Request`.

  Disables Req's built-in retry step and registers this module's step for both
  responses and exceptions. The retry count is exposed afterwards through
  `retry_count/1`.

  The policy is resolved against the request's method with `for_method/2`
  first, so an `:auto` `retry_connection_errors` becomes a boolean here.
  """
  @spec attach(Req.Request.t(), t()) :: Req.Request.t()
  def attach(%Req.Request{} = request, %__MODULE__{} = policy) do
    policy = for_method(policy, request.method)

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

  An unresolved `:auto` counts as `false`; run the policy through `for_method/2`
  (as `attach/2` does) to resolve it. A pool checkout timeout is the one case
  that ignores both flags: the request never left the process.
  """
  @spec retryable?(t(), Req.Response.t() | Exception.t()) :: boolean()
  def retryable?(%__MODULE__{statuses: statuses}, %Req.Response{status: status}) do
    MapSet.member?(statuses, status)
  end

  def retryable?(%__MODULE__{}, %Req.HTTPError{reason: :pool_timeout}), do: true

  def retryable?(%__MODULE__{retry_timeout_errors: flag}, %Req.TransportError{reason: :timeout}) do
    flag == true
  end

  def retryable?(%__MODULE__{retry_connection_errors: flag}, %Req.TransportError{}),
    do: flag == true

  def retryable?(%__MODULE__{retry_connection_errors: flag}, %Req.HTTPError{}), do: flag == true
  def retryable?(%__MODULE__{}, _other), do: false

  @doc """
  The delay in milliseconds before retry number `attempt` (1-based), given the
  response or exception that triggered it.

  Uses the server's `retry-after-ms` or `Retry-After` header when present and
  `respect_retry_after` is set; otherwise exponential backoff with jitter.

  A server-requested delay is clamped into `retry_after_min` at the bottom and
  `retry_after_max` at the top, and otherwise honored as given, even when it is
  shorter than the exponential backoff would have been: the server knows its own
  load better than a schedule does. The floor matters: `retry-after: 0`, an
  empty header and an HTTP date a skewed clock reads as past all parse to zero,
  and honoring that verbatim would hammer a server that is already struggling
  while the wall-clock budget never advances.
  """
  @spec delay(t(), Req.Response.t() | Exception.t(), pos_integer()) :: non_neg_integer()
  def delay(%__MODULE__{respect_retry_after: true} = policy, %Req.Response{} = response, attempt) do
    case retry_after_ms(response) do
      nil -> backoff(policy, attempt)
      ms -> ms |> max(policy.retry_after_min) |> min(policy.retry_after_max)
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
    with nil <- parse_retry_after_ms(TypeSafeAPI.HTTP.first_header(response, "retry-after-ms")) do
      parse_retry_after(TypeSafeAPI.HTTP.first_header(response, "retry-after"))
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
