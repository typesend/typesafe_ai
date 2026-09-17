defmodule TypeSafe.Telemetry do
  @moduledoc """
  Telemetry events emitted by this library, plus a small logger handler.

  Every HTTP call is wrapped in a `:telemetry.span/3`, which yields:

    * `[:typesafe, :request, :start]` with measurements `%{system_time: integer}`
    * `[:typesafe, :request, :stop]` with measurements `%{duration: integer}`
    * `[:typesafe, :request, :exception]` with `%{duration: integer}` and the
      usual `kind`, `reason`, `stacktrace` metadata

  Durations are in native time units; convert with `System.convert_time_unit/3`.

  ## Metadata

  The start event carries `method`, `path`, `model`, and `question_count`.
  The stop event adds:

    * `status` - HTTP status, or `nil` when no response arrived
    * `retry_count` - retries performed by `TypeSafe.Retry`
    * `input_tokens` / `output_tokens` - from the response `usage`, or `nil`
    * `error` - a `TypeSafe.Error` when the call failed, otherwise `nil`

  `question_count` and `model` describe the request as sent, so a raw
  `TypeSafe.HTTP.post/4` call still reports them when the body has them.

  ## Failures are stop events, not exception events

  Every failure this library knows how to name is a normal outcome of the
  span, so it arrives as a `:stop` event with `metadata.error` set to a
  `%TypeSafe.Error{}`. That covers `:auth`, `:rate_limited`, `:overloaded`, `:timeout`,
  `:connection`, `:unexpected` and `:validation` alike: an expired key, a 429
  that outlived its retries, a socket that never opened, and a body the
  library could not decode all look the same to a handler, and all of them
  come with a `duration`. The `:exception` event fires only when code raises,
  which in practice means a bug in a handler, in a `Req` step, or in this
  library. A handler that watches only `:exception` will see none of the
  failures that matter operationally.

  ## Attaching a handler

      :telemetry.attach("typesafe-watch", [:typesafe, :request, :stop], fn _event, _m, meta, tokens ->
        if meta.error, do: Logger.warning("typesafe \#{meta.error.type}: \#{Exception.message(meta.error)}")
        :counters.add(tokens, 1, meta[:input_tokens] || 0)
        :counters.add(tokens, 2, meta[:output_tokens] || 0)
      end, :counters.new(2, [:write_concurrency]))

  Read the running totals back with `:counters.get(tokens, 1)` and
  `:counters.get(tokens, 2)`. The `duration` in the measurements map is in
  native time units; turn it into milliseconds with
  `System.convert_time_unit(duration, :native, :millisecond)`.

  ## Logging

  `attach_logger/1` attaches a handler that logs one line per request at the
  level given (or `TYPESAFE_LOG_LEVEL`, default `:info`).
  """

  require Logger

  @prefix [:typesafe, :request]
  @handler_id "typesafe-ai-logger"

  @doc "The telemetry event prefix, `[:typesafe, :request]`."
  @spec prefix() :: [atom()]
  def prefix, do: @prefix

  @doc """
  Runs `fun` inside a `[:typesafe, :request]` span.

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
  Attaches a `Logger` handler for request stop and exception events.

  ## Options

    * `:level` - log level, defaults to `TYPESAFE_LOG_LEVEL` or `:info`
  """
  @spec attach_logger(keyword()) :: :ok | {:error, :already_exists}
  def attach_logger(opts \\ []) do
    level = Keyword.get_lazy(opts, :level, &default_level/0)

    :telemetry.attach_many(
      @handler_id,
      [@prefix ++ [:stop], @prefix ++ [:exception]],
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc "Detaches the handler attached by `attach_logger/1`."
  @spec detach_logger() :: :ok | {:error, :not_found}
  def detach_logger, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(@prefix ++ [:stop], %{duration: duration}, metadata, %{level: level}) do
    ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.log(level, fn ->
      base =
        "typesafe #{metadata[:method]} #{metadata[:path]} -> #{metadata[:status] || "no response"} " <>
          "in #{ms}ms (retries: #{metadata[:retry_count] || 0}, model: #{metadata[:model]})"

      case metadata[:error] do
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
    (Application.get_env(:typesafe_api, :log_level) || System.get_env("TYPESAFE_LOG_LEVEL"))
    |> parse_level()
  end

  @levels ~w(debug info notice warning error critical alert emergency)a
  @level_names Map.new(@levels, &{Atom.to_string(&1), &1})

  defp parse_level(level) when level in @levels, do: level

  defp parse_level(level) when is_binary(level) do
    Map.get(@level_names, level |> String.trim() |> String.downcase(), :info)
  end

  defp parse_level(_), do: :info
end
