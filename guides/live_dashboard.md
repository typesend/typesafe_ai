# LiveDashboard metrics

Every call this library makes emits a `[:typesafe_api, :request, :stop]` telemetry event
carrying the status, the retries it took, and the token usage the API reported.
`TypeSafeAPI.Telemetry.metrics/0` turns those events into `Telemetry.Metrics` definitions, so
a Phoenix LiveDashboard (or any other reporter) can show them without you writing a handler.

Add the optional dependency:

```elixir
{:telemetry_metrics, "~> 1.0"}
```

## The metrics

| Metric | Type | Tags | What it answers |
| --- | --- | --- | --- |
| `typesafe_api.request.count` | counter | method, path, status | How many calls, and how many were not 200 |
| `typesafe_api.request.duration` | distribution (ms) | method, path, status | How slow the API is right now |
| `typesafe_api.request.retry_count` | sum | method, path | How much the retry policy is working |
| `typesafe_api.request.error.count` | counter | method, path, error_type | Which failures: `:auth`, `:rate_limited`, `:timeout`, ... |
| `typesafe_api.request.input_tokens` | sum | model | Spend, by model |
| `typesafe_api.request.output_tokens` | sum | model | Spend, by model |
| `typesafe_api.request.exception.count` | counter | method, path, kind | Bugs: a raise, not a returned error |

`duration` is a `distribution` rather than a `summary` on purpose: `summary` is the one
definition `TelemetryMetricsPrometheus` does not implement, and these definitions are meant
to survive a change of reporter. It ships bucket boundaries in milliseconds through
`reporter_options: [buckets: ...]`; reporters that do their own bucketing ignore them.

The `status` tag is `"none"` on a call where no response arrived at all, rather than an
empty label you cannot group by.

The error counter keeps only events whose metadata carries a `TypeSafeAPI.Error`, and tags
them with `error_type`. Failures are `:stop` events, not `:exception` events, which is why
a dashboard that watches only exceptions looks healthy while every call is failing. See
`TypeSafeAPI.Telemetry` for why.

## Phoenix LiveDashboard

Most Phoenix apps already have a `MyAppWeb.Telemetry` module with a `metrics/0` function.
Append this library's list to it:

```elixir
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def metrics do
    [
      # ... your Phoenix, Ecto and VM metrics ...
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond})
    ] ++ TypeSafeAPI.Telemetry.metrics()
  end
end
```

LiveDashboard picks them up from the `metrics:` option it is already given in your router:

```elixir
live_dashboard "/dashboard", metrics: MyAppWeb.Telemetry
```

If you are wiring LiveDashboard up from scratch, the `metrics:` option can also take the
list directly:

```elixir
live_dashboard "/dashboard", metrics: {TypeSafeAPI.Telemetry, :metrics}
```

Charts appear under a **TypeSafe API** heading if you group them, for example by passing
`reporter_options: [nav: "TypeSafe API"]` to each definition you care about.

## Without Phoenix

Any `Telemetry.Metrics` reporter works. The console reporter prints every event it sees,
which is enough to check your wiring in `iex -S mix`:

```elixir
{:ok, _pid} =
  Telemetry.Metrics.ConsoleReporter.start_link(metrics: TypeSafeAPI.Telemetry.metrics())
```

In a release, put the reporter in your supervision tree next to the rest of your telemetry:

```elixir
children = [
  {Telemetry.Metrics.ConsoleReporter, metrics: TypeSafeAPI.Telemetry.metrics()}
]
```

Swap `ConsoleReporter` for `TelemetryMetricsStatsd`, `TelemetryMetricsPrometheus` or whatever
your metrics pipeline speaks; the definitions do not change. Every metric here is a
`counter`, `sum` or `distribution`, the three every reporter implements.

## One line of logs instead

If all you want is a line per request, skip metrics entirely:

```elixir
TypeSafeAPI.Telemetry.attach_logger(level: :info)
```

Successful calls log at `:level`; failed ones log at `:error_level`, `:warning` by default,
so a production logger set to `:warning` keeps showing you the failures while the happy
path stays quiet.
