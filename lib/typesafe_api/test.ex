defmodule TypeSafeAPI.Test do
  @moduledoc """
  Stub the TypeSafe API in your tests without fixtures or a network.

  Add `plug` to your test dependencies (`{:plug, "~> 1.16", only: :test}`),
  then build a test client and describe the answers you want by question id:

      # test/test_helper.exs
      ExUnit.start()

      # in a test
      setup :typesafe_stubs

      test "routes billing tickets" do
        client = TypeSafeAPI.Test.client()

        TypeSafeAPI.Test.stub(client,
          dept: {:choice, :billing, 0.9},
          urgent: {:noul, 0.3},
          anger: {:score, 1, 0.8}
        )

        assert {:ok, result} = MyApp.Triage.run(client, "Where is my refund?")
        assert result.answers.dept.choice == :billing
      end

  The stub reads the questions in each request and builds a response the way
  the API would, so the decoded structs are identical to those from a real
  call: probabilities are spread over exactly the options or levels you sent,
  they sum to one, the winning option or level is the argmax, Score answers
  carry `level`, `label` and a `legend` echoing your own labels, and keys come
  back as atoms or strings exactly as you sent them.

  ## Answer specs

    * `{:noul, probability}` - `probability` is in `0.0..1.0`
    * `{:choice, option, confidence}` - `option` is one of the question's keys;
      the remaining probability is spread evenly across the other options
    * `{:score, level, confidence}` - `level` is a 0-based index; the remaining
      probability is spread evenly across the other levels

  `confidence` has to beat the uniform baseline, which is `1 / n` for a
  question with `n` options or levels. Below it the option you named would not
  be the argmax and the answer would contradict itself, so the stub rejects it
  with a message naming the minimum for that question. A shape that is wrong
  whatever the question (a confidence above `1.0`, a negative level) is
  rejected by `stub/2` itself, before any request is made.

  A request that asks a question you did not stub is answered with HTTP 422 and
  a message naming the question, so `TypeSafeAPI.evaluate/4` returns
  `{:error, %TypeSafeAPI.Error{type: :validation}}` and a test cannot silently
  pass on a default answer. It is an error response rather than a raise so that
  a missing stub under `TypeSafeAPI.evaluate_many/4` surfaces as one error per
  state instead of an exception inside a task that takes the test process with
  it.

  ## Composing stubs

  Every helper adds to the same stub, so a client can serve several endpoints
  at once and a later call refines an earlier one:

      client =
        TypeSafeAPI.Test.client()
        |> TypeSafeAPI.Test.stub_models([%{name: "jev-1.13.0"}])
        |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.3})
        |> TypeSafeAPI.Test.stub(dept: {:choice, :billing, 0.9})

  Requests are dispatched on method and path: `GET /v1/models` is served by
  `stub_models/2` and `POST /v1/systemone` by `stub/2`. Anything else gets a
  422 naming the route.

  ## Errors

  `stub_error/4` queues an error response. By default it answers every request
  from then on; `times:` limits it to the next call or calls, which is how you
  test a retry or a recovery path:

      client
      |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.3})
      |> TypeSafeAPI.Test.stub_error(429, %{"error" => "slow down"},
        headers: [{"retry-after", "1"}],
        times: 1
      )

  The first call gets the 429; the retry gets the stubbed answers.

  ## Recording fixtures

  When the answers you want are the ones the real model gives, record them once
  and replay them forever after. `record/2` wraps a client so every response is
  appended to a fixture file; `replay/2` turns that file back into a client:

      # once, against the real API
      TypeSafeAPI.new()
      |> TypeSafeAPI.Test.record("test/fixtures/triage.jsonl")
      |> MyApp.Triage.run("Where is my refund?")

      # in every test run afterwards, with no network
      test "routes billing tickets" do
        client = TypeSafeAPI.Test.replay("test/fixtures/triage.jsonl")

        assert {:ok, result} = MyApp.Triage.run(client, "Where is my refund?")
        assert result.answers.dept.choice == :billing
      end

  The replayed `TypeSafeAPI.Result` is the one the API sent, decoded by the same
  code, so it is identical to the recorded run. Requests are matched by method,
  path and body, and the same request twice gets the two recordings in order;
  pass `match: [:method, :path]` to ignore the body. A request that matches
  nothing raises with the request, the closest unserved recording and the first
  field they differ on.

  ### Fixture format

  A fixture is [JSON Lines](https://jsonlines.org): one JSON object per line,
  in the order the responses arrived, so appending one entry is one write and a
  recorded diff reads one response per line. Each line is

      {"request":{"method":...,"path":...,"body":...},
       "response":{"status":...,"headers":...,"body":...}}

  Only the request method, path and JSON body are written, never request
  headers, so an API key cannot reach a fixture that you commit. Of the
  response headers only `content-type` and `x-typesafe-request-id` are kept.
  The format is what `record/2` writes and `replay/2` reads; treat a fixture as
  generated output and re-record it rather than editing it by hand. A fixture
  written as a whole-file JSON array by an earlier version still loads.

  Every response with an HTTP status is recorded, including 4xx and 5xx, so a
  test can replay the error path too. A transport failure never reached the
  server and is not recorded. A run that was retried records each attempt, so
  replaying it reproduces that same sequence: give the replay client a retry
  policy (`replay(path, retry: [max_retries: 2])`) when you want the retry to
  be replayed rather than surfaced.

  ### Ordering

  Entries are appended as responses arrive. Under `TypeSafeAPI.evaluate_many/4`
  that order is the order the concurrent calls finished in, not the order of
  the input states, and it differs from run to run. Body matching (the default)
  is unaffected, because each request finds its own recording wherever it sits.
  `match: [:method, :path]` pairs requests to recordings by position instead, so
  use it only for fixtures recorded by sequential calls.

  Unlike a missing stub, a request that matches no recording raises rather than
  answering 422, because the message is the whole value of a fixture mismatch.
  Under `TypeSafeAPI.evaluate_many/4` that raise happens inside a task, so
  replay a fan-out only from a fixture that holds a recording for every state.

  ## Concurrency

  Stubs use `Req.Test`, which follows the ownership model of `Mox`: call
  `Req.Test.set_req_test_from_context/1` in `setup` (or the `typesafe_stubs/1`
  helper here) and stubs are private to each async test. The stubs a client
  accumulates are tracked per process, so build them from the test process;
  the tasks `TypeSafeAPI.evaluate_many/4` starts reach them through `$callers`
  the same way `Req.Test` ownership does.
  """

  # `plug` is optional; the Plug.Conn calls below are only reached from Req.Test stubs.
  @compile {:no_warn_undefined, Plug.Conn}

  alias TypeSafeAPI.{Client, Keys}
  alias TypeSafeAPI.Test.Recorder

  @default_name TypeSafeAPI.Test

  @typedoc "How to answer one question."
  @type answer_spec ::
          {:noul, number()}
          | {:choice, atom() | String.t(), number()}
          | {:score, non_neg_integer(), number()}

  @typedoc "Options for `stub_error/4`."
  @type error_option ::
          {:headers, [{String.t(), String.t()}]}
          | {:times, pos_integer() | :infinity}
          | {:path, String.t()}

  @doc """
  Builds a client whose requests are served by this module's stubs.

  Options are passed to `TypeSafeAPI.new/1`; `api_key` defaults to `"test-key"`
  and retries are disabled unless you set `:retry`. Pass `:name` to use a
  custom `Req.Test` stub name.
  """
  @spec client(keyword()) :: Client.t()
  def client(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @default_name)

    [api_key: "test-key", retry: [max_retries: 0]]
    |> Keyword.merge(opts)
    |> Keyword.update(
      :req_options,
      [plug: {Req.Test, name}],
      &Keyword.put(&1, :plug, {Req.Test, name})
    )
    |> TypeSafeAPI.new()
  end

  @doc """
  An ExUnit setup callback: `setup :typesafe_stubs`.

  Makes stubs private to async tests and shared otherwise.
  """
  @spec typesafe_stubs(map()) :: :ok
  def typesafe_stubs(context) do
    Req.Test.set_req_test_from_context(context)
    :ok
  end

  @doc """
  Stubs the evaluation endpoint with one answer per question id.

  Ids given here are merged into whatever this client already answers, so
  several calls compose and the last spec for an id wins. Returns the client so
  the call can be piped.

  Raises `ArgumentError` for a spec that cannot be right for any question: a
  probability or confidence outside `0.0..1.0`, a negative level, or a shape
  that is not one of the three in `t:answer_spec/0`. A spec that only the
  question can judge - an option the question does not have, a level past its
  last one, a confidence under that question's uniform baseline - comes back
  as an HTTP 422 when the request is made.
  """
  @spec stub(Client.t(), keyword() | %{optional(atom() | String.t()) => answer_spec()}) ::
          Client.t()
  def stub(%Client{} = client, answers) when is_list(answers) or is_map(answers) do
    specs = Map.new(answers, fn {id, spec} -> {to_string(id), validate_spec!(id, spec)} end)

    update_config(client, fn config ->
      %{config | answers: Map.merge(config.answers || %{}, specs)}
    end)
  end

  @doc """
  Queues an HTTP error response.

  It takes priority over the other stubs on this client, so a client can hold
  both an error and the answers that follow it.

  ## Options

    * `:headers` - response headers, as `{name, value}` pairs. Defaults to none
    * `:times` - how many requests this error answers, a positive integer or
      `:infinity`. Defaults to `:infinity`, which is every request from now on
    * `:path` - only answer requests whose path ends with this string.
      Defaults to answering every path

  ## Examples

      TypeSafeAPI.Test.stub_error(client, 429, %{"error" => "slow down"},
        headers: [{"retry-after", "1"}],
        times: 1
      )
  """
  @spec stub_error(Client.t(), pos_integer(), term(), [error_option()]) :: Client.t()
  def stub_error(%Client{} = client, status, body \\ %{}, opts \\ [])
      when is_integer(status) and status > 0 do
    opts = validate_error_opts!(opts)

    error = %{
      status: status,
      body: body,
      headers: Keyword.get(opts, :headers, []),
      times: Keyword.get(opts, :times, :infinity),
      path: Keyword.get(opts, :path)
    }

    update_config(client, fn config ->
      %{config | errors: push_error(config.errors, error)}
    end)
  end

  @doc """
  Sends a JSON response from inside a custom `Req.Test` stub, for cases the
  built-in stubs do not cover:

      Req.Test.stub(TypeSafeAPI.Test, fn conn ->
        TypeSafeAPI.Test.json(conn, 200, %{"models" => []})
      end)
  """
  @spec json(Plug.Conn.t(), pos_integer(), term(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  def json(conn, status, body, headers \\ []) when is_map(conn) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  @doc """
  Stubs the models endpoint. Each entry needs a `:name`; `:description` and
  `:release_date` are optional.

  Replaces whatever list this client served before, and leaves its other stubs
  alone.
  """
  @spec stub_models(Client.t(), [map()]) :: Client.t()
  def stub_models(%Client{} = client, models) when is_list(models) do
    wire =
      Enum.map(models, fn model ->
        %{
          "name" => Keys.get(model, :name),
          "description" => Keys.get(model, :description) || "",
          "release_date" => model |> Keys.get(:release_date) |> to_wire_date()
        }
      end)

    update_config(client, fn config -> %{config | models: wire} end)
  end

  @doc """
  Wraps `client` so every response is appended to the fixture at `path`, and
  returns it.

  Run it once against the real API (or any stub), then hand the file to
  `replay/2` and your tests run offline. Each entry holds the request method,
  path and decoded JSON body, and the response status, decoded JSON body and
  the `content-type` and `x-typesafe-request-id` headers. Request headers are
  never written, so the `Authorization` header and your API key stay out of the
  fixture. See the "Fixture format" section above for the file layout and what
  is and is not recorded.
  """
  @spec record(Client.t(), Path.t()) :: Client.t()
  def record(%Client{} = client, path) when is_binary(path) do
    req_options =
      case Keyword.fetch(client.req_options, :plug) do
        {:ok, plug} ->
          Keyword.put(client.req_options, :plug, {Recorder, {plug, path}})

        :error ->
          client.req_options
          |> put_header(Recorder.path_header(), path)
          |> put_adapter()
      end

    %{client | req_options: req_options}
  end

  @doc """
  Builds a client that answers from the recordings in `path`.

  Requests are matched against the fixture by method, path and body; repeated
  matches are served in the order they were recorded. A request that matches no
  remaining recording raises `ArgumentError` naming the request, the closest
  unserved recording and the first field they differ on.

  ## Options

    * `:match` - which parts of a request must be equal, any of `:method`,
      `:path` and `:body`. Defaults to all three; `match: [:method, :path]`
      ignores the body, which is what you want when the state text varies.
      It pairs requests to recordings by position, so use it only on a fixture
      recorded by sequential calls
    * `:name` - a custom `Req.Test` stub name; one is generated per call
    * anything else is passed to `client/1`, including `:retry`, which is what
      you want when the fixture holds a retried sequence
  """
  @spec replay(Path.t(), keyword()) :: Client.t()
  def replay(path, opts \\ []) when is_binary(path) do
    {match, opts} = Keyword.pop(opts, :match, Recorder.match_keys())
    {name, opts} = Keyword.pop(opts, :name, {__MODULE__.Replay, make_ref()})

    validate_match!(match)
    entries = Recorder.load!(path)
    {:ok, agent} = Agent.start_link(fn -> entries end)

    Req.Test.stub(name, &Recorder.replay_plug(&1, agent, match, path))
    client([name: name] ++ opts)
  end

  defp validate_match!(match) do
    known = Recorder.match_keys()

    if not (is_list(match) and match != [] and Enum.all?(match, &(&1 in known))) do
      raise ArgumentError,
            "TypeSafeAPI.Test.replay/2: :match must be a non-empty subset of " <>
              "#{inspect(known)}, got: #{inspect(match)}"
    end
  end

  defp put_header(req_options, name, value) do
    case Keyword.fetch(req_options, :headers) do
      {:ok, headers} when is_map(headers) ->
        Keyword.put(req_options, :headers, Map.put(headers, name, value))

      {:ok, headers} when is_list(headers) ->
        Keyword.put(req_options, :headers, headers ++ [{name, value}])

      :error ->
        Keyword.put(req_options, :headers, [{name, value}])
    end
  end

  defp put_adapter(req_options) do
    case Keyword.fetch(req_options, :adapter) do
      {:ok, Recorder} ->
        req_options

      {:ok, adapter} when is_atom(adapter) ->
        req_options
        |> put_header(Recorder.adapter_header(), Atom.to_string(adapter))
        |> Keyword.put(:adapter, Recorder)

      {:ok, other} ->
        raise ArgumentError,
              "TypeSafeAPI.Test.record/2 can only wrap an adapter module, got: " <>
                "#{inspect(other)}. Give the client a `plug:` instead, or a module adapter."

      :error ->
        Keyword.put(req_options, :adapter, Recorder)
    end
  end

  # -- stub configuration ------------------------------------------------------

  # The helpers run in the test process and accumulate there; each one
  # re-registers a plug closing over the whole configuration, so the tasks that
  # actually make the requests see it without sharing the process dictionary.
  defp update_config(%Client{} = client, fun) do
    name = stub_name!(client)
    key = {__MODULE__, name}
    config = fun.(Process.get(key, %{answers: nil, models: nil, errors: nil}))

    Process.put(key, config)
    Req.Test.stub(name, &dispatch(&1, config))

    client
  end

  defp push_error(agent, error) do
    agent = agent || start_errors()
    Agent.update(agent, &(&1 ++ [error]))
    agent
  end

  defp start_errors do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    agent
  end

  defp validate_error_opts!(opts) do
    if Keyword.keyword?(opts) do
      Keyword.validate!(opts, [:headers, :times, :path])
    else
      raise ArgumentError,
            "TypeSafeAPI.Test.stub_error/4 takes options, not headers; " <>
              "write headers: #{inspect(opts)}"
    end
  end

  defp validate_spec!(id, {:noul, probability}) when is_number(probability) do
    in_unit_interval!(id, "probability", probability)
    {:noul, probability}
  end

  defp validate_spec!(id, {:choice, option, confidence})
       when (is_atom(option) or is_binary(option)) and is_number(confidence) do
    in_unit_interval!(id, "confidence", confidence)
    {:choice, option, confidence}
  end

  defp validate_spec!(id, {:score, level, confidence})
       when is_integer(level) and level >= 0 and is_number(confidence) do
    in_unit_interval!(id, "confidence", confidence)
    {:score, level, confidence}
  end

  defp validate_spec!(id, spec) do
    raise ArgumentError,
          "TypeSafeAPI.Test: #{inspect(spec)} is not an answer spec for question " <>
            "#{inspect(id)}. Expected {:noul, probability}, {:choice, option, confidence} " <>
            "or {:score, level, confidence}, with a 0-based integer level."
  end

  defp in_unit_interval!(_id, _name, value) when value >= 0 and value <= 1, do: :ok

  defp in_unit_interval!(id, name, value) do
    raise ArgumentError,
          "TypeSafeAPI.Test: #{name} for question #{inspect(id)} must be between 0.0 and 1.0, " <>
            "got #{inspect(value)}"
  end

  # -- dispatch ----------------------------------------------------------------

  defp dispatch(conn, config) do
    case take_error(config.errors, conn) do
      {:ok, error} -> json(conn, error.status, error.body, error.headers)
      :error -> route(conn, config)
    end
  end

  defp take_error(nil, _conn), do: :error

  defp take_error(agent, conn) do
    Agent.get_and_update(agent, fn errors ->
      case Enum.split_while(errors, &(not error_matches?(&1, conn))) do
        {_before, []} -> {:error, errors}
        {before, [error | rest]} -> {{:ok, error}, before ++ consume(error) ++ rest}
      end
    end)
  end

  defp error_matches?(%{path: nil}, _conn), do: true
  defp error_matches?(%{path: path}, conn), do: String.ends_with?(conn.request_path, path)

  defp consume(%{times: :infinity} = error), do: [error]
  defp consume(%{times: 1}), do: []
  defp consume(%{times: times} = error), do: [%{error | times: times - 1}]

  defp route(conn, config) do
    case {conn.method, endpoint(conn.request_path)} do
      {"POST", :systemone} -> evaluate_stub(conn, config.answers)
      {"GET", :models} -> models_stub(conn, config.models)
      _other -> problem(conn, "no stub for #{conn.method} #{conn.request_path}")
    end
  end

  defp endpoint(path) do
    cond do
      String.ends_with?(path, "/systemone") -> :systemone
      String.ends_with?(path, "/models") -> :models
      true -> :unknown
    end
  end

  defp models_stub(conn, nil) do
    problem(conn, "no models stubbed; call TypeSafeAPI.Test.stub_models/2 on this client")
  end

  defp models_stub(conn, wire), do: json(conn, 200, %{"models" => wire})

  # -- answer construction -----------------------------------------------------

  defp evaluate_stub(conn, specs) do
    case read_json(conn) do
      {%{"questions" => questions, "model" => model}, conn} when is_map(questions) ->
        evaluate_questions(conn, questions, model, specs || %{})

      {_other, conn} ->
        problem(conn, "request body is not a systemone request")
    end
  end

  defp evaluate_questions(conn, questions, model, specs) do
    case build_answers(questions, specs) do
      {:ok, answers} ->
        json(conn, 200, %{
          "model" => model,
          "answers" => answers,
          "usage" => %{
            "input_tokens" => usage_estimate(questions),
            "output_tokens" => map_size(answers) * 8
          }
        })

      {:error, message} ->
        problem(conn, message)
    end
  end

  defp build_answers(questions, specs) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, question}, {:ok, acc} ->
      case answer(id, question, specs) do
        {:ok, answer} -> {:cont, {:ok, Map.put(acc, id, answer)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp answer(id, %{"type" => "noul"}, specs) do
    case Map.fetch(specs, id) do
      {:ok, {:noul, probability}} -> {:ok, %{"type" => "noul", "noul" => probability / 1}}
      other -> mismatch(id, "noul", other)
    end
  end

  defp answer(id, %{"type" => "choice", "criteria" => criteria}, specs) when is_map(criteria) do
    case Map.fetch(specs, id) do
      {:ok, {:choice, option, confidence}} ->
        choice_answer(id, Map.keys(criteria), to_string(option), confidence)

      other ->
        mismatch(id, "choice", other)
    end
  end

  defp answer(id, %{"type" => "score", "criteria" => levels}, specs) when is_list(levels) do
    case Map.fetch(specs, id) do
      {:ok, {:score, level, confidence}} -> score_answer(id, levels, level, confidence)
      other -> mismatch(id, "score", other)
    end
  end

  defp answer(id, question, _specs) do
    {:error, "question #{inspect(id)} has an unknown shape: #{inspect(question)}"}
  end

  defp choice_answer(id, options, chosen, confidence) do
    with :ok <- known_option(id, options, chosen),
         :ok <- beats_baseline(id, length(options), "option", confidence) do
      {probabilities, confidence} = spread(options, chosen, confidence)

      {:ok,
       %{
         "type" => "choice",
         "choice" => chosen,
         "probabilities" => probabilities,
         "confidence" => confidence
       }}
    end
  end

  defp known_option(id, options, chosen) do
    if chosen in options do
      :ok
    else
      {:error,
       "question #{inspect(id)} has no option #{inspect(chosen)}; " <>
         "options are #{inspect(options)}"}
    end
  end

  defp score_answer(id, levels, level, confidence) do
    count = length(levels)

    with :ok <- known_level(id, count, level),
         :ok <- beats_baseline(id, count, "level", confidence) do
      keys = Enum.map(0..(count - 1), &Integer.to_string/1)
      {probabilities, confidence} = spread(keys, Integer.to_string(level), confidence)

      {:ok,
       %{
         "type" => "score",
         "score" => weighted_score(probabilities),
         "legend" => Map.new(Enum.zip(keys, levels)),
         "probabilities" => probabilities,
         "confidence" => confidence
       }}
    end
  end

  defp known_level(_id, count, level) when level >= 0 and level < count, do: :ok

  defp known_level(id, count, level) do
    {:error, "question #{inspect(id)} has #{count} levels; got level #{level}"}
  end

  defp weighted_score(probabilities) do
    Enum.reduce(probabilities, 0.0, fn {key, probability}, acc ->
      acc + String.to_integer(key) * probability
    end)
  end

  # Below the uniform baseline the named option is no longer the argmax, so the
  # response would say one thing and decode to another.
  defp beats_baseline(_id, count, _noun, _confidence) when count <= 1, do: :ok

  defp beats_baseline(id, count, noun, confidence) do
    baseline = 1 / count

    if confidence > baseline do
      :ok
    else
      {:error,
       "confidence #{inspect(confidence)} for question #{inspect(id)} is at or below the " <>
         "uniform baseline for a #{count}-#{noun} question: it must be greater than " <>
         "#{Float.round(baseline, 4)}, or the stubbed answer would not be the one with the " <>
         "highest probability"}
    end
  end

  defp mismatch(id, type, :error) do
    {:error, "no stub for question #{inspect(id)} (a #{type} question)"}
  end

  defp mismatch(id, type, {:ok, spec}) do
    {:error, "stub #{inspect(spec)} does not fit question #{inspect(id)}, a #{type} question"}
  end

  # Gives `chosen` the confidence and spreads the remainder evenly over the
  # rest. A one-option question has no remainder, and its only answer is
  # certain whatever the caller asked for.
  defp spread([_only] = keys, chosen, _confidence) when is_list(keys), do: {%{chosen => 1.0}, 1.0}

  defp spread(keys, chosen, confidence) do
    rest = length(keys) - 1
    each = (1 - confidence) / rest

    probabilities =
      Map.new(keys, fn key -> {key, if(key == chosen, do: confidence / 1, else: each)} end)

    {probabilities, confidence / 1}
  end

  defp usage_estimate(questions) do
    questions |> JSON.encode!() |> byte_size() |> div(4)
  end

  # -- plug helpers ------------------------------------------------------------

  defp problem(conn, message), do: json(conn, 422, %{"detail" => "TypeSafeAPI.Test: #{message}"})

  defp stub_name!(%Client{req_options: req_options}) do
    case Keyword.get(req_options, :plug) do
      {Req.Test, name} ->
        name

      {Recorder, {{Req.Test, name}, _path}} ->
        name

      _other ->
        raise ArgumentError,
              "TypeSafeAPI.Test stubs need a client built with TypeSafeAPI.Test.client/1 " <>
                "(or req_options: [plug: {Req.Test, name}])"
    end
  end

  defp read_json(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case JSON.decode(body) do
      {:ok, decoded} -> {decoded, conn}
      {:error, _} -> {nil, conn}
    end
  end

  defp to_wire_date(%Date{} = date), do: Date.to_iso8601(date)
  defp to_wire_date(other), do: other
end
