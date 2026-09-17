defmodule TypeSafe.TestTest do
  use ExUnit.Case, async: true

  alias TypeSafe.{Answer, Error, Result}

  setup :typesafe_stubs

  defp typesafe_stubs(context), do: TypeSafe.Test.typesafe_stubs(context)

  defp questions do
    [
      urgent: TypeSafe.noul("Urgent?"),
      dept: TypeSafe.choice("Team?", billing: "b", technical: "t", sales: nil),
      anger: TypeSafe.score("Anger?", ["Calm", "Frustrated", "Very angry"])
    ]
  end

  test "stubbed answers decode exactly like a real response" do
    client =
      TypeSafe.Test.client()
      |> TypeSafe.Test.stub(
        dept: {:choice, :technical, 0.9},
        urgent: {:noul, 0.3},
        anger: {:score, 2, 0.8}
      )

    assert {:ok, %Result{} = result} =
             TypeSafe.evaluate(client, "hello", questions(), model: "jev-x")

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

  test "string keys stay strings" do
    client = TypeSafe.Test.stub(TypeSafe.Test.client(), %{"dept" => {:choice, "sales", 0.6}})
    questions = %{"dept" => TypeSafe.choice("Team?", [{"billing", nil}, {"sales", nil}])}

    assert {:ok, result} = TypeSafe.evaluate(client, "hi", questions)
    assert result.answers["dept"].choice == "sales"
  end

  test "an unstubbed question raises with a clear message" do
    client = TypeSafe.Test.stub(TypeSafe.Test.client(), urgent: {:noul, 0.5})

    assert_raise ArgumentError, ~r/no stub for question "(dept|anger)"/, fn ->
      TypeSafe.evaluate(client, "hi", questions())
    end
  end

  test "a stub that does not fit the question type raises" do
    client = TypeSafe.Test.stub(TypeSafe.Test.client(), urgent: {:choice, :yes, 0.5})

    assert_raise ArgumentError, ~r/does not fit question "urgent"/, fn ->
      TypeSafe.evaluate(client, "hi", urgent: TypeSafe.noul("?"))
    end
  end

  test "an unknown option or level raises" do
    client = TypeSafe.Test.stub(TypeSafe.Test.client(), dept: {:choice, :legal, 0.5})

    assert_raise ArgumentError, ~r/has no option :legal/, fn ->
      TypeSafe.evaluate(client, "hi", dept: TypeSafe.choice("?", billing: nil, sales: nil))
    end

    client = TypeSafe.Test.stub(TypeSafe.Test.client(), anger: {:score, 5, 0.5})

    assert_raise ArgumentError, ~r/has 2 levels; got level 5/, fn ->
      TypeSafe.evaluate(client, "hi", anger: TypeSafe.score("?", ["a", "b"]))
    end
  end

  test "stub_error/4 returns typed errors with headers" do
    client =
      TypeSafe.Test.stub_error(TypeSafe.Test.client(), 429, %{"error" => "slow"}, [
        {"retry-after", "2"}
      ])

    assert {:error, %Error{type: :rate_limited, retry_after_ms: 2_000, message: "slow"}} =
             TypeSafe.evaluate(client, "hi", questions())
  end

  test "stub_models/2 serves the models endpoint" do
    client =
      TypeSafe.Test.stub_models(TypeSafe.Test.client(), [
        %{name: "jev-1", release_date: ~D[2026-01-01]}
      ])

    assert {:ok, [%TypeSafe.Model{name: "jev-1", release_date: ~D[2026-01-01], description: ""}]} =
             TypeSafe.models(client)
  end

  test "stubs need a test client" do
    assert_raise ArgumentError, ~r/TypeSafe.Test.client/, fn ->
      TypeSafe.Test.stub(TypeSafe.new(api_key: "k"), [])
    end
  end

  test "custom stub names and client options are honoured" do
    client = TypeSafe.Test.client(name: MyStubs, model: "jev-custom")
    assert client.model == "jev-custom"
    assert client.req_options[:plug] == {Req.Test, MyStubs}
    TypeSafe.Test.stub(client, urgent: {:noul, 1.0})
    assert {:ok, result} = TypeSafe.evaluate(client, "x", urgent: TypeSafe.noul("?"))
    assert result.model == "jev-custom"
  end
end
