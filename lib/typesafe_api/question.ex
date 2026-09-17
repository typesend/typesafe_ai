defmodule TypeSafeAPI.Question do
  @moduledoc """
  The three question types and the functions that validate and encode them.

  `instructions` is optional on all three types: the API requires only `type`
  for a Noul and `type` plus `criteria` for a Choice or a Score. Pass `nil`
  (or omit it, for `TypeSafeAPI.noul/1`) and the key is left out of the request
  rather than sent as `null`.

  Constructors never validate; validation happens once, locally, when a
  question set is sent (`TypeSafeAPI.evaluate/4`), so a Score with one level or a
  Choice with one option fails fast with a `:validation` error value instead
  of a round trip to the API. Only the three known types are accepted;
  anything else is a local `:validation` error too.

  Questions built at compile time (say, in a module attribute) can be checked
  eagerly with `validate!/1`, which raises `ArgumentError` so the mistake shows
  up at the line that made it.

  `questions` given to `TypeSafeAPI.evaluate/4` are a keyword list, or a list of
  `{id, question}` pairs — never a map: question order is the order the model
  reads them in and the order they travel on the wire, and an Elixir map has no
  order to preserve. `normalize/1` turns the list into an ordered
  `[{id, question}]` list, which is the shape the rest of the typed layer works
  with, and rejects two ids that would collide on the wire (`:billing` and
  `"billing"` are the same JSON key).

  Validation is also a promise about encoding: a question that passes
  `validate/1` can always be JSON-encoded. Descriptions and instructions are
  walked recursively, and anything `JSON` cannot encode — a struct, a tuple, a
  keyword list, a pid, a map keyed by something other than a string or an atom —
  is a `:validation` error rather than an exception from inside the encoder.
  """

  alias TypeSafeAPI.{Error, Keys}
  alias TypeSafeAPI.JSON.{Encoded, OrderedObject}
  alias TypeSafeAPI.Question.{Choice, Noul, Score}

  @typedoc "Anything the API accepts as a description: a string, map, or list."
  @type description :: String.t() | map() | list()

  @typedoc """
  Instructions for a question. Optional on every type: a `nil` is left out of
  the request rather than sent as `null`.
  """
  @type instructions :: description() | nil

  @type t :: Noul.t() | Choice.t() | Score.t()

  @typedoc "Questions as the caller passes them: a keyword list or list of pairs."
  @type input :: [{Keys.key(), t()}]

  @doc """
  Turns a keyword list (or list of `{id, question}` pairs) into an ordered
  `[{id, question}]` list, validating every id and question and rejecting two
  ids that share a wire name.

  Maps are not accepted: they have no order, and question order is what the
  model sees. Pass a keyword list instead.
  """
  @spec normalize(input()) :: {:ok, [{Keys.key(), t()}]} | {:error, Error.t()}
  def normalize(questions) when is_list(questions) do
    questions
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, message} -> {:halt, {:error, Error.validation(message)}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, Error.validation("at least one question is required")}
      {:ok, pairs} -> finish(Enum.reverse(pairs))
      error -> error
    end
  end

  def normalize(questions) when is_map(questions) and not is_struct(questions) do
    {:error,
     Error.validation(
       "questions must be a keyword list or list of {id, question} pairs, not a map: " <>
         "a map has no order, and question order is what the model sees"
     )}
  end

  def normalize(other) do
    {:error,
     Error.validation(
       "questions must be a keyword list or list of {id, question} pairs, got: #{inspect(other)}"
     )}
  end

  defp finish(pairs) do
    case validate_unique_ids(pairs) do
      :ok -> {:ok, pairs}
      {:error, message} -> {:error, Error.validation(message)}
    end
  end

  defp validate_unique_ids(pairs) do
    wire_ids = Enum.map(pairs, fn {id, _question} -> Keys.wire(id) end)

    case wire_ids -- Enum.uniq(wire_ids) do
      [] -> :ok
      [dup | _] -> {:error, "question id #{inspect(dup)} is given more than once"}
    end
  end

  defp normalize_entry({id, question}) when (is_atom(id) and not is_nil(id)) or is_binary(id) do
    case validate(question) do
      :ok -> {:ok, {id, question}}
      {:error, message} -> {:error, "question #{inspect(id)}: #{message}"}
    end
  end

  defp normalize_entry({id, _question}) do
    {:error, "question ids must be atoms or strings, got: #{inspect(id)}"}
  end

  defp normalize_entry(other) do
    {:error, "expected {id, question}, got: #{inspect(other)}"}
  end

  @doc "Validates a single question struct."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(%Noul{} = question), do: Noul.validate(question)
  def validate(%Choice{} = question), do: Choice.validate(question)
  def validate(%Score{} = question), do: Score.validate(question)

  def validate(other) do
    {:error,
     "expected a TypeSafeAPI.Question.Noul, Choice, or Score struct, got: #{inspect(other)}"}
  end

  @doc """
  Validates a question and raises `ArgumentError` if it is malformed.

  Returns the question unchanged, so it can wrap a constructor:

      @urgent TypeSafeAPI.Question.validate!(TypeSafeAPI.noul("Urgent?", true: "time-sensitive"))
  """
  @spec validate!(t()) :: t()
  def validate!(question) do
    case validate(question) do
      :ok -> question
      {:error, message} -> raise ArgumentError, "invalid question: " <> message
    end
  end

  @doc "Encodes a validated question to its JSON-ready wire map."
  @spec encode(t()) :: map()
  def encode(%Noul{} = question), do: Noul.encode(question)
  def encode(%Choice{} = question), do: Choice.encode(question)
  def encode(%Score{} = question), do: Score.encode(question)

  @doc """
  Encodes a normalized question list to the wire `questions` object,
  preserving the caller's order.

  The result is a `TypeSafeAPI.JSON.Encoded`: the object is serialized to JSON
  bytes here, once, so a question set reused across many states
  (`TypeSafeAPI.evaluate_many/4`) is not re-serialized per request. The
  `TypeSafeAPI.JSON.OrderedObject` it was built from is still available as
  `encoded.object`.
  """
  @spec encode_all([{Keys.key(), t()}]) :: Encoded.t()
  def encode_all(questions) when is_list(questions) do
    questions
    |> Enum.map(fn {id, question} -> {Keys.wire(id), encode(question)} end)
    |> OrderedObject.new()
    |> Encoded.new()
  end

  @doc false
  @spec validate_description(term(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_description(value, field, opts \\ [])

  def validate_description(nil, field, opts) do
    if opts[:allow_nil], do: :ok, else: {:error, "#{field} is required"}
  end

  def validate_description(value, field, _opts)
      when is_binary(value) or is_map(value) or is_list(value) do
    case encodable(value) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{field} #{reason}"}
    end
  end

  def validate_description(value, field, _opts) do
    {:error, "#{field} must be a string, map, or list, got: #{inspect(value)}"}
  end

  # A description reaches the API as JSON, so validation has to agree with the
  # encoder: everything `JSON` can encode is allowed, everything else is a
  # `:validation` error here rather than a `Protocol.UndefinedError` at request
  # time.
  defp encodable(value) when is_binary(value) or is_number(value) or is_atom(value), do: :ok

  defp encodable(%struct{}) do
    {:error, "must be JSON-encodable, got a #{inspect(struct)} struct"}
  end

  defp encodable(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, inner}, :ok ->
      continue(with :ok <- encodable_key(key), do: encodable(inner))
    end)
  end

  defp encodable(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn inner, :ok -> continue(encodable(inner)) end)
  end

  defp encodable(value) when is_tuple(value) do
    {:error,
     "must be JSON-encodable, got a tuple: #{inspect(value)} " <>
       "(a keyword list is a list of tuples; use a map for structured descriptions)"}
  end

  defp encodable(value), do: {:error, "must be JSON-encodable, got: #{inspect(value)}"}

  defp encodable_key(key) when is_binary(key) or (is_atom(key) and not is_nil(key)), do: :ok

  defp encodable_key(key) do
    {:error,
     "must be JSON-encodable, but has a map key that is not a string or atom: #{inspect(key)}"}
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, _reason} = error), do: {:halt, error}

  @doc false
  @spec put_instructions(map(), instructions()) :: map()
  def put_instructions(wire, nil), do: wire
  def put_instructions(wire, instructions), do: Map.put(wire, "instructions", instructions)
end
