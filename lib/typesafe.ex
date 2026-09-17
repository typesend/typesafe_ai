defmodule TypeSafe do
  @moduledoc """
  Unofficial Elixir client for the TypeSafe AI API.
  Not affiliated with or endorsed by TypeSafe AI.

  TypeSafe's System One API answers typed questions about a piece of state:
  a yes/no probability (`noul/2`), one option from a set (`choice/2`), or a
  position on an ordered scale (`score/2`). This module is the whole public
  surface for everyday use; the modules it delegates to hold the details.

      client = TypeSafe.new(api_key: "...")

      {:ok, result} =
        TypeSafe.evaluate(client, "Help! My payouts have been failing for 3 days.",
          urgent: TypeSafe.noul("Does this convey urgency?"),
          dept:
            TypeSafe.choice("Which team should handle this?",
              billing: "Payments, invoicing, refunds",
              technical: "Bugs, outages, integrations",
              sales: nil
            ),
          anger: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
        )

      result.answers.dept.choice   #=> :technical
      result.answers.anger.label   #=> "Very angry"
      result.usage.input_tokens    #=> 312

  The same example, run against `TypeSafe.Test` stubs instead of the network
  (this block is a doctest):

      iex> client =
      ...>   TypeSafe.Test.client()
      ...>   |> TypeSafe.Test.stub(
      ...>     urgent: {:noul, 0.92},
      ...>     dept: {:choice, :technical, 0.82},
      ...>     anger: {:score, 2, 0.65}
      ...>   )
      iex> {:ok, result} =
      ...>   TypeSafe.evaluate(client, "Help! My payouts have been failing for 3 days.",
      ...>     urgent:
      ...>       TypeSafe.noul("Does this convey urgency?",
      ...>         true: "Explicitly time-sensitive",
      ...>         false: "No urgency expressed"
      ...>       ),
      ...>     dept:
      ...>       TypeSafe.choice("Which team should handle this?",
      ...>         billing: "Payments, invoicing, refunds",
      ...>         technical: "Bugs, outages, integrations",
      ...>         sales: nil
      ...>       ),
      ...>     anger: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
      ...>   )
      iex> result.model
      "jev-latest"
      iex> result.answers.urgent
      %TypeSafe.Answer.Noul{id: :urgent, noul: 0.92}
      iex> {result.answers.dept.choice, result.answers.dept.confidence}
      {:technical, 0.82}
      iex> Map.keys(result.answers.dept.probabilities) |> Enum.sort()
      [:billing, :sales, :technical]
      iex> {result.answers.anger.level, result.answers.anger.label}
      {2, "Very angry"}
      iex> Enum.map(result.answers.anger.levels, &elem(&1, 0))
      ["Calm", "Frustrated", "Very angry"]
      iex> TypeSafe.Answer.gate(result.answers.dept, act: 0.8, review: 0.5)
      :act
      iex> TypeSafe.Answer.gate(result.answers.anger, act: 0.8, review: 0.5)
      :review
      iex> TypeSafe.Answer.yes?(result.answers.urgent)
      true

  Question ids and Choice option keys come back exactly as you gave them:
  atoms stay atoms, strings stay strings. See `TypeSafe.Keys` for why.

  Questions are validated locally on every call, so a malformed one fails with
  a `:validation` error before anything is sent. To catch the mistake at the
  line that wrote it instead, wrap the constructor in
  `TypeSafe.Question.validate!/1`, which raises `ArgumentError` and returns the
  question unchanged. That is the eager-validation path for questions built
  once in a module attribute or at application start.

  ## Two layers

  `TypeSafe.HTTP` is the raw layer: maps in, maps out, with auth, retries and
  telemetry handled. Everything above it (questions, answers, results) is the
  typed layer. If the API adds something this library does not model yet, the
  raw layer still works.
  """

  alias TypeSafe.Question.{Choice, Noul, Score}

  @doc """
  Builds a `TypeSafe.Client`.

  With no options, configuration comes from application config and the
  `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, and `TYPESAFE_DEFAULT_MODEL`
  environment variables. See `TypeSafe.Client.new/1` for all options.
  """
  @spec new(keyword()) :: TypeSafe.Client.t()
  defdelegate new(opts \\ []), to: TypeSafe.Client

  @doc """
  A yes/no question. Optional `true:` and `false:` descriptions say what each
  answer means. See `TypeSafe.Question.Noul`.
  """
  @spec noul(TypeSafe.Question.description(), keyword()) :: Noul.t()
  defdelegate noul(instructions, criteria \\ []), to: Noul, as: :new

  @doc """
  Pick one option from `criteria`, a keyword list (or list of pairs) of option
  key to description; `nil` when the key speaks for itself. Order is
  preserved. See `TypeSafe.Question.Choice`.
  """
  @spec choice(TypeSafe.Question.description(), [Choice.option()] | map()) :: Choice.t()
  defdelegate choice(instructions, criteria), to: Choice, as: :new

  @doc """
  Rate the state along `levels`, an ordered list of two to ten level
  descriptions from low to high. See `TypeSafe.Question.Score`.
  """
  @spec score(TypeSafe.Question.description(), [Score.level()]) :: Score.t()
  defdelegate score(instructions, levels), to: Score, as: :new

  @doc """
  Evaluates `state` against `questions` and returns a `TypeSafe.Result`.

  `state` is a string or JSON-shaped map or list. `questions` is a keyword
  list or map of id to question.

  ## Options

  #{NimbleOptions.docs(TypeSafe.SystemOne.options_schema())}
  """
  @spec evaluate(
          TypeSafe.Client.t(),
          TypeSafe.SystemOne.state(),
          TypeSafe.Question.input(),
          keyword()
        ) ::
          {:ok, TypeSafe.Result.t()} | {:error, TypeSafe.Error.t()}
  defdelegate evaluate(client, state, questions, opts \\ []), to: TypeSafe.SystemOne

  @doc "Like `evaluate/4` but returns the result or raises the `TypeSafe.Error`."
  @spec evaluate!(
          TypeSafe.Client.t(),
          TypeSafe.SystemOne.state(),
          TypeSafe.Question.input(),
          keyword()
        ) ::
          TypeSafe.Result.t()
  def evaluate!(client, state, questions, opts \\ []) do
    case evaluate(client, state, questions, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Evaluates many states against one question set, concurrently, and returns
  one outcome per state in input order. See `TypeSafe.FanOut` for how errors,
  timeouts and exhausted retries surface.

  ## Options

  #{NimbleOptions.docs(TypeSafe.FanOut.options_schema())}

  Every other option is passed through to each individual call, so `:model`,
  `:retry`, `:req_options` and `:telemetry` mean the same here as in
  `evaluate/4`. The one exception is `:timeout`, which is the per-state task
  timeout above; use `:attempt_timeout` for the single HTTP attempt.
  """
  @spec evaluate_many(TypeSafe.Client.t(), Enumerable.t(), TypeSafe.Question.input(), keyword()) ::
          [TypeSafe.FanOut.outcome()] | {:error, TypeSafe.Error.t()}
  defdelegate evaluate_many(client, states, questions, opts \\ []), to: TypeSafe.FanOut

  @doc "Lists the models available to the account. See `TypeSafe.Models.list/2`."
  @spec models(TypeSafe.Client.t(), keyword()) ::
          {:ok, [TypeSafe.Model.t()]} | {:error, TypeSafe.Error.t()}
  defdelegate models(client, opts \\ []), to: TypeSafe.Models, as: :list
end
