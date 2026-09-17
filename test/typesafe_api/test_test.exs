defmodule TypeSafeAPI.TestTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.{Answer, Error, Result}

  setup :typesafe_stubs

  defp typesafe_stubs(context), do: TypeSafeAPI.Test.typesafe_stubs(context)

  defp questions do
    [
      urgent: TypeSafeAPI.noul("Urgent?"),
      dept: TypeSafeAPI.choice("Team?", billing: "b", technical: "t", sales: nil),
      anger: TypeSafeAPI.score("Anger?", ["Calm", "Frustrated", "Very angry"])
    ]
  end

  test "stubbed answers decode exactly like a real response" do
    client =
      TypeSafeAPI.Test.client()
      |> TypeSafeAPI.Test.stub(
        dept: {:choice, :technical, 0.9},
        urgent: {:noul, 0.3},
        anger: {:score, 2, 0.8}
      )

    assert {:ok, %Result{} = result} =
             TypeSafeAPI.evaluate(client, "hello", questions(), model: "jev-x")

    assert result.model == "jev-x"
    assert %Answer.Noul{id: :urgent, noul: 0.3} = result.answers.urgent

    assert %Answer.Choice{id: :dept, choice: :technical, confidence: 0.9} = result.answers.dept
    assert_in_delta result.answers.dept.probabilities.technical, 0.9, 1.0e-9
    assert_in_delta result.answers.dept.probabilities.billing, 0.05, 1.0e-9
    assert_in_delta Enum.sum(Map.values(result.answers.dept.probabilities)), 1.0, 1.0e-9

    assert %Answer.Score{id: :anger, level: 2, label: "Very angry", confidence: 0.8} =
             result.answers.anger

    assert_in_delta result.answers.anger.score, 0 * 0.1 + 1 * 0.1 + 2 * 0.8, 1.0e-9
    assert [{"Calm", _}, {"Frustrated", _}, {"Very angry", p}] = result.answers.anger.levels
    assert_in_delta p, 0.8, 1.0e-9
    assert result.answers.anger.legend == %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"}
    assert result.usage.input_tokens > 0
  end

  test "probabilities cover exactly the options that were sent" do
    client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), dept: {:choice, :sales, 0.5})

    assert {:ok, result} = TypeSafeAPI.evaluate(client, "hi", questions() |> Keyword.take([:dept]))

    assert Map.keys(result.answers.dept.probabilities) |> Enum.sort() ==
             [:billing, :sales, :technical]

    assert result.answers.dept.choice == :sales

    assert result.answers.dept.choice ==
             result.answers.dept.probabilities |> Enum.max_by(&elem(&1, 1)) |> elem(0)
  end

  test "string keys stay strings" do
    client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), %{"dept" => {:choice, "sales", 0.6}})
    questions = [{"dept", TypeSafeAPI.choice("Team?", [{"billing", nil}, {"sales", nil}])}]

    assert {:ok, result} = TypeSafeAPI.evaluate(client, "hi", questions)
    assert result.answers["dept"].choice == "sales"
  end

  test "an unstubbed question comes back as a validation error" do
    client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), urgent: {:noul, 0.5})

    assert {:error, %Error{type: :validation, status: 422, message: message}} =
             TypeSafeAPI.evaluate(client, "hi", questions())

    assert message =~ ~r/no stub for question "(dept|anger)"/
  end

  test "a stub that does not fit the question type is a validation error" do
    client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), urgent: {:choice, :yes, 0.5})

    assert {:error, %Error{type: :validation, message: message}} =
             TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("?"))

    assert message =~ ~s(does not fit question "urgent")
  end

  test "an unknown option or level is a validation error" do
    client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), dept: {:choice, :legal, 0.5})

    assert {:error, %Error{message: message}} =
             TypeSafeAPI.evaluate(client, "hi",
               dept: TypeSafeAPI.choice("?", billing: nil, sales: nil)
             )

    assert message =~ ~s(has no option "legal")

    client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), anger: {:score, 5, 0.5})

    assert {:error, %Error{message: message}} =
             TypeSafeAPI.evaluate(client, "hi", anger: TypeSafeAPI.score("?", ["a", "b"]))

    assert message =~ "has 2 levels; got level 5"
  end

  describe "confidence validation" do
    test "a confidence at or below the uniform baseline is rejected with the minimum" do
      client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), anger: {:score, 0, 0.2})

      assert {:error, %Error{type: :validation, message: message}} =
               TypeSafeAPI.evaluate(client, "hi",
                 anger: TypeSafeAPI.score("?", ["Calm", "Mad", "Livid"])
               )

      assert message =~ "uniform baseline for a 3-level question"
      assert message =~ "greater than 0.3333"
    end

    test "a confidence exactly at the baseline is rejected too" do
      client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), dept: {:choice, :b, 0.5})

      assert {:error, %Error{type: :validation, message: message}} =
               TypeSafeAPI.evaluate(client, "hi", dept: TypeSafeAPI.choice("?", a: nil, b: nil))

      assert message =~ "greater than 0.5"
    end

    test "a confidence above 1.0 is rejected when the stub is registered" do
      assert_raise ArgumentError,
                   ~r/confidence for question :dept must be between 0.0 and 1.0/,
                   fn ->
                     TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), dept: {:choice, :a, 1.4})
                   end
    end

    test "a probability outside 0.0..1.0 is rejected when the stub is registered" do
      assert_raise ArgumentError, ~r/probability for question :urgent/, fn ->
        TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), urgent: {:noul, -0.1})
      end
    end

    test "a spec that is not an answer spec at all is rejected" do
      assert_raise ArgumentError, ~r/is not an answer spec for question :urgent/, fn ->
        TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), urgent: {:noul, "high"})
      end

      assert_raise ArgumentError, ~r/is not an answer spec/, fn ->
        TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), anger: {:score, -1, 0.9})
      end
    end
  end

  describe "composition" do
    test "stub_models/2 and stub/2 serve their own endpoints on one client" do
      client =
        TypeSafeAPI.Test.client()
        |> TypeSafeAPI.Test.stub_models([%{name: "jev-1"}])
        |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.5})

      assert {:ok, [%TypeSafeAPI.Model{name: "jev-1"}]} = TypeSafeAPI.models(client)
      assert {:ok, result} = TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("?"))
      assert result.answers.urgent.noul == 0.5
    end

    test "successive stub/2 calls merge, and the last spec for an id wins" do
      client =
        TypeSafeAPI.Test.client()
        |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.1})
        |> TypeSafeAPI.Test.stub(dept: {:choice, :billing, 0.9})
        |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.9})

      assert {:ok, result} =
               TypeSafeAPI.evaluate(client, "hi",
                 urgent: TypeSafeAPI.noul("?"),
                 dept: TypeSafeAPI.choice("?", billing: nil, sales: nil)
               )

      assert result.answers.urgent.noul == 0.9
      assert result.answers.dept.choice == :billing
    end

    test "an unstubbed endpoint is a validation error naming the route" do
      client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), urgent: {:noul, 0.5})

      assert {:error, %Error{type: :validation, message: message}} = TypeSafeAPI.models(client)
      assert message =~ "no models stubbed"
    end

    test "times: 1 makes the error cover only the next call" do
      client =
        TypeSafeAPI.Test.client(retry: [max_retries: 0])
        |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.4})
        |> TypeSafeAPI.Test.stub_error(429, %{"error" => "slow down"}, times: 1)

      assert {:error, %Error{type: :rate_limited}} =
               TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("?"))

      assert {:ok, result} = TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("?"))
      assert result.answers.urgent.noul == 0.4
    end

    test "a retried call sees the queued error once and then the answers" do
      client =
        TypeSafeAPI.Test.client(retry: [max_retries: 2, backoff_initial: 0, backoff_max: 0])
        |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.4})
        |> TypeSafeAPI.Test.stub_error(429, %{"error" => "slow down"}, times: 1)

      assert {:ok, result} = TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("?"))
      assert result.answers.urgent.noul == 0.4
    end
  end

  test "a missing stub under evaluate_many is one error per state, not an exit" do
    client = TypeSafeAPI.Test.stub(TypeSafeAPI.Test.client(), urgent: {:noul, 0.5})

    results =
      TypeSafeAPI.evaluate_many(client, ["a", "b"],
        urgent: TypeSafeAPI.noul("?"),
        dept: TypeSafeAPI.choice("?", a: nil, b: nil)
      )

    assert [{:error, %Error{type: :validation} = first}, {:error, %Error{type: :validation}}] =
             results

    assert first.message =~ ~s(no stub for question "dept")
    assert Process.alive?(self())
  end

  test "stub_error/4 returns typed errors with headers" do
    client =
      TypeSafeAPI.Test.stub_error(TypeSafeAPI.Test.client(), 429, %{"error" => "slow"},
        headers: [{"retry-after", "2"}]
      )

    assert {:error, %Error{type: :rate_limited, retry_after_ms: 2_000, message: "slow"}} =
             TypeSafeAPI.evaluate(client, "hi", questions())
  end

  test "stub_error/4 rejects a bare header list with a message that names the fix" do
    assert_raise ArgumentError, ~r/takes options, not headers/, fn ->
      TypeSafeAPI.Test.stub_error(TypeSafeAPI.Test.client(), 429, %{}, [{"retry-after", "2"}])
    end
  end

  test "stub_models/2 serves the models endpoint" do
    client =
      TypeSafeAPI.Test.stub_models(TypeSafeAPI.Test.client(), [
        %{name: "jev-1", release_date: ~D[2026-01-01]}
      ])

    assert {:ok, [%TypeSafeAPI.Model{name: "jev-1", release_date: ~D[2026-01-01], description: ""}]} =
             TypeSafeAPI.models(client)
  end

  test "stubs need a test client" do
    assert_raise ArgumentError, ~r/TypeSafeAPI.Test.client/, fn ->
      TypeSafeAPI.Test.stub(TypeSafeAPI.new(api_key: "k"), [])
    end
  end

  test "custom stub names and client options are honoured" do
    client = TypeSafeAPI.Test.client(name: MyStubs, model: "jev-custom")
    assert client.model == "jev-custom"
    assert client.req_options[:plug] == {Req.Test, MyStubs}
    TypeSafeAPI.Test.stub(client, urgent: {:noul, 1.0})
    assert {:ok, result} = TypeSafeAPI.evaluate(client, "x", urgent: TypeSafeAPI.noul("?"))
    assert result.model == "jev-custom"
  end
end
