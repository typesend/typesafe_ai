# Configuration and concurrency

How client settings are resolved, what every client and call option does, and how to
run many evaluations at once without exhausting your connection pool.

## Option precedence

Every `TypeSafeAPI.Client` setting is resolved in this order, first match wins:

1. the option passed to `TypeSafeAPI.new/1`
2. application config: `config :typesafe_api, api_key: "...", base_url: "...", model: "..."`
3. an environment variable, for the three settings that have one:
   `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`
4. the built-in default

`timeout` and `connect_timeout` have no environment variable; they fall back straight
from the explicit option (or app config, `config :typesafe_api, timeout: ...`) to their
default. `TYPESAFE_LOG_LEVEL` is separate from client configuration: it is read by
`TypeSafeAPI.Telemetry.attach_logger/1`, not by `TypeSafeAPI.new/1`, and only when no
`:level` option is given to `attach_logger/1`.

| setting            | app config key | env var                   | default                    |
| ------------------ | --------------- | -------------------------- | --------------------------- |
| `api_key`          | `:api_key`      | `TYPESAFE_API_KEY`         | none — raises if missing    |
| `base_url`         | `:base_url`     | `TYPESAFE_BASE_URL`        | `https://api.typesafe.ai`   |
| `model`             | `:model`        | `TYPESAFE_DEFAULT_MODEL`   | `jev-latest`                |
| `timeout`           | `:timeout`      | —                           | `10_000` ms                 |
| `connect_timeout`   | `:connect_timeout` | —                        | `5_000` ms                  |
| (logger level)      | `:log_level`    | `TYPESAFE_LOG_LEVEL`       | `:info`                     |

An empty-string environment variable or app config value is treated as unset and falls
through to the next source, so an env var left blank in a shell profile does not
shadow app config underneath it.

## Client options

`TypeSafeAPI.new/1` accepts:

* `api_key` — string, no default; `new/1` raises `ArgumentError` when none is found
  anywhere in the precedence chain.
* `base_url` — string, defaults to `https://api.typesafe.ai`.
* `model` — string, defaults to `jev-latest`, a pinned alias the API resolves to a
  versioned id. Call `TypeSafeAPI.models/1` for the ids your account can pin to instead.
* `timeout` — positive integer milliseconds, default `10_000`. Sets `receive_timeout`
  for every call made with this client, unless overridden per call.
* `connect_timeout` — positive integer milliseconds, default `5_000`. How long to wait
  for the TCP/TLS handshake. Client-level only — see "Finch pools" below for why.
* `retry` — keyword list, default `[]`, passed to `TypeSafeAPI.Retry.new/1`.
* `req_options` — keyword list, default `[]`. Escape hatch merged into the underlying
  `Req.Request`; see "Sharing your existing Finch pool" below.

Per-call options on `TypeSafeAPI.evaluate/4` (and `evaluate_prepared/4`) are a subset:
`model`, `timeout`, `retry`, `req_options`, `telemetry`. Each overrides the client's
value for that one call; `req_options` merges on top of the client's `req_options`
rather than replacing it, so a per-call option wins only for the keys it sets.

## Finch pools and connection reuse

`Req` selects (or starts) a Finch connection pool by the connection settings of a
request. Two requests whose `connect_options` differ do **not** share a pool, so
varying the wrong option per call quietly throws away connection reuse.

What selects a pool:

* the client's `finch:` option — names a pool you start and supervise yourself.
* `req_options` carrying `connect_options:` — a different value is a different pool.
  What this library sets as the connect timeout is merged *under* yours, so
  `connect_timeout` survives unless you set `timeout:` inside `connect_options`.
