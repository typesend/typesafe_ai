defmodule TypeSafeAPI.Telemetry do
  @moduledoc """
  Telemetry events emitted by this library, plus a small logger handler.

  Every HTTP call is wrapped in a `:telemetry.span/3`, which yields:

    * `[:typesafe_api, :request, :start]` with measurements `%{system_time: integer}`
    * `[:typesafe_api, :request, :stop]` with measurements `%{duration: integer}`
    * `[:typesafe_api, :request, :exception]` with `%{duration: integer}` and the
      usual `kind`, `reason`, `stacktrace` metadata

  Durations are in native time units; convert with `System.convert_time_unit/3`.

  ## Metadata

  The start event carries `method`, `path`, `model`, and `question_count`.
  The stop event adds:

    * `status` - HTTP status, or `nil` when no response arrived
    * `retry_count` - retries performed by `TypeSafeAPI.Retry`
    * `input_tokens` / `output_tokens` - from the response `usage`, or `nil`
    * `error` - a `TypeSafeAPI.Error` when the call failed, otherwise `nil`

  `question_count` and `model` describe the request as sent, so a raw
  `TypeSafeAPI.HTTP.post/4` call still reports them when the body has them.

  ## Failures are stop events, not exception events

  Every failure this library knows how to name is a normal outcome of the
  span, so it arrives as a `:stop` event with `metadata.error` set to a
  `%TypeSafeAPI.Error{}`. That covers `:auth`, `:rate_limited`, `:overloaded`, `:timeout`,
  `:connection`, `:unexpected` and `:validation` alike: an expired key, a 429
  that outlived its retries, a socket that never opened, and a body the
  library could not decode all look the same to a handler, and all of them
  come with a `duration`. The `:exception` event fires only when code raises,
  which in practice means a bug in a handler, in a `Req` step, or in this
  library. A handler that watches only `:exception` will see none of the
  failures that matter operationally.

  ## Attaching a handler

      :telemetry.attach("typesafe-watch", [:typesafe_api, :request, :stop], fn _event, _m, meta, tokens ->
        if meta.error, do: Logger.warning("typesafe \#{meta.error.type}: \#{Exception.message(meta.error)}")
        :counters.add(tokens, 1, meta[:input_tokens] || 0)
        :counters.add(tokens, 2, meta[:output_tokens] || 0)
      end, :counters.new(2, [:write_concurrency]))

  Read the running totals back with `:counters.get(tokens, 1)` and
  `:counters.get(tokens, 2)`. The `duration` in the measurements map is in
  native time units; turn it into milliseconds with
  `System.convert_time_unit(duration, :native, :millisecond)`.

  ## Metrics

  `metrics/0` returns `Telemetry.Metrics` definitions for these events, ready to
  drop into a Phoenix LiveDashboard or a `Telemetry.Metrics.ConsoleReporter`.
  It needs `{:telemetry_metrics, "~> 1.0"}`, which this library lists as an
  optional dependency. See the [LiveDashboard guide](live_dashboard.md).

  ## Logging

  `attach_logger/1` attaches a handler that logs one line per request: at
  `:level` when the call succeeded, and at `:error_level` (`:warning` by
  default) when it failed. Failures arrive as `:stop` events, so logging them
  at the success level is how they disappear from a production `:warning`
  logger; the two levels keep the happy path quiet without hiding the
  failures.

  The default success level comes from `config :typesafe_api, log_level:`
  first, then `TYPESAFE_LOG_LEVEL`, then `:info`. `warn` is accepted as a
  spelling of `:warning`; anything else raises rather than silently logging
  every request at `:info`.
  """

  require Logger

  # `telemetry_metrics` is optional; metrics/0 checks for it at runtime.
  @compile {:no_warn_undefined, Telemetry.Metrics}

  @prefix [:typesafe_api, :request]
  @handler_id "typesafe-ai-logger"

  # Milliseconds. Wide enough to separate a cached 4xx from a request that sat
  # through two retries, without asking a reporter to keep dozens of series.
  @duration_buckets [50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000]

  @doc "The telemetry event prefix, `[:typesafe_api, :request]`."
  @spec prefix() :: [atom()]
  def prefix, do: @prefix

  @doc """
  Runs `fun` inside a `[:typesafe_api, :request]` span.

  `fun` must return `{result, extra_metadata}`; the extra metadata is merged
  into the stop event.
  """
  @spec span(map(), (-> {result, map()})) :: result when result: term()
  def span(metadata, fun) when is_map(metadata) and is_function(fun, 0) do
    :telemetry.span(@prefix, metadata, fn ->
      {result, extra} = fun.()
      {result, Map.merge(metadata, extra)}
    end)
  end

  @doc """
  `Telemetry.Metrics` definitions for every `[:typesafe_api, :request]` event.

  Pass them to a LiveDashboard `metrics:` list, or to any reporter:

      Telemetry.Metrics.ConsoleReporter.start_link(metrics: TypeSafeAPI.Telemetry.metrics())

  The list covers request counts, durations, retries, errors by type and token
  usage; see the [LiveDashboard guide](live_dashboard.md) for the names and for
  where to put them. Every definition reads the `:stop` or `:exception` event
  this library already emits, so nothing else has to be instrumented.

  Requires `{:telemetry_metrics, "~> 1.0"}`; the function raises without it.
  """
  @spec metrics() :: [struct()]
  def metrics do
    ensure_metrics!()
    stop = @prefix ++ [:stop]

    [
      Telemetry.Metrics.counter("typesafe_api.request.count",
        event_name: stop,
        measurement: :duration,
        tag_values: &__MODULE__.request_tags/1,
        tags: [:method, :path, :status],
        description: "Requests completed, by method, path and HTTP status"
      ),
      # `distribution`, not `summary`: TelemetryMetricsPrometheus does not
      # implement `summary`, and the guide promises the reporter can be swapped
      # without touching these definitions.
      Telemetry.Metrics.distribution("typesafe_api.request.duration",
        event_name: stop,
        measurement: :duration,
        unit: {:native, :millisecond},
        tag_values: &__MODULE__.request_tags/1,
        tags: [:method, :path, :status],
        reporter_options: [buckets: @duration_buckets],
        description: "Time from the first byte sent to the decoded response"
      ),
      Telemetry.Metrics.sum("typesafe_api.request.retry_count",
        event_name: stop,
        measurement: &__MODULE__.retry_count/2,
        tags: [:method, :path],
        description: "Retries performed before the response arrived"
      ),
      Telemetry.Metrics.counter("typesafe_api.request.error.count",
        event_name: stop,
        measurement: :duration,
        keep: &(&1[:error] != nil),
        tag_values: &__MODULE__.error_tags/1,
        tags: [:method, :path, :error_type],
        description: "Failed requests, by TypeSafeAPI.Error type"
      ),
      Telemetry.Metrics.sum("typesafe_api.request.input_tokens",
        event_name: stop,
        measurement: &__MODULE__.input_tokens/2,
        tags: [:model],
        description: "Input tokens reported by the API"
      ),
      Telemetry.Metrics.sum("typesafe_api.request.output_tokens",
        event_name: stop,
        measurement: &__MODULE__.output_tokens/2,
        tags: [:model],
        description: "Output tokens reported by the API"
      ),
      Telemetry.Metrics.counter("typesafe_api.request.exception.count",
        event_name: @prefix ++ [:exception],
        measurement: :duration,
        tags: [:method, :path, :kind],
        description: "Requests that raised rather than returning an error"
      )
    ]
  end

  @doc false
  def retry_count(_measurements, metadata), do: metadata[:retry_count] || 0

  @doc false
  def input_tokens(_measurements, metadata), do: metadata[:input_tokens] || 0

  @doc false
  def output_tokens(_measurements, metadata), do: metadata[:output_tokens] || 0

  @doc false
  def error_tags(metadata) do
    Map.put(metadata, :error_type, metadata[:error] && metadata.error.type)
  end

  @doc false
  # `status` is nil when no response arrived, which most reporters render as an
  # empty label rather than something you can group by.
  def request_tags(metadata), do: Map.put(metadata, :status, metadata[:status] || "none")

  defp ensure_metrics! do
    if not Code.ensure_loaded?(Telemetry.Metrics) do
      raise """
      TypeSafeAPI.Telemetry.metrics/0 needs the :telemetry_metrics library. Add it:

          {:telemetry_metrics, "~> 1.0"}
      """
    end
  end

  @doc """
  Attaches a `Logger` handler for request stop and exception events.

  Calling it again replaces the handler rather than returning
  `{:error, :already_exists}`, so the levels can be changed at runtime.

  ## Options

    * `:level` - level for calls that succeeded. Defaults to
      `config :typesafe_api, log_level:`, then `TYPESAFE_LOG_LEVEL`, then
      `:info`.
    * `:error_level` - level for calls that failed, i.e. `:stop` events
      carrying a `%TypeSafeAPI.Error{}`. Defaults to `:warning`.

  Both accept any `Logger` level, plus `warn` as a spelling of `:warning`.
  An unrecognised level raises `ArgumentError`.
  """
  @spec attach_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_logger(opts \\ []) do
    level =
      case Keyword.fetch(opts, :level) do
        {:ok, level} -> parse_level!(level, ":level")
        :error -> default_level()
      end

    error_level = opts |> Keyword.get(:error_level, :warning) |> parse_level!(":error_level")

    # Attaching twice is a no-op in :telemetry, which would silently keep the
    # old levels. Detaching first makes a second call mean what it looks like.
    _ = detach_logger()

    :telemetry.attach_many(
      @handler_id,
      [@prefix ++ [:stop], @prefix ++ [:exception]],
      &__MODULE__.handle_event/4,
      %{level: level, error_level: error_level}
    )
  end

  @doc "Detaches the handler attached by `attach_logger/1`."
  @spec detach_logger() :: :ok | {:error, :not_found}
  def detach_logger, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(@prefix ++ [:stop], %{duration: duration}, metadata, config) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    error = metadata[:error]
    level = if error, do: config.error_level, else: config.level

    Logger.log(level, fn ->
      base =
        "typesafe #{metadata[:method]} #{metadata[:path]} -> #{metadata[:status] || "no response"} " <>
          "in #{ms}ms (retries: #{metadata[:retry_count] || 0}, model: #{metadata[:model]})"

      case error do
        nil -> base
        error -> base <> " error: " <> Exception.message(error)
      end
    end)
  end

  def handle_event(@prefix ++ [:exception], %{duration: duration}, metadata, _config) do
    ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.error(fn ->
      "typesafe #{metadata[:method]} #{metadata[:path]} raised after #{ms}ms: " <>
        Exception.format(metadata.kind, metadata.reason, metadata.stacktrace)
    end)
  end

  defp default_level do
    case Application.get_env(:typesafe_api, :log_level) do
      nil -> env_level()
      level -> parse_level!(level, "config :typesafe_api, log_level:")
    end
  end

  defp env_level do
    case System.get_env("TYPESAFE_LOG_LEVEL") do
      nil -> :info
      "" -> :info
      level -> parse_level!(level, "TYPESAFE_LOG_LEVEL")
    end
  end

  @levels ~w(debug info notice warning error critical alert emergency)a
  # `warn` is Logger's deprecated spelling and still what most people type.
  @level_names @levels |> Map.new(&{Atom.to_string(&1), &1}) |> Map.put("warn", :warning)

  defp parse_level!(level, _source) when level in @levels, do: level
  defp parse_level!(:warn, _source), do: :warning

  defp parse_level!(level, source) when is_binary(level) or is_atom(level) do
    name = level |> to_string() |> String.trim() |> String.downcase()

    # Silently falling back to :info here is how someone asking for less
    # logging ends up with a line per request and no idea why.
    case Map.fetch(@level_names, name) do
      {:ok, parsed} ->
        parsed

      :error ->
        raise ArgumentError,
              "#{source} must be a Logger level, got: #{inspect(level)}. " <>
                "One of: #{Enum.map_join(@levels, ", ", &inspect/1)}."
    end
  end

  defp parse_level!(level, source) do
    raise ArgumentError, "#{source} must be a Logger level, got: #{inspect(level)}"
  end
end
