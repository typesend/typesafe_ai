defmodule TypeSafe.Test do
  @moduledoc """
  Stub the TypeSafe API in your tests without fixtures or a network.

  Add `plug` to your test dependencies (`{:plug, "~> 1.16", only: :test}`),
  then build a test client and describe the answers you want by question id:

      # test/test_helper.exs
      ExUnit.start()

      # in a test
      setup :typesafe_stubs

      test "routes billing tickets" do
        client = TypeSafe.Test.client()

        TypeSafe.Test.stub(client,
          dept: {:choice, :billing, 0.9},
          urgent: {:noul, 0.3},
          anger: {:score, 1, 0.8}
        )

        assert {:ok, result} = MyApp.Triage.run(client, "Where is my refund?")
        assert result.answers.dept.choice == :billing
      end

  The stub reads the questions in each request and builds a response the way
  the API would, so the decoded structs are identical to those from a real
  call: probabilities sum to one, Score answers carry `level`, `label` and
  `levels`, and keys come back as atoms or strings exactly as you sent them.

  ## Answer specs

    * `{:noul, probability}`
    * `{:choice, option, confidence}` - `option` is one of the question's keys;
      the remaining probability is spread evenly across the other options
    * `{:score, level, confidence}` - `level` is a 0-based index; the remaining
      probability is spread evenly across the other levels

  A request that asks a question you did not stub raises, so a test cannot
  silently pass on a default answer.

  ## Errors and models

      TypeSafe.Test.stub_error(client, 429, %{"error" => "slow down"}, [{"retry-after", "1"}])
      TypeSafe.Test.stub_models(client, [%{name: "jev-1.13.0", description: "...", release_date: "2026-01-01"}])

  ## Concurrency

  Stubs use `Req.Test`, which follows the ownership model of `Mox`: call
  `Req.Test.set_req_test_from_context/1` in `setup` (or the `typesafe_stubs/1`
  helper here) and stubs are private to each async test.
  """

  # `plug` is optional; the Plug.Conn calls below are only reached from Req.Test stubs.
  @compile {:no_warn_undefined, Plug.Conn}

  alias TypeSafe.{Client, Keys}

  @default_name TypeSafe.Test

  @typedoc "How to answer one question."
  @type answer_spec ::
          {:noul, number()}
          | {:choice, atom() | String.t(), number()}
          | {:score, non_neg_integer(), number()}

  @doc """
  Builds a client whose requests are served by this module's stubs.

  Options are passed to `TypeSafe.new/1`; `api_key` defaults to `"test-key"`
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
    |> TypeSafe.new()
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

  Returns the client so the call can be piped.
  """
  @spec stub(Client.t(), keyword() | %{(atom() | String.t()) => answer_spec()}) :: Client.t()
  def stub(%Client{} = client, answers) when is_list(answers) or is_map(answers) do
    specs = Map.new(answers, fn {id, spec} -> {to_string(id), spec} end)

    Req.Test.stub(stub_name!(client), &evaluate_stub(&1, specs))
    client
  end

  @doc """
  Stubs every request with an HTTP error response.
  """
  @spec stub_error(Client.t(), pos_integer(), term(), [{String.t(), String.t()}]) :: Client.t()
  def stub_error(%Client{} = client, status, body \\ %{}, headers \\ []) do
    Req.Test.stub(stub_name!(client), &json(&1, status, body, headers))
    client
  end

  @doc """
  Sends a JSON response from inside a custom `Req.Test` stub, for cases the
  built-in stubs do not cover:

      Req.Test.stub(TypeSafe.Test, fn conn ->
        TypeSafe.Test.json(conn, 200, %{"models" => []})
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

    Req.Test.stub(stub_name!(client), &respond(&1, 200, %{"models" => wire}))
    client
  end

  # -- answer construction -----------------------------------------------------

  defp evaluate_stub(conn, specs) do
    case read_json(conn) do
      {%{"questions" => questions, "model" => model}, conn} when is_map(questions) ->
        answers = Map.new(questions, fn {id, question} -> {id, answer(id, question, specs)} end)

        respond(conn, 200, %{
          "model" => model,
          "answers" => answers,
          "usage" => %{
            "input_tokens" => usage_estimate(questions),
            "output_tokens" => map_size(answers) * 8
          }
        })

      {_other, conn} ->
        respond(conn, 422, %{"detail" => "TypeSafe.Test: request body is not a systemone request"})
    end
  end

  defp answer(id, %{"type" => "noul"}, specs) do
    case Map.fetch(specs, id) do
      {:ok, {:noul, probability}} when is_number(probability) ->
        %{"type" => "noul", "noul" => probability / 1}

      other ->
        mismatch(id, "noul", other)
    end
  end

  defp answer(id, %{"type" => "choice", "criteria" => criteria}, specs) do
    options = Map.keys(criteria)

    case Map.fetch(specs, id) do
      {:ok, {:choice, option, confidence}} when is_number(confidence) ->
        chosen = to_string(option)

        if chosen not in options do
          raise ArgumentError,
                "TypeSafe.Test: question #{inspect(id)} has no option #{inspect(option)}; " <>
                  "options are #{inspect(options)}"
        end

        %{
          "type" => "choice",
          "choice" => chosen,
          "probabilities" => spread(options, chosen, confidence),
          "confidence" => confidence / 1
        }

      other ->
        mismatch(id, "choice", other)
    end
  end

  defp answer(id, %{"type" => "score", "criteria" => levels}, specs) do
    count = length(levels)

    case Map.fetch(specs, id) do
      {:ok, {:score, level, confidence}} when is_integer(level) and is_number(confidence) ->
        if level < 0 or level >= count do
          raise ArgumentError,
                "TypeSafe.Test: question #{inspect(id)} has #{count} levels; got level #{level}"
        end

        keys = Enum.map(0..(count - 1), &Integer.to_string/1)
        probabilities = spread(keys, Integer.to_string(level), confidence)

        score =
          Enum.reduce(probabilities, 0.0, fn {key, probability}, acc ->
            acc + String.to_integer(key) * probability
          end)

        %{
          "type" => "score",
          "score" => score,
          "legend" => Map.new(Enum.zip(keys, levels)),
          "probabilities" => probabilities,
          "confidence" => confidence / 1
        }

      other ->
        mismatch(id, "score", other)
    end
  end

  defp answer(id, question, _specs) do
    raise ArgumentError,
          "TypeSafe.Test: question #{inspect(id)} has an unknown shape: #{inspect(question)}"
  end

  defp mismatch(id, type, :error) do
    raise ArgumentError, "TypeSafe.Test: no stub for question #{inspect(id)} (a #{type} question)"
  end

  defp mismatch(id, type, {:ok, spec}) do
    raise ArgumentError,
          "TypeSafe.Test: stub #{inspect(spec)} does not fit question #{inspect(id)}, a #{type} question"
  end

  # Gives `chosen` the confidence and spreads the remainder evenly over the rest.
  defp spread([_only], chosen, _confidence), do: %{chosen => 1.0}

  defp spread(keys, chosen, confidence) do
    rest = length(keys) - 1
    each = (1 - confidence) / rest
    Map.new(keys, fn key -> {key, if(key == chosen, do: confidence / 1, else: each)} end)
  end

  defp usage_estimate(questions) do
    questions |> JSON.encode!() |> byte_size() |> div(4)
  end

  # -- plug helpers ------------------------------------------------------------

  defp stub_name!(%Client{req_options: req_options}) do
    case Keyword.get(req_options, :plug) do
      {Req.Test, name} ->
        name

      _ ->
        raise ArgumentError,
              "TypeSafe.Test stubs need a client built with TypeSafe.Test.client/1 " <>
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

  defp respond(conn, status, body), do: json(conn, status, body)

  defp to_wire_date(%Date{} = date), do: Date.to_iso8601(date)
  defp to_wire_date(other), do: other
end
