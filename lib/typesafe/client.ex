defmodule TypeSafe.Client do
  @moduledoc """
  Connection settings for the TypeSafe API, resolved once and passed around.

  The client is a plain struct rather than a process: nothing about talking to
  the API needs shared state, so a struct keeps concurrency trivial (build once,
  use from any number of tasks) and keeps supervision trees out of your way.

  ## Configuration precedence

  Each setting is resolved from, in order:

  1. the options passed to `new/1`
  2. application config: `config :typesafe_api, api_key: "...", model: "..."`
  3. environment variables: `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`,
     `TYPESAFE_DEFAULT_MODEL`
  4. the built-in defaults (`https://api.typesafe.ai`, `jev-latest`, 10 000 ms)

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
  `req_options`, and leave it out of per-call options.

  The API key is redacted by this module's `Inspect` implementation, so it
  does not leak through `inspect/1`, a crash dump or a logged struct. It is
  never copied into telemetry metadata or into `TypeSafe.Error` bodies either;
  those carry the request as sent minus the `Authorization` header.
  """

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_timeout 10_000

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
            retry: [
              type: TypeSafe.Retry.option_type(),
              default: [],
              doc: "Retry policy; see `TypeSafe.Retry.new/1`."
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: "Escape hatch: options merged into the underlying `Req.Request`."
            ]
          )

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          model: String.t(),
          timeout: pos_integer(),
          retry: TypeSafe.Retry.t(),
          req_options: keyword()
        }

  @enforce_keys [:api_key, :base_url, :model, :timeout, :retry, :req_options]
  defstruct [:api_key, :base_url, :model, :timeout, :retry, :req_options]

  @doc """
  Builds a client, resolving configuration as described in the module docs.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    %__MODULE__{
      api_key: resolve(opts, :api_key, nil) || raise_missing_key(),
      base_url: opts |> resolve(:base_url, @default_base_url) |> String.trim_trailing("/"),
      model: resolve(opts, :model, @default_model),
      timeout: opts |> resolve(:timeout, @default_timeout) |> validate_timeout(),
      retry: TypeSafe.Retry.new(opts[:retry]),
      req_options: opts[:req_options]
    }
  end

  defp resolve(opts, key, default) do
    opts[key] || app_env(key) || system_env(key) || default
  end

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp validate_timeout(other) do
    raise ArgumentError, "timeout must be a positive integer, got: #{inspect(other)}"
  end

  defp app_env(key) do
    case Application.get_env(:typesafe_api, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp system_env(key) do
    case Map.fetch(@env, key) do
      {:ok, name} -> blank_to_nil(System.get_env(name))
      :error -> nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp raise_missing_key do
    raise ArgumentError,
          "no TypeSafe API key found. Pass api_key: to TypeSafe.new/1, set " <>
            "config :typesafe_api, api_key: \"...\", or export TYPESAFE_API_KEY."
  end

  defimpl Inspect do
    def inspect(client, opts) do
      Inspect.Any.inspect(%{client | api_key: "[REDACTED]"}, opts)
    end
  end
end
