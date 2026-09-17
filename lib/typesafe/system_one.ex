defmodule TypeSafe.SystemOne do
  @moduledoc """
  Layer 2 for the evaluation endpoint: typed questions in, typed answers out.

  This module is the seam between the caller's structs and `TypeSafe.HTTP`.
  It validates questions locally, records the caller's keys, encodes the body,
  posts it, and decodes the answers back under the caller's keys. Everything
  that can fail before the network does so with a `:validation` error and no
  request is sent.

  `prepare/1` and `evaluate_prepared/4` split the work so `TypeSafe.evaluate_many/4`
  can validate and encode a question set once and reuse it for every state.
  """

  alias TypeSafe.{Client, Error, HTTP, Keys, Question, Result}
  alias TypeSafe.SystemOne.Prepared

  @path "/v1/systemone"

  @schema NimbleOptions.new!(
            model: [type: :string, doc: "Model for this call; defaults to the client's model."],
            timeout: [type: :pos_integer, doc: "Timeout in milliseconds for this call."],
            retry: [
              type: TypeSafe.Retry.option_type(),
              doc: "Retry policy for this call; see `TypeSafe.Retry.new/1`."
            ],
            req_options: [type: :keyword_list, doc: "Extra `Req` options for this call."],
            telemetry: [type: :map, doc: "Extra metadata merged into telemetry events."]
          )

  @typedoc "The state to evaluate: text, or JSON-shaped structured data."
  @type state :: String.t() | map() | list()

  @doc "The evaluation endpoint path."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Per-call options accepted by `evaluate/4`.

  #{NimbleOptions.docs(@schema)}
  """
  @spec options_schema() :: NimbleOptions.t()
  def options_schema, do: @schema

  @doc """
  Evaluates `state` against `questions`.

  See `TypeSafe.evaluate/4` for the public entry point and examples.
  """
  @spec evaluate(Client.t(), state(), Question.input(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def evaluate(%Client{} = client, state, questions, opts \\ []) do
    with {:ok, prepared} <- prepare(questions) do
      evaluate_prepared(client, state, prepared, opts)
    end
  end

  @doc """
  Validates and encodes a question set once, for reuse across many states.
  """
  @spec prepare(Question.input()) :: {:ok, Prepared.t()} | {:error, Error.t()}
  def prepare(questions) do
    with {:ok, normalized} <- Question.normalize(questions) do
      {:ok,
       %Prepared{
         questions: normalized,
         count: length(normalized),
         encoded: Question.encode_all(normalized),
         keys: Keys.build(normalized)
       }}
    end
  end

  @doc """
  Evaluates `state` against a question set from `prepare/1`.
  """
  @spec evaluate_prepared(Client.t(), state(), Prepared.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def evaluate_prepared(%Client{} = client, state, %Prepared{} = prepared, opts \\ []) do
    run(client, state, prepared, validate_options!(opts))
  end

  @doc false
  # Validates per-call options once and builds the retry policy, so a batch
  # caller (`TypeSafe.FanOut`) can pay for it once rather than per state.
  @spec validate_options!(keyword()) :: keyword()
  def validate_options!(opts) do
    opts
    |> NimbleOptions.validate!(@schema)
    |> Keyword.replace_lazy(:retry, &TypeSafe.Retry.new/1)
  end

  @doc false
  # The request itself, for options already passed through `validate_options!/1`.
  @spec run(Client.t(), state(), Prepared.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def run(%Client{} = client, state, %Prepared{} = prepared, opts) when is_list(opts) do
    with :ok <- validate_state(state),
         body = body(client, state, prepared, opts),
         {:ok, response} <- HTTP.request(client, :post, @path, body, http_opts(prepared, opts)),
         {:ok, result} <- Result.decode(response.body, prepared.questions, prepared.keys) do
      {:ok, %{result | request_id: response.request_id}}
    end
  end

  defp body(client, state, %Prepared{} = prepared, opts) do
    %{
      "state" => state,
      "model" => Keyword.get(opts, :model, client.model),
      "questions" => prepared.encoded
    }
  end

  defp http_opts(%Prepared{} = prepared, opts) do
    telemetry =
      opts
      |> Keyword.get(:telemetry, %{})
      |> Map.put(:question_count, prepared.count)

    opts
    |> Keyword.take([:timeout, :retry, :req_options])
    |> Keyword.put(:telemetry, telemetry)
  end

  defp validate_state(state) when is_binary(state) or is_map(state) or is_list(state), do: :ok

  defp validate_state(other) do
    {:error, Error.validation("state must be a string, map, or list, got: #{inspect(other)}")}
  end
end
