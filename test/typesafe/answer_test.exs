defmodule TypeSafe.AnswerTest do
  use ExUnit.Case, async: true

  alias TypeSafe.Answer
  alias TypeSafe.Answer.{Choice, Noul, Score}
  alias TypeSafe.{Error, Keys, Question}

  # From the API reference fixture (https://docs.typesafe.ai/api, verified 2026-09-16).
  defp department_question do
    Question.Choice.new("Which team should handle this?",
      billing: "Payments, invoicing, refunds",
      technical: "Bugs, outages, integrations",
      sales: nil
    )
  end

  defp frustration_question do
    Question.Score.new("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
  end

  defp department_question_string_keys do
    Question.Choice.new("Which team should handle this?", [
      {"billing", "Payments, invoicing, refunds"},
      {"technical", "Bugs, outages, integrations"},
      {"sales", nil}
    ])
  end

  defp keys_for(question, id \\ :department) do
    Keys.build([{id, question}])
  end

  describe "decode/4 — Noul" do
    test "decodes the wire fixture" do
      keys = Keys.build([{:is_urgent, Question.Noul.new("Does this convey urgency?")}])
      raw = %{"type" => "noul", "noul" => 0.92}

      assert {:ok, %Noul{id: :is_urgent, noul: 0.92}} =
               Answer.decode(raw, "is_urgent", Question.Noul.new("..."), keys)
    end

    test "type mismatch with the question is an unexpected error" do
      keys = Keys.build([{:is_urgent, Question.Noul.new("...")}])
      raw = %{"type" => "choice", "choice" => "x"}

      assert {:error, %Error{type: :unexpected}} =
               Answer.decode(raw, "is_urgent", Question.Noul.new("..."), keys)
    end

    test "unknown answer type is an unexpected error" do
      keys = Keys.build([{:is_urgent, Question.Noul.new("...")}])
      raw = %{"type" => "mystery"}

      assert {:error, %Error{type: :unexpected}} =
               Answer.decode(raw, "is_urgent", Question.Noul.new("..."), keys)
    end

    test "missing noul field is an unexpected error" do
      keys = Keys.build([{:is_urgent, Question.Noul.new("...")}])
      raw = %{"type" => "noul"}

      assert {:error, %Error{type: :unexpected}} =
               Answer.decode(raw, "is_urgent", Question.Noul.new("..."), keys)
    end
  end

  describe "decode/4 — Choice" do
    test "decodes the wire fixture with atom keys restored" do
      question = department_question()
      keys = keys_for(question)

      raw = %{
        "type" => "choice",
        "choice" => "technical",
        "probabilities" => %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07},
        "confidence" => 0.82
      }

      assert {:ok, %Choice{} = answer} = Answer.decode(raw, "department", question, keys)
      assert answer.id == :department
      assert answer.choice == :technical
      assert answer.confidence == 0.82
      assert answer.probabilities == %{billing: 0.08, technical: 0.85, sales: 0.07}
    end

    test "string-keyed caller gets strings back" do
      question = department_question_string_keys()
      keys = Keys.build([{"department", question}])

      raw = %{
        "type" => "choice",
        "choice" => "technical",
        "probabilities" => %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07},
        "confidence" => 0.82
      }

      assert {:ok, %Choice{id: "department", choice: "technical"} = answer} =
               Answer.decode(raw, "department", question, keys)

      assert answer.probabilities == %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07}
    end

    test "an option the API named that the caller never declared stays a string" do
      question = department_question()
      keys = keys_for(question)

      raw = %{
        "type" => "choice",
        "choice" => "legal",
        "probabilities" => %{"legal" => 1.0},
        "confidence" => 0.9
      }

      assert {:ok, %Choice{choice: "legal", probabilities: %{"legal" => 1.0}}} =
               Answer.decode(raw, "department", question, keys)
    end

    test "invalid probabilities is an unexpected error" do
      question = department_question()
      keys = keys_for(question)

      raw = %{
        "type" => "choice",
        "choice" => "technical",
        "probabilities" => "nope",
        "confidence" => 0.9
      }

      assert {:error, %Error{type: :unexpected}} =
               Answer.decode(raw, "department", question, keys)
    end
  end

  describe "decode/4 — Score" do
    test "decodes the wire fixture: level, label, levels, legend, probabilities" do
      question = frustration_question()
      keys = keys_for(question, :frustration)

      raw = %{
        "type" => "score",
        "score" => 1.6,
        "legend" => %{"0" => "Calm", "1" => "Frustrated", "2" => "Very angry"},
        "probabilities" => %{"0" => 0.05, "1" => 0.3, "2" => 0.65},
        "confidence" => 0.78
      }

      assert {:ok, %Score{} = answer} = Answer.decode(raw, "frustration", question, keys)

      assert answer.score == 1.6
      assert answer.level == 2
      assert answer.label == "Very angry"
      assert answer.levels == [{"Calm", 0.05}, {"Frustrated", 0.3}, {"Very angry", 0.65}]
      assert answer.probabilities == %{0 => 0.05, 1 => 0.3, 2 => 0.65}
      assert answer.legend == %{0 => "Calm", 1 => "Frustrated", 2 => "Very angry"}
      assert answer.confidence == 0.78
    end

    test "a level missing from probabilities defaults to 0.0 in levels" do
      question = frustration_question()
      keys = keys_for(question, :frustration)

      raw = %{
        "type" => "score",
        "score" => 0.1,
        "probabilities" => %{"0" => 1.0},
        "confidence" => 0.99
      }

      assert {:ok, %Score{levels: levels}} = Answer.decode(raw, "frustration", question, keys)
      assert levels == [{"Calm", 1.0}, {"Frustrated", 0.0}, {"Very angry", 0.0}]
    end

    test "label comes from the question's levels, not the legend" do
      question =
        Question.Score.new("How angry?", [
          {"calm", "Calm and collected"},
          {"upset", "Visibly upset"}
        ])

      keys = keys_for(question, :frustration)

      raw = %{
        "type" => "score",
        "score" => 1.0,
        "legend" => %{"0" => "totally different legend text", "1" => "also different"},
        "probabilities" => %{"0" => 0.1, "1" => 0.9},
        "confidence" => 0.9
      }

      assert {:ok, %Score{level: 1, label: "upset", description: "Visibly upset"}} =
               Answer.decode(raw, "frustration", question, keys)
    end

    test "a plain string level is its own label and description" do
      question = frustration_question()
      keys = keys_for(question, :frustration)

      raw = %{
        "type" => "score",
        "score" => 2.0,
        "probabilities" => %{"0" => 0.0, "1" => 0.0, "2" => 1.0},
        "confidence" => 1.0
      }

      assert {:ok, %Score{label: "Very angry", description: "Very angry"}} =
               Answer.decode(raw, "frustration", question, keys)
    end

    test "a structured level without a label gets a string label and keeps its description" do
      blocking = %{"what" => "Blocking", "examples" => ["nobody can log in"]}
      question = Question.Score.new("Severity?", [%{"what" => "Cosmetic"}, blocking])
      keys = keys_for(question, :severity)

      raw = %{
        "type" => "score",
        "score" => 1.0,
        "probabilities" => %{"0" => 0.0, "1" => 1.0},
        "confidence" => 1.0
      }

      assert {:ok, %Score{} = answer} = Answer.decode(raw, "severity", question, keys)
      assert is_binary(answer.label)
      assert answer.label =~ "Blocking"
      assert answer.description == blocking
      assert Enum.all?(answer.levels, fn {label, _} -> is_binary(label) end)
    end

    test "ties break to the lowest index" do
      question = frustration_question()
      keys = keys_for(question, :frustration)

      raw = %{
        "type" => "score",
        "score" => 0.5,
        "probabilities" => %{"0" => 0.5, "1" => 0.5, "2" => 0.0},
        "confidence" => 0.6
      }

      assert {:ok, %Score{level: 0, label: "Calm"}} =
               Answer.decode(raw, "frustration", question, keys)
    end

    test "a bad probability key is an unexpected error, never String.to_atom" do
      question = frustration_question()
      keys = keys_for(question, :frustration)

      raw = %{
        "type" => "score",
        "score" => 0.5,
        "probabilities" => %{"not-a-number" => 0.5},
        "confidence" => 0.6
      }

      assert {:error, %Error{type: :unexpected}} =
               Answer.decode(raw, "frustration", question, keys)
    end

    test "a bad legend key is an unexpected error" do
      question = frustration_question()
      keys = keys_for(question, :frustration)

      raw = %{
        "type" => "score",
        "score" => 0.5,
        "legend" => %{"nope" => "Calm"},
        "probabilities" => %{"0" => 1.0},
        "confidence" => 0.6
      }

      assert {:error, %Error{type: :unexpected}} =
               Answer.decode(raw, "frustration", question, keys)
    end
  end

  describe "gate/2" do
    test "Noul uses max(noul, 1 - noul)" do
      assert Answer.gate(%Noul{id: :x, noul: 0.9}, act: 0.8, review: 0.5) == :act
      assert Answer.gate(%Noul{id: :x, noul: 0.1}, act: 0.8, review: 0.5) == :act
      assert Answer.gate(%Noul{id: :x, noul: 0.6}, act: 0.8, review: 0.5) == :review
      assert Answer.gate(%Noul{id: :x, noul: 0.5}, act: 0.8, review: 0.5) == :review
      assert Answer.gate(%Noul{id: :x, noul: 0.5}, act: 0.8, review: 0.51) == :escalate
    end

    test "Choice uses confidence" do
      choice = %Choice{id: :x, choice: :a, probabilities: %{a: 1.0}, confidence: 0.82}
      assert Answer.gate(choice, act: 0.8, review: 0.5) == :act
      assert Answer.gate(%{choice | confidence: 0.6}, act: 0.8, review: 0.5) == :review
      assert Answer.gate(%{choice | confidence: 0.1}, act: 0.8, review: 0.5) == :escalate
    end

    test "Score uses confidence" do
      score = %Score{
        id: :x,
        score: 1.0,
        level: 0,
        label: "Calm",
        description: "Calm",
        levels: [{"Calm", 1.0}],
        probabilities: %{0 => 1.0},
        legend: %{},
        confidence: 0.78
      }

      assert Answer.gate(score, act: 0.8, review: 0.5) == :review
      assert Answer.gate(%{score | confidence: 0.8}, act: 0.8, review: 0.5) == :act
      assert Answer.gate(%{score | confidence: 0.4}, act: 0.8, review: 0.5) == :escalate
    end

    test "raises when act is lower than review" do
      assert_raise ArgumentError, fn ->
        Answer.gate(%Noul{id: :x, noul: 0.9}, act: 0.4, review: 0.5)
      end
    end
  end

  describe "yes?/2" do
    test "defaults to a 0.5 threshold" do
      assert Answer.yes?(%Noul{id: :x, noul: 0.51})
      refute Answer.yes?(%Noul{id: :x, noul: 0.49})
      assert Answer.yes?(%Noul{id: :x, noul: 0.5})
    end

    test "accepts an explicit threshold" do
      assert Answer.yes?(%Noul{id: :x, noul: 0.7}, 0.6)
      refute Answer.yes?(%Noul{id: :x, noul: 0.5}, 0.6)
    end
  end

  describe "confidence/1" do
    test "matches the value gate/2 uses for every answer type" do
      assert Answer.confidence(%Noul{id: :x, noul: 0.9}) == 0.9
      assert Answer.confidence(%Noul{id: :x, noul: 0.1}) == 0.9

      choice = %Choice{id: :x, choice: :a, probabilities: %{a: 1.0}, confidence: 0.42}
      assert Answer.confidence(choice) == 0.42
    end
  end
end
