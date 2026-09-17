defmodule TypeSafeAPI.Client do
  @moduledoc """
  Connection settings for the TypeSafe API, resolved once and passed around.

  The client is a plain struct rather than a process: nothing about talking to
  the API needs shared state, so a struct keeps concurrency trivial (build once,
  use from any number of tasks) and keeps supervision trees out of your way.

  ## Configuration precedence

  `api_key`, `base_url`, `model`, `timeout`, `connect_timeout` and `finch` are
  resolved from, in order:

  1. the options passed to `new/1`
  2. application config: `config :typesafe_api, api_key: "...", model: "..."`
  3. environment variables, for the three settings that have one:
     `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`
  4. the built-in defaults (`https://api.typesafe.ai`, `jev-latest`, 10 000 ms,
     5 000 ms)

  `retry` and `req_options` are read from `new/1` only. They are structured
  values, not strings, and a retry policy in config would be resolved at a
  point where nothing can tell you it is wrong.

  Values are validated wherever they come from, so a stray
  `config :typesafe_api, base_url: :production` fails with a configuration
  error at `new/1` rather than a `FunctionClauseError` on the first request.
  Blank strings are ignored the same way in both, after trimming.

  The API key has no default; `new/1` raises `ArgumentError` when none is found.

  ## Placement

  Because it is a plain struct with no process behind it, a client is safe to
  share across processes: build one and pass it into every task, GenServer or
  controller that needs it. Build it in a function, not in a module attribute.
  A module attribute is evaluated at compile time, which reads the API key
  from whatever environment compiled the release rather than the one running
  it. A function called at application start, or a small `Application.get_env`
  lookup memoized in `:persistent_term`, keeps configuration at runtime where
  it belongs.

  `req_options` merges rather than replaces. The client's `req_options` are
  applied first, then the ones passed to a single call, so a per-call option
  wins over the same key on the client. Anything the client sets and the call
  does not mention survives.

  ## Connections

  `Req` picks a Finch connection pool by the `connect_options` it is given,
  so two requests with different `connect_options` do not share a pool.
  Varying that option per call spins up a separate pool each time and throws
  away connection reuse. Set `connect_options` once on the client, in
  `req_options`, and leave it out of per-call options. The client's
  `connect_timeout` is merged underneath, so it survives unless you set
  `timeout:` inside `connect_options` yourself.

  For that reason the connect timeout is a client setting, `connect_timeout`
  (5 000 ms by default), and not the per-call `:timeout`. The per-call
  `:timeout` bounds waiting for the response (`receive_timeout`) only, so
  calls that differ in timeout still share one pool. See `TypeSafeAPI.HTTP` for
  the full list of options that do and do not affect pool identity.

  To size the pool yourself, start a `Finch` in your own supervision tree and
  name it with `finch:`:

      children = [{Finch, name: MyApp.Finch, pools: %{default: [size: 50, count: 2]}}]
      TypeSafeAPI.new(api_key: key, finch: MyApp.Finch)

  `Req` refuses `:finch` and `:connect_options` together, so a client with
  `finch:` sends neither `connect_options` nor `connect_timeout`: connection
  settings for a pool you own belong in its own child spec. `new/1` raises
  rather than letting the two be set at once.

  `req_options` is an escape hatch for `Req`, not a second way to configure
  this library. `:retry`, `:auth`, `:base_url` and `:finch` are rejected there
  with a message naming the client option to use instead; a `retry:` that
  slipped through would run `Req`'s own retry loop nested inside this
  library's, multiplying attempts and escaping the wall-clock budget.

  The API key is redacted by this module's `Inspect` implementation, so it
  does not leak through `inspect/1`, a crash dump or a logged struct. It is
  never copied into telemetry metadata or into `TypeSafeAPI.Error` bodies either;
  those carry the request as sent minus the `Authorization` header.
  """

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_timeout 10_000
  @default_connect_timeout 5_000

  @env %{
    api_key: "TYPESAFE_API_KEY",
    base_url: "TYPESAFE_BASE_URL",
    model: "TYPESAFE_DEFAULT_MODEL"
  }

  @schema NimbleOptions.new!(
            api_key: [
              type: :string,
              doc: "API key. Falls back to app config, then `TYPESAFE_API_KEY`."
            ],
            base_url: [
              type: :string,
              doc: "API base URL. Falls back to `TYPESAFE_BASE_URL`, then the public API."
            ],
            model: [
              type: :string,
              doc: "Default model. Falls back to `TYPESAFE_DEFAULT_MODEL`, then `jev-latest`."
            ],
            timeout: [
              type: :pos_integer,
              doc: "Per-operation timeout in milliseconds. Defaults to 10 000."
            ],
            connect_timeout: [
              type: :pos_integer,
              doc:
                "Timeout in milliseconds for establishing a connection. Defaults to 5 000. " <>
                  "Client-level on purpose: it feeds `connect_options`, which selects the " <>
                  "Finch pool, so it must not vary per call. Ignored when `finch:` is set, " <>
                  "and overridden by a `timeout:` inside your own `connect_options`."
            ],
            finch: [
              type: :atom,
              doc:
                "Name of a `Finch` pool you start and supervise yourself, for control over " <>
                  "pool size. Suppresses `connect_options` and `connect_timeout`, which " <>
                  "`Req` refuses to combine with a named pool."
            ],
            retry: [
              type: TypeSafeAPI.Retry.option_type(),
              default: [],
              doc: "Retry policy; see `TypeSafeAPI.Retry.new/1`."
            ],
            req_options: [
              type: {:custom, __MODULE__, :validate_req_options, []},
              default: [],
              doc:
                "Escape hatch: options merged into the underlying `Req.Request`. " <>
                  "`:retry`, `:auth`, `:base_url` and `:finch` are rejected; each has a " <>
                  "client option of its own."
            ]
          )

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          model: String.t(),
          timeout: pos_integer(),
          connect_timeout: pos_integer(),
          finch: atom(),
          retry: TypeSafeAPI.Retry.t(),
          req_options: keyword()
        }

  @enforce_keys [:api_key, :base_url, :model, :timeout, :connect_timeout, :retry, :req_options]
  defstruct [
    :api_key,
    :base_url,
    :model,
    :timeout,
    :connect_timeout,
    :finch,
    :retry,
    :req_options
  ]

  @doc """
  Builds a client, resolving configuration as described in the module docs.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    finch = resolve(opts, :finch, nil, &check_atom/2)

    %__MODULE__{
      api_key: resolve(opts, :api_key, nil, &check_string/2) || raise_missing_key(),
      base_url:
        opts
        |> resolve(:base_url, @default_base_url, &check_string/2)
        |> String.trim_trailing("/"),
      model: resolve(opts, :model, @default_model, &check_string/2),
      timeout: resolve(opts, :timeout, @default_timeout, &check_timeout/2),
      connect_timeout: resolve(opts, :connect_timeout, @default_connect_timeout, &check_timeout/2),
      finch: finch,
      retry: TypeSafeAPI.Retry.new(opts[:retry]),
      req_options: check_pool_settings(opts[:req_options], finch)
    }
  end

  @doc false
  # Nothing this library owns belongs in the Req escape hatch: each of these
  # has a client option, and setting them here breaks the library quietly.
  @owned_req_options %{
    retry: "the `retry:` client option",
    auth: "the `api_key:` client option",
    base_url: "the `base_url:` client option",
    finch: "the `finch:` client option"
  }

  @spec validate_req_options(term()) :: {:ok, keyword()} | {:error, String.t()}
  def validate_req_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      case Enum.find(Map.keys(@owned_req_options), &Keyword.has_key?(options, &1)) do
        nil -> {:ok, options}
        key -> {:error, "req_options must not set #{key}: use #{@owned_req_options[key]}"}
      end
    else
      {:error, "expected a keyword list, got: #{inspect(options)}"}
    end
  end

  def validate_req_options(other) do
    {:error, "expected a keyword list, got: #{inspect(other)}"}
  end

  # Req raises "cannot set both :finch and :connect_options" on every request,
  # so catch it once, here, where the message can say what to do about it.
  defp check_pool_settings(req_options, nil), do: req_options

  defp check_pool_settings(req_options, finch) do
    if Keyword.has_key?(req_options, :connect_options) do
      raise ArgumentError,
            "cannot set both finch: #{inspect(finch)} and req_options connect_options. " <>
              "A pool you name owns its own connection settings; put them in its child spec."
    end

    req_options
  end

  # Whatever the source, the value is checked, so a bad app config fails here
  # with a message that names the source rather than deep inside Req.
  defp resolve(opts, key, default, check) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        case app_env(key) do
          nil -> check.(system_env(key) || default, {:env, key})
          value -> check.(value, {:config, key})
        end
    end
  end

  # nil means "not configured anywhere"; the caller decides whether that is fatal.
  defp check_string(nil, _source), do: nil
  defp check_string(value, _source) when is_binary(value), do: value

  defp check_string(value, source) do
    raise ArgumentError, "#{describe(source)} must be a string, got: #{inspect(value)}"
  end

  defp check_atom(value, _source) when is_atom(value), do: value

  defp check_atom(value, source) do
    raise ArgumentError, "#{describe(source)} must be an atom, got: #{inspect(value)}"
  end

  defp check_timeout(value, _source) when is_integer(value) and value > 0, do: value

  defp check_timeout(value, source) do
    raise ArgumentError, "#{describe(source)} must be a positive integer, got: #{inspect(value)}"
  end

  defp describe({:config, key}), do: "config :typesafe_api, #{key}:"
  defp describe({:env, key}), do: "#{key}"

  defp app_env(key) do
    :typesafe_api |> Application.get_env(key) |> blank_to_nil()
  end

  defp system_env(key) do
    case Map.fetch(@env, key) do
      {:ok, name} -> blank_to_nil(System.get_env(name))
      :error -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp raise_missing_key do
    raise ArgumentError,
          "no TypeSafe API key found. Pass api_key: to TypeSafeAPI.new/1, set " <>
            "config :typesafe_api, api_key: \"...\", or export TYPESAFE_API_KEY."
  end

  defimpl Inspect do
    def inspect(client, opts) do
      Inspect.Any.inspect(%{client | api_key: "[REDACTED]"}, opts)
    end
  end
end
