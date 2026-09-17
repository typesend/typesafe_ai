defmodule TypeSafe.FanOutTest do
  use TypeSafe.StubCase, async: true

  alias TypeSafe.{Error, Result}

  defp questions, do: [urgent: TypeSafe.noul("Urgent?")]

  # States are numeric strings; the answer's noul echoes the number so results are traceable.
  defp echo_stub do
    stub(fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      %{"state" => state} = JSON.decode!(raw)

      case state do
        "fail" ->
          json(500, %{"error" => "boom"}).(conn)

        "slow" ->
          Process.sleep(1_500)
          json(200, response(0.0)).(conn)

        number ->
          Process.sleep(:rand.uniform(20))
          json(200, response(String.to_integer(number) / 100)).(conn)
      end
    end)
  end

  def response(noul) do
    %{
      "model" => "jev-1",
      "answers" => %{"urgent" => %{"type" => "noul", "noul" => noul}},
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  test "returns results in input order despite concurrent completion" do
    echo_stub()
    states = Enum.map(1..20, &Integer.to_string/1)

    outcomes = TypeSafe.evaluate_many(client(), states, questions(), max_concurrency: 8)

    assert length(outcomes) == 20
    assert Enum.all?(outcomes, &match?({:ok, %Result{}}, &1))

    assert Enum.map(outcomes, fn {:ok, r} -> r.answers.urgent.noul end) ==
             Enum.map(1..20, &(&1 / 100))
  end

  test "ordered: false yields in completion order but still all results" do
    echo_stub()
    states = Enum.map(1..10, &Integer.to_string/1)
    outcomes = TypeSafe.evaluate_many(client(), states, questions(), ordered: false)
    values = Enum.map(outcomes, fn {:ok, r} -> r.answers.urgent.noul end)
    assert Enum.sort(values) == Enum.map(1..10, &(&1 / 100))
  end

  test "on_error: :collect keeps errors in place" do
    echo_stub()
    outcomes = TypeSafe.evaluate_many(client(), ["1", "fail", "3"], questions())

    assert [{:ok, _}, {:error, %Error{type: :unexpected, status: 500}}, {:ok, _}] = outcomes
  end

  test "on_error: :raise raises the first error" do
    echo_stub()

    assert_raise Error, ~r/boom/, fn ->
      TypeSafe.evaluate_many(client(), ["1", "fail", "3"], questions(), on_error: :raise)
    end
  end

  test "task timeouts become :timeout errors and do not crash the caller" do
    echo_stub()
    outcomes = TypeSafe.evaluate_many(client(), ["1", "slow", "3"], questions(), timeout: 400)
    assert [{:ok, _}, {:error, %Error{type: :timeout}}, {:ok, _}] = outcomes
  end

  test "a non-JSON state is a per-state validation error" do
    stub(fn _conn -> flunk("no request expected") end)

    assert [{:error, %Error{type: :validation}}] =
             TypeSafe.evaluate_many(client(), [42], questions())
  end

  test "invalid questions fail once, before any request" do
    stub(fn _conn -> flunk("no request expected") end)

    assert {:error, %Error{type: :validation}} =
             TypeSafe.evaluate_many(client(), ["1", "2"], bad: TypeSafe.choice("?", []))
  end

  test "respects max_concurrency" do
    counter = :counters.new(2, [:atomics])

    stub(fn conn ->
      :counters.add(counter, 1, 1)
      current = :counters.get(counter, 1)
      if current > :counters.get(counter, 2), do: :counters.put(counter, 2, current)
      Process.sleep(20)
      :counters.sub(counter, 1, 1)
      json(200, response(0.5)).(conn)
    end)

    TypeSafe.evaluate_many(client(), List.duplicate("1", 12), questions(), max_concurrency: 3)
    assert :counters.get(counter, 2) <= 3
  end

  # Req.Test stubs run in-process and ignore Req timeouts, so this adapter
  # reports the timeout each request was built with instead.
  defmodule TimeoutProbe do
    def run(request) do
      send(:fan_out_timeout_probe, {:receive_timeout, request.options[:receive_timeout]})
      body = JSON.encode!(TypeSafe.FanOutTest.response(0.5))
      {request, Req.Response.new(status: 200, body: body)}
    end
  end

  test "attempt_timeout bounds each HTTP attempt" do
    Process.register(self(), :fan_out_timeout_probe)
    opts = [req_options: [adapter: TimeoutProbe]]

    assert [{:ok, _}] = TypeSafe.evaluate_many(client(), ["1"], questions(), opts)
    assert_receive {:receive_timeout, 10_000}

    assert [{:ok, _}] =
             TypeSafe.evaluate_many(client(), ["1"], questions(), [attempt_timeout: 50] ++ opts)

    assert_receive {:receive_timeout, 50}
  end

  test "validates options" do
    assert_raise NimbleOptions.ValidationError, fn ->
      TypeSafe.evaluate_many(client(), ["1"], questions(), on_error: :ignore)
    end
  end
end