* the client's `connect_timeout`, which is exactly the `connect_options: [timeout:
  ...]` this library sets; it is fixed for the life of a client.

What does **not** select a pool: the client's `timeout` and the per-call `:timeout`,
which means the same thing in `evaluate_many/4` — they only set `receive_timeout`;
also `:retry`, `:telemetry`, headers, the body, and the path. Vary `:timeout` per call
as much as you like; set `connect_options` once, on the client.

## `evaluate_many/4`: batching many states

```elixir
TypeSafeAPI.evaluate_many(client, states, questions,
  max_concurrency: 8,
  task_timeout: 40_000,
  timeout: 5_000,
  ordered: true,
  on_error: :collect
)
```

The question set is validated and encoded once, then each state runs as its own task
under `Task.Supervisor.async_stream_nolink/6`, on the supervisor this library's
application starts. The tasks are deliberately *not* linked to the caller: a task that
raises becomes one failed outcome instead of taking the calling process, and every
other in-flight request, down with it. Options:

* `max_concurrency` — positive integer, default `8`. A guess: TypeSafe has not
  published rate limits. Raise it if your account allows, and watch for
  `:rate_limited` errors, which the retry policy already absorbs short bursts of.
* `task_timeout` — the cap in milliseconds on one state's whole **task**, covering
  every retry and every backoff delay. Defaults to the retry budget plus one attempt
  timeout (`40_000` ms with every other default), or `60_000` when the budget is
  disabled (`retry: [budget: nil]`).
* `ordered` — boolean, default `true`. `false` yields outcomes as they finish rather
  than in input order.
* `on_error` — `:collect` (default) returns `{:error, _}` in place for a failed state
  without failing the batch, or `:raise` to raise the first error once every task has
  been collected. Under `ordered: false` that "first" error is the first task to
  *finish*, not the earliest state in the input.

Every other option (`model`, `timeout`, `retry`, `req_options`, `telemetry`) passes
through to each individual `evaluate/4` call and means exactly what it means there.
`:timeout` in particular is still one HTTP attempt, not the task.

An invalid *question set* is the one failure with no per-state slot to sit in, so it
comes back as a bare `{:error, error}` rather than a list. Under `on_error: :raise` it
raises like any other error. Pass a `%TypeSafeAPI.SystemOne.Prepared{}` from
`TypeSafeAPI.SystemOne.prepare/1` instead of a question set to skip that path.

### `timeout` vs `task_timeout`, concretely

The task timeout must always be large enough to let one call exhaust its retry
budget; if it is not, the stream kills a task that was still legitimately retrying.
That is why the default `task_timeout` is derived from the retry budget:

```
default task_timeout = retry.budget + timeout   # 40_000 ms with defaults
                     = 30_000       + 10_000
```

If you shorten `timeout` to fail fast on one slow question, either leave
`task_timeout` alone (it still generously covers the shorter attempts) or shorten both:

```elixir
TypeSafeAPI.evaluate_many(client, states, questions,
  timeout: 3_000,        # give up on a single slow attempt sooner
  task_timeout: 15_000   # and don't let the task run much longer than that
)
```

### The `Task.async_stream` timeout gotcha

If you roll your own fan-out instead of `evaluate_many/4` — say, to interleave other
work between calls — remember that `Task.async_stream/3`'s `:timeout` option is a
**per-task wall-clock deadline**, not a per-HTTP-attempt one. A task that is still
inside its second or third retry when the deadline hits is killed outright
(`on_timeout: :kill_task`), and the caller sees `{:exit, :timeout}`, not an ordinary
`TypeSafeAPI.Error`. Size that timeout the same way `evaluate_many/4` does: at least
the retry budget plus one attempt timeout, never just the attempt timeout alone.
`evaluate_many/4`'s own `unwrap/1` turns that `{:exit, :timeout}` into
`%TypeSafeAPI.Error{type: :timeout}` for you; a hand-rolled `Task.async_stream/3` call
gets the raw exit tuple and has to handle it itself.

## Sharing your existing Finch pool

Shops that already run Finch (directly, or through another Req- or Tesla-based
client) can point this library at that same pool instead of letting it start its own,
with the `finch:` client option. It is also the only way to control pool size:

```elixir
# application.ex
children = [
  {Finch, name: MyApp.Finch, pools: %{default: [size: 50, count: 2]}}
  # ... your other children
]

# wherever you build the client
TypeSafeAPI.new(
  api_key: System.fetch_env!("TYPESAFE_API_KEY"),
  finch: MyApp.Finch
)
```

`connect_timeout` does **not** apply to a pool you own: `Req` refuses `:finch` and
`:connect_options` together, so a client with `finch:` sends neither. Connection
settings for `MyApp.Finch` belong in its own child spec, which is where you were
already configuring them. Setting `finch:` alongside a `connect_options` in
`req_options` raises at `TypeSafeAPI.new/1` rather than on every request.

`:finch` in `req_options` is rejected outright, with a message naming the client
option — as are `:retry`, `:auth` and `:base_url`, each of which has one.

### Proxy and TLS options

A proxy or custom TLS configuration goes through `req_options`' `connect_options`,
same as any other `Req` client:

```elixir
TypeSafeAPI.new(
  api_key: api_key,
  req_options: [
    connect_options: [
      timeout: 5_000,
      proxy: {:http, "proxy.internal", 8080, []},
      transport_opts: [cacertfile: "/etc/ssl/certs/internal-ca.pem"]
    ]
  ]
)
```

Set this once, on the client. A `connect_options` that differs between calls (for
example, passed per-call instead of on the client) starts a new Finch pool for every
distinct value, defeating connection reuse — the same reason `connect_timeout` is a
client-only setting.
