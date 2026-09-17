defmodule TypeSafe.Question do
  @moduledoc """
  The three question types and the functions that validate and encode them.

  Constructors never validate; validation happens once, locally, when a
  question set is sent (`TypeSafe.evaluate/4`), so a Score with one level or a
  Choice with one option fails fast with a `:validation` error value instead
  of a round trip to the API. Only the three known types are accepted;
  anything else is a local `:validation` error too.

  Questions built at compile time (say, in a module attribute) can be checked
  eagerly with `validate!/1`, which raises `ArgumentError` so the mistake shows
  up at the line that made it.

  `questions` given to `TypeSafe.evaluate/4` may be a keyword list or a map of
  id to question. `normalize/1` turns either into an ordered `[{id, question}]`
  list, which is the shape the rest of the typed layer works with.
  """

  alias TypeSafe.{Error, Keys}
  alias TypeSafe.JSON.OrderedObject
  alias TypeSafe.Question.{Choice, Noul, Score}

  @typedoc "Anything the API accepts as a description: a string, map, or list."
  @type description :: String.t() | map() | list()

  @type t :: Noul.t() | Choice.t() | Score.t()

  @typedoc "Questions as the caller passes them."
  @type input :: [{Keys.key(), t()}] | %{Keys.key() => t()}

  @doc """
  Turns a keyword list or map of questions into an ordered `[{id, question}]`
  list, validating every id and question.
  """
  @spec normalize(input()) :: {:ok, [{Keys.key(), t()}]} | {:error, Error.t()}
  def normalize(questions) when is_list(questions) or is_map(questions) do
    questions
    |> Enum.to_list()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, message} -> {:halt, {:error, Error.validation(message)}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, Error.validation("at least one question is required")}
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  def normalize(other) do
    {:error, Error.validation("questions must be a keyword list or map, got: #{inspect(other)}")}
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
    {:error, "expected a TypeSafe.Question.Noul, Choice, or Score struct, got: #{inspect(other)}"}
  end

  @doc """
  Validates a question and raises `ArgumentError` if it is malformed.

  Returns the question unchanged, so it can wrap a constructor:

      @urgent TypeSafe.Question.validate!(TypeSafe.noul("Urgent?", true: "time-sensitive"))
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
  """
  @spec encode_all([{Keys.key(), t()}]) :: OrderedObject.t()
  def encode_all(questions) when is_list(questions) do
    questions
    |> Enum.map(fn {id, question} -> {Keys.wire(id), encode(question)} end)
    |> OrderedObject.new()
  end

  @doc false
  @spec validate_description(term(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_description(value, field, opts \\ [])

  def validate_description(nil, field, opts) do
    if opts[:allow_nil], do: :ok, else: {:error, "#{field} is required"}
  end

  def validate_description(value, _field, _opts)
      when is_binary(value) or is_map(value) or is_list(value),
      do: :ok

  def validate_description(value, field, _opts) do
    {:error, "#{field} must be a string, map, or list, got: #{inspect(value)}"}
  end
end
