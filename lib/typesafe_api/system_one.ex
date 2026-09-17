defmodule TypeSafeAPI.SystemOne do
  @moduledoc """
  Layer 2 for the evaluation endpoint: typed questions in, typed answers out.

  This module is the seam between the caller's structs and `TypeSafeAPI.HTTP`.
  It validates questions locally, records the caller's keys, encodes the body,
  posts it, and decodes the answers back under the caller's keys. Everything
  that can fail before the network does so with a `:validation` error and no
  request is sent: a malformed question, a per-call option this library does
  not accept, and a state that has no JSON representation all fail the same
  way. Nothing in this path raises.

  `prepare/1` and `evaluate_prepared/4` split the work so `TypeSafeAPI.evaluate_many/4`
  can validate and encode a question set once and reuse it for every state.
  `evaluate/4` also takes a `TypeSafeAPI.SystemOne.Prepared` in place of a
  question set, so a caller holding one does not have to reach for a second
  function name.
  """

  alias TypeSafeAPI.{Client, Error, HTTP, Question, Result}
  alias TypeSafeAPI.JSON.Encoded
  alias TypeSafeAPI.SystemOne.Prepared

  @path "/v1/systemone"

  @schema NimbleOptions.new!(
            model: [type: :string, doc: "Model for this call; defaults to the client's model."],
            timeout: [type: :pos_integer, doc: "Timeout in milliseconds for this call."],
            retry: [
              type: TypeSafeAPI.Retry.option_type(),
              doc: "Retry policy for this call; see `TypeSafeAPI.Retry.new/1`."
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

  `questions` is a question set (see `TypeSafeAPI.Question.normalize/1`) or an
  already-prepared one from `prepare/1`, which is passed straight through
  without being validated and encoded again.

  See `TypeSafeAPI.evaluate/4` for the public entry point and examples.
  """
  @spec evaluate(Client.t(), state(), Question.input() | Prepared.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def evaluate(client, state, questions, opts \\ [])

  def evaluate(%Client{} = client, state, %Prepared{} = prepared, opts) do
    evaluate_prepared(client, state, prepared, opts)
  end

  def evaluate(%Client{} = client, state, questions, opts) do
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
      {:ok, Prepared.new(normalized)}
    end
  end

  @doc """
  Evaluates `state` against a question set from `prepare/1`.
  """
  @spec evaluate_prepared(Client.t(), state(), Prepared.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def evaluate_prepared(%Client{} = client, state, %Prepared{} = prepared, opts \\ []) do
    with {:ok, opts} <- validate_options(opts) do
      run(client, state, prepared, opts)
    end
  end

  @doc false
  # Validates per-call options once and builds the retry policy, so a batch
  # caller (`TypeSafeAPI.FanOut`) can pay for it once rather than per state.
  @spec validate_options(keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def validate_options(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      # validate!/1 keeps the keyword list so HTTP.build/5 can merge it onto the client's
      # policy; new/1 would fill in every default and silently reset the client's settings.
      {:ok, opts} -> {:ok, Keyword.replace_lazy(opts, :retry, &TypeSafeAPI.Retry.validate!/1)}
      {:error, error} -> {:error, Error.validation(Exception.message(error))}
    end
  end

  def validate_options(opts) do
    {:error, Error.validation("options must be a keyword list, got: #{inspect(opts)}")}
  end

  @doc false
  # The raising form, for `TypeSafeAPI.FanOut`, where a bad option is a mistake
  # in the batch call itself rather than in one of the states.
  @spec validate_options!(keyword()) :: keyword()
  def validate_options!(opts) do
    case validate_options(opts) do
      {:ok, opts} -> opts
      {:error, error} -> raise error
    end
  end

  @doc false
  # The request itself, for options already passed through `validate_options!/1`.
  @spec run(Client.t(), state(), Prepared.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def run(%Client{} = client, state, %Prepared{} = prepared, opts) when is_list(opts) do
    with {:ok, body} <- encodable_body(client, state, prepared, opts),
         {:ok, response} <- HTTP.request(client, :post, @path, body, http_opts(prepared, opts)),
         {:ok, result} <-
           Result.decode(response.body, prepared.questions, prepared.keys, response.request_id) do
      {:ok, %{result | retry_count: response.retry_count}}
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

  # The state is the one part of the body the caller supplies raw, so it is the
  # one part that can fail to encode. Encoding it here, before the request is
  # built, turns what would be a `Protocol.UndefinedError` raised inside the
  # telemetry span in `TypeSafeAPI.HTTP` into an ordinary `:validation` error —
  # and under `TypeSafeAPI.evaluate_many/4`, into one failed state instead of a
  # dead task. The bytes are kept, the same way `Prepared` keeps the questions',
  # so the request splices them rather than walking the state a second time.
  defp encodable_body(client, state, prepared, opts) do
    with {:ok, state} <- encode_state(state) do
      {:ok, body(client, state, prepared, opts)}
    end
  end

  defp encode_state(state) when is_binary(state), do: {:ok, state}

  defp encode_state(state) when is_map(state) or is_list(state) do
    with :ok <- reject_charlist(state), do: cache_encoded(state)
  end

  defp encode_state(other) do
    {:error, Error.validation("state must be a string, map, or list, got: #{inspect(other)}")}
  end

  # A charlist is a list of integers, so it encodes to a JSON array of code
  # points and the model is asked about `[117, 114, ...]`. Nothing downstream
  # can tell that apart from a state that really is a list of numbers, so it is
  # caught here instead.
  defp reject_charlist(state) when is_list(state) and state != [] do
    if List.ascii_printable?(state) do
      {:error,
       Error.validation(
         "state is a charlist (#{inspect(state)}), which would be sent as a JSON array of " <>
           "code points. Pass a string instead: List.to_string/1, or \"...\" rather than ~c\"...\"."
       )}
    else
      :ok
    end
  end

  defp reject_charlist(_state), do: :ok

  defp cache_encoded(state) do
    {:ok, Encoded.new(state)}
  rescue
    exception ->
      {:error,
       Error.validation(
         "state cannot be encoded as JSON: #{first_line(Exception.message(exception))}. " <>
           "Structs, tuples and keyword lists have no JSON representation; convert the state " <>
           "to plain maps, lists, strings, numbers, booleans and nil first."
       )}
  end

  defp first_line(message) do
    message |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end
end
