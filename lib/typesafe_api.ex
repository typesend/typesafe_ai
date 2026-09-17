defmodule TypeSafeAPI do
  @moduledoc """
  Unofficial Elixir client for the TypeSafe AI API.
  Not affiliated with or endorsed by TypeSafe AI.

  TypeSafe's System One API answers typed questions about a piece of state:
  a yes/no probability for a question or a statement (`noul/2`), one option
  from a set (`choice/2`), or a position on an ordered scale (`score/2`).
  This module is the whole public
  surface for everyday use; the modules it delegates to hold the details.

      client = TypeSafeAPI.new(api_key: "...")

      {:ok, result} =
        TypeSafeAPI.evaluate(client, "Help! My payouts have been failing for 3 days.",
          urgent: TypeSafeAPI.noul("Does this convey urgency?"),
          dept:
            TypeSafeAPI.choice("Which team should handle this?",
              billing: "Payments, invoicing, refunds",
              technical: "Bugs, outages, integrations",
              sales: nil
            ),
          anger: TypeSafeAPI.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
        )

      result.answers.dept.choice   #=> :technical
      result.answers.anger.label   #=> "Very angry"
      result.usage.input_tokens    #=> 312

  The same example, run against `TypeSafeAPI.Test` stubs instead of the network
  (this block is a doctest):

      iex> client =
      ...>   TypeSafeAPI.Test.client()
      ...>   |> TypeSafeAPI.Test.stub(
      ...>     urgent: {:noul, 0.92},
      ...>     dept: {:choice, :technical, 0.82},
      ...>     anger: {:score, 2, 0.65}
      ...>   )
      iex> {:ok, result} =
      ...>   TypeSafeAPI.evaluate(client, "Help! My payouts have been failing for 3 days.",
      ...>     urgent:
      ...>       TypeSafeAPI.noul("Does this convey urgency?",
      ...>         true: "Explicitly time-sensitive",
      ...>         false: "No urgency expressed"
      ...>       ),
      ...>     dept:
      ...>       TypeSafeAPI.choice("Which team should handle this?",
      ...>         billing: "Payments, invoicing, refunds",
      ...>         technical: "Bugs, outages, integrations",
      ...>         sales: nil
      ...>       ),
      ...>     anger: TypeSafeAPI.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
      ...>   )
      iex> result.model
      "jev-latest"
      iex> {result.answers.urgent.noul, result.answers.urgent.confidence}
      {0.92, 0.92}
      iex> {result.answers.dept.choice, result.answers.dept.confidence}
      {:technical, 0.82}
      iex> Map.keys(result.answers.dept.probabilities) |> Enum.sort()
      [:billing, :sales, :technical]
      iex> {result.answers.anger.level, result.answers.anger.label}
      {2, "Very angry"}
      iex> Enum.map(result.answers.anger.levels, &elem(&1, 0))
      ["Calm", "Frustrated", "Very angry"]
      iex> TypeSafeAPI.Answer.gate(result.answers.dept, act: 0.8, review: 0.5)
      :act
      iex> TypeSafeAPI.Answer.gate(result.answers.anger, act: 0.8, review: 0.5)
      :review
      iex> TypeSafeAPI.Answer.yes?(result.answers.urgent)
      true

  Question ids and Choice option keys come back exactly as you gave them:
  atoms stay atoms, strings stay strings. See `TypeSafeAPI.Keys` for why.

  Questions are validated locally on every call, so a malformed one fails with
  a `:validation` error before anything is sent. To catch the mistake at the
  line that wrote it instead, wrap the constructor in
  `TypeSafeAPI.Question.validate!/1`, which raises `ArgumentError` and returns the
  question unchanged. That is the eager-validation path for questions built
  once in a module attribute or at application start.

  ## Two layers

  `TypeSafeAPI.HTTP` is the raw layer: maps in, maps out, with auth, retries and
  telemetry handled. Everything above it (questions, answers, results) is the
  typed layer. If the API adds something this library does not model yet, the
  raw layer still works.
  """

  alias TypeSafeAPI.Question.{Choice, Noul, Score}

  @doc """
  Builds a `TypeSafeAPI.Client`.

  With no options, configuration comes from application config and the
  `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, and `TYPESAFE_DEFAULT_MODEL`
  environment variables. See `TypeSafeAPI.Client.new/1` for all options.
  """
  @spec new(keyword()) :: TypeSafeAPI.Client.t()
  defdelegate new(opts \\ []), to: TypeSafeAPI.Client

  @doc """
  A yes/no judgment on a question ("Does this convey urgency?") or a statement
  ("This message contains unsolicited advertising."). `instructions` is
  optional, as are the `true:` and `false:` descriptions that say what each
  answer means. Criteria alone are enough: `noul(true: "spam", false: "legit")`
  reads the keyword list as criteria, not as instructions.
  See `TypeSafeAPI.Question.Noul`.
  """
  @spec noul(TypeSafeAPI.Question.instructions() | keyword(), keyword() | map() | nil) :: Noul.t()
  defdelegate noul(instructions \\ nil, criteria \\ nil), to: Noul, as: :new

  @doc """
  Pick one option from `criteria`, a keyword list (or list of pairs) of option
  key to description; `nil` when the key speaks for itself. A bare list of
  option names works too, and means the same as pairing each with `nil`. Order
  is preserved. `instructions` is optional and may be `nil`.
  See `TypeSafeAPI.Question.Choice`.
  """
  @spec choice(TypeSafeAPI.Question.instructions(), [Choice.option() | TypeSafeAPI.Keys.key()]) ::
          Choice.t()
  defdelegate choice(instructions, criteria), to: Choice, as: :new

  @doc """
  Rate the state along `levels`, an ordered list of two to ten level
  descriptions from low to high. `instructions` is optional and may be `nil`.
  See `TypeSafeAPI.Question.Score`.
  """
  @spec score(TypeSafeAPI.Question.instructions(), [Score.level()]) :: Score.t()
  defdelegate score(instructions, levels), to: Score, as: :new

  @doc """
  Validates and encodes a question set once, for reuse across many calls.

  Returns a `TypeSafeAPI.SystemOne.Prepared`, which holds the normalized
  questions, their wire bytes and the key registry that maps answers back to
  the ids you used. Preparing at boot (in a module attribute, or in a
  `GenServer`'s state) turns a malformed question set into a startup failure
  instead of a per-request one, and keeps the encoding cost out of the request
  path:

      {:ok, prepared} = TypeSafeAPI.prepare(urgent: TypeSafeAPI.noul("Urgent?"))
      TypeSafeAPI.SystemOne.evaluate_prepared(client, "the ticket text", prepared)

  Treat the result as opaque: it is four fields that must agree with each
  other, and nothing revalidates them if you rewrite one.
  """
  @spec prepare(TypeSafeAPI.Question.input()) ::
          {:ok, TypeSafeAPI.SystemOne.Prepared.t()} | {:error, TypeSafeAPI.Error.t()}
  defdelegate prepare(questions), to: TypeSafeAPI.SystemOne

  @doc """
  Evaluates `state` against `questions` and returns a `TypeSafeAPI.Result`.

  `state` is a string or JSON-shaped map or list — a struct, tuple, keyword
  list or charlist is a `:validation` error, since none of them has the JSON
  representation the API is being sent. `questions` is a keyword list (or list
  of `{id, question}` pairs); question order is preserved, so a map is not
  accepted. A `TypeSafeAPI.SystemOne.Prepared` from `prepare/1` is also
  accepted, and is used as-is rather than validated and encoded again.

  Nothing on this path raises. A malformed question, a state that cannot be
  encoded, and an option not in the list below all return
  `{:error, %TypeSafeAPI.Error{type: :validation}}` with no request sent. A
  response this library cannot decode against the questions it asked — an
  answer missing, a probability that is not a number, an option or level the
  question never declared — is `{:error, %TypeSafeAPI.Error{type: :unexpected}}`
  carrying the response's `request_id` and the body.

  ## Options

  #{NimbleOptions.docs(TypeSafeAPI.SystemOne.options_schema())}
  """
  @spec evaluate(
          TypeSafeAPI.Client.t(),
          TypeSafeAPI.SystemOne.state(),
          TypeSafeAPI.Question.input() | TypeSafeAPI.SystemOne.Prepared.t(),
          keyword()
        ) ::
          {:ok, TypeSafeAPI.Result.t()} | {:error, TypeSafeAPI.Error.t()}
  defdelegate evaluate(client, state, questions, opts \\ []), to: TypeSafeAPI.SystemOne

  @doc """
  Like `evaluate/4` but returns the result or raises the `TypeSafeAPI.Error`.

  This is the only one of the two that raises, and it raises for every failure
  alike: a validation mistake caught locally, an HTTP error, and a response
  that would not decode all arrive as the same `TypeSafeAPI.Error` exception.
  """
  @spec evaluate!(
          TypeSafeAPI.Client.t(),
          TypeSafeAPI.SystemOne.state(),
          TypeSafeAPI.Question.input(),
          keyword()
        ) ::
          TypeSafeAPI.Result.t()
  def evaluate!(client, state, questions, opts \\ []) do
    case evaluate(client, state, questions, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Evaluates many states against one question set, concurrently, and returns
  one outcome per state in input order. See `TypeSafeAPI.FanOut` for how errors,
  timeouts and exhausted retries surface.

  `questions` may also be a `%TypeSafeAPI.SystemOne.Prepared{}` from
  `TypeSafeAPI.SystemOne.prepare/1`, already validated and encoded.

  An invalid question set fails before anything is sent, so it comes back as a
  bare `{:error, error}` rather than a list of outcomes; `on_error: :raise`
  raises it instead.

  ## Options

  #{NimbleOptions.docs(TypeSafeAPI.FanOut.options_schema())}

  Every other option is passed through to each individual call, so `:model`,
  `:timeout`, `:retry`, `:req_options` and `:telemetry` mean exactly what they
  mean in `evaluate/4`. `:timeout` is still one HTTP attempt; the cap on a
  whole state, retries included, is `:task_timeout` above.
  """
  @spec evaluate_many(
          TypeSafeAPI.Client.t(),
          Enumerable.t(),
          TypeSafeAPI.Question.input() | TypeSafeAPI.SystemOne.Prepared.t(),
          keyword()
        ) ::
          [TypeSafeAPI.FanOut.outcome()] | {:error, TypeSafeAPI.Error.t()}
  defdelegate evaluate_many(client, states, questions, opts \\ []), to: TypeSafeAPI.FanOut

  @doc """
  Lists the models available to the account.

  An entry this library cannot decode is logged and skipped rather than failing
  the list. See `TypeSafeAPI.Models.list/2` for the per-call options.
  """
  @spec models(TypeSafeAPI.Client.t(), keyword()) ::
          {:ok, [TypeSafeAPI.Model.t()]} | {:error, TypeSafeAPI.Error.t()}
  defdelegate models(client, opts \\ []), to: TypeSafeAPI.Models, as: :list

  @doc "Like `models/2` but returns the list or raises the `TypeSafeAPI.Error`."
  @spec models!(TypeSafeAPI.Client.t(), keyword()) :: [TypeSafeAPI.Model.t()]
  def models!(client, opts \\ []) do
    case models(client, opts) do
      {:ok, models} -> models
      {:error, error} -> raise error
    end
  end
end
