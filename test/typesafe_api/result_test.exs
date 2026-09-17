defmodule TypeSafeAPI.ResultTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.{Error, Keys, Question, Result, Usage}

  # The API reference fixture (https://docs.typesafe.ai/api, verified 2026-09-16).
  defp fixture_questions(ids) do
    [is_urgent, department, frustration] = ids

    {:ok, questions} =
      Question.normalize([
        {is_urgent, Question.Noul.new("Does this convey urgency?")},
        {department,
         Question.Choice.new("Which team should handle this?",
           billing: "Payments, invoicing, refunds",
           technical: "Bugs, outages, integrations",
           sales: nil
         )},
        {frustration, Question.Score.new("How frustrated?", ["Calm", "Frustrated", "Very angry"])}
      ])

    questions
  end

  defp fixture_body(answer_ids \\ ~w(is_urgent department frustration)) do
    [is_urgent, department, frustration] = answer_ids

    %{
      "model" => "jev-latest",
      "answers" => %{
        is_urgent => %{"type" => "noul", "noul" => 0.92},
        department => %{
          "type" => "choice",
          "choice" => "technical",
          "probabilities" => %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07},
          "confidence" => 0.82
        },
        frustration => %{
          "type" => "score",
          "score" => 1.6,
          "legend" => %{"0" => "Calm", "1" => "Frustrated", "2" => "Very angry"},
          "probabilities" => %{"0" => 0.05, "1" => 0.3, "2" => 0.65},
          "confidence" => 0.78
        }
      },
      "usage" => %{"input_tokens" => 312, "output_tokens" => 48}
    }
  end

  test "answers for questions that were not asked are ignored but kept in raw" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    extra = %{"type" => "bounding_box", "box" => [0.1, 0.2, 0.3, 0.4], "confidence" => 0.5}
    body = fixture_body() |> put_in(["answers", "future_question"], extra)

    assert {:ok, %Result{} = result} = Result.decode(body, questions, keys)

    assert Map.keys(result.answers) |> Enum.sort() == [:department, :frustration, :is_urgent]
    assert result.answers.department.choice == :technical
    assert result.raw["answers"]["future_question"] == extra
  end

  test "atom ids round-trip through Keys.build and Result.decode" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)
    body = fixture_body()

    assert {:ok, %Result{} = result} = Result.decode(body, questions, keys)

    assert result.model == "jev-latest"
    assert Map.keys(result.answers) |> Enum.sort() == [:department, :frustration, :is_urgent]
    assert result.answers.is_urgent.noul == 0.92
    assert result.answers.department.choice == :technical
    assert result.answers.frustration.level == 2
    assert result.answers.frustration.label == "Very angry"
    assert result.usage == %Usage{input_tokens: 312, output_tokens: 48}
    assert result.raw == body
  end

  test "string ids round-trip and string-keyed callers get strings back" do
    questions = fixture_questions(["is_urgent", "department", "frustration"])
    keys = Keys.build(questions)
    body = fixture_body()

    assert {:ok, %Result{} = result} = Result.decode(body, questions, keys)

    assert Map.keys(result.answers) |> Enum.sort() ==
             ["department", "frustration", "is_urgent"]

    assert result.answers["department"].choice == :technical
  end

  test "extra answers are ignored but stay in raw" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    body =
      fixture_body()
      |> put_in(["answers", "extra"], %{"type" => "noul", "noul" => 0.1})

    assert {:ok, %Result{answers: answers, raw: raw}} = Result.decode(body, questions, keys)
    refute Map.has_key?(answers, "extra")
    refute Map.has_key?(answers, :extra)
    assert raw["answers"]["extra"] == %{"type" => "noul", "noul" => 0.1}
  end

  test "a missing answer for a question is an unexpected error" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)
    body = update_in(fixture_body(), ["answers"], &Map.delete(&1, "is_urgent"))

    assert {:error, %Error{type: :unexpected}} = Result.decode(body, questions, keys)
  end

  test "a missing or invalid model is an unexpected error" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    assert {:error, %Error{type: :unexpected}} =
             Result.decode(Map.delete(fixture_body(), "model"), questions, keys)

    assert {:error, %Error{type: :unexpected}} =
             Result.decode(Map.put(fixture_body(), "model", 42), questions, keys)
  end

  test "a missing or malformed usage degrades to nil token counts, not a failed call" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)
    empty = %Usage{input_tokens: nil, output_tokens: nil}

    assert {:ok, %Result{usage: ^empty}} =
             Result.decode(Map.delete(fixture_body(), "usage"), questions, keys)

    assert {:ok, %Result{usage: ^empty}} =
             Result.decode(Map.put(fixture_body(), "usage", nil), questions, keys)

    assert {:ok, %Result{usage: ^empty}} =
             Result.decode(Map.put(fixture_body(), "usage", "nope"), questions, keys)
  end

  test "spec drift: the OpenAPI schema requires usage with both token counts" do
    schema =
      "priv/openapi.json"
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["components", "schemas", "Usage"])

    assert Enum.sort(schema["required"]) == ["input_tokens", "output_tokens"]
    assert schema["properties"]["input_tokens"]["type"] == "integer"
    assert schema["properties"]["output_tokens"]["type"] == "integer"
  end

  test "decode/4 puts the request id on every decode error" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)
    body = update_in(fixture_body(), ["answers"], &Map.delete(&1, "is_urgent"))

    assert {:error, %Error{type: :unexpected, request_id: "req_123"}} =
             Result.decode(body, questions, keys, "req_123")

    assert {:error, %Error{type: :unexpected, request_id: "req_123"}} =
             Result.decode(Map.delete(body, "model"), questions, keys, "req_123")
  end

  test "decode/4 puts the request id on the decoded result" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    assert {:ok, %Result{request_id: "req_123"}} =
             Result.decode(fixture_body(), questions, keys, "req_123")
  end

  test "decode/3 still works and leaves request_id nil" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    assert {:ok, %Result{request_id: nil}} = Result.decode(fixture_body(), questions, keys)
  end

  test "inspect elides raw but keeps the other fields" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    assert {:ok, result} = Result.decode(fixture_body(), questions, keys)
    text = inspect(result)

    assert text =~ "raw: #elided"
    refute text =~ "bounding_box"
    refute text =~ "input_tokens\" =>"
    assert text =~ "model: \"jev-latest\""
    assert text =~ ":department"
  end

  test "nil usage tokens decode to nil, not a crash" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    body =
      put_in(fixture_body(), ["usage"], %{"input_tokens" => nil, "output_tokens" => nil})

    assert {:ok, %Result{usage: %Usage{input_tokens: nil, output_tokens: nil}}} =
             Result.decode(body, questions, keys)
  end

  test "usage with no tokens at all decodes to nil fields" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)
    body = put_in(fixture_body(), ["usage"], %{})

    assert {:ok, %Result{usage: %Usage{input_tokens: nil, output_tokens: nil}}} =
             Result.decode(body, questions, keys)
  end

  test "Usage.decode/1 accepts nil directly" do
    assert Usage.decode(nil) == %Usage{input_tokens: nil, output_tokens: nil}
  end

  test "a type mismatch inside an answer surfaces as an unexpected error" do
    questions = fixture_questions([:is_urgent, :department, :frustration])
    keys = Keys.build(questions)

    body = put_in(fixture_body(), ["answers", "is_urgent", "type"], "choice")

    assert {:error, %Error{type: :unexpected}} = Result.decode(body, questions, keys)
  end
end
