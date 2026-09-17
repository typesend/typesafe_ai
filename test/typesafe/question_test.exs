defmodule TypeSafe.QuestionTest do
  use ExUnit.Case, async: true

  alias TypeSafe.Error
  alias TypeSafe.Question
  alias TypeSafe.Question.{Choice, Noul, Score}

  describe "normalize/1 with a keyword list" do
    test "returns an ordered list of {id, question} pairs" do
      assert {:ok,
              [
                {:is_urgent, %Noul{}},
                {:department, %Choice{}}
              ]} =
               Question.normalize(
                 is_urgent: Noul.new("Urgent?"),
                 department: Choice.new("Dept?", billing: nil, sales: nil)
               )
    end

    test "preserves the caller's order" do
      {:ok, pairs} =
        Question.normalize(
          c: Noul.new("C?"),
          a: Noul.new("A?"),
          b: Noul.new("B?")
        )

      assert Enum.map(pairs, fn {id, _} -> id end) == [:c, :a, :b]
    end
  end

  describe "normalize/1 with a map" do
    test "returns an ordered list of {id, question} pairs" do
      assert {:ok, pairs} =
               Question.normalize(%{
                 "is_urgent" => Noul.new("Urgent?"),
                 "department" => Choice.new("Dept?", billing: nil, sales: nil)
               })

      assert Enum.sort(Enum.map(pairs, fn {id, _} -> id end)) == ["department", "is_urgent"]
      assert Enum.all?(pairs, fn {id, _} -> is_binary(id) end)
    end
  end

  describe "normalize/1 validation" do
    test "rejects an empty keyword list" do
      assert {:error, %Error{type: :validation, message: message}} = Question.normalize([])
      assert message =~ "at least one question is required"
    end

    test "rejects an empty map" do
      assert {:error, %Error{type: :validation}} = Question.normalize(%{})
    end

    test "rejects a non-integer, non-atom, non-string id" do
      assert {:error, %Error{type: :validation, message: message}} =
               Question.normalize([{123, Noul.new("Urgent?")}])

      assert message =~ "question ids must be atoms or strings"
    end

    test "rejects a nil id" do
      assert {:error, %Error{type: :validation, message: message}} =
               Question.normalize([{nil, Noul.new("Urgent?")}])

      assert message =~ "question ids must be atoms or strings"
    end

    test "rejects a question that is not a Noul/Choice/Score struct" do
      assert {:error, %Error{type: :validation, message: message}} =
               Question.normalize(is_urgent: %{not: "a question struct"})

      assert message =~ "expected a TypeSafe.Question.Noul, Choice, or Score struct"
    end

    test "rejects something that is not a keyword list or map entirely" do
      assert {:error, %Error{type: :validation, message: message}} = Question.normalize("nope")
      assert message =~ "questions must be a keyword list or map"
    end

    test "rejects an entry that isn't a {id, question} pair" do
      assert {:error, %Error{type: :validation}} = Question.normalize([:not_a_pair])
    end
  end

  describe "validate/1 for Score" do
    test "rejects a single level" do
      assert {:error, message} = Question.validate(Score.new("Rate it", ["only one"]))
      assert message =~ "at least 2 levels"
    end

    test "rejects eleven levels" do
      levels = for n <- 1..11, do: "level #{n}"

      assert {:error, message} = Question.validate(Score.new("Rate it", levels))
      assert message =~ "at most 10 levels"
    end

    test "accepts the boundary of 2 levels" do
      assert :ok = Question.validate(Score.new("Rate it", ["low", "high"]))
    end

    test "accepts the boundary of 10 levels" do
      levels = for n <- 1..10, do: "level #{n}"
      assert :ok = Question.validate(Score.new("Rate it", levels))
    end

    test "rejects a non-string label in a {label, description} level" do
      assert {:error, message} =
               Question.validate(Score.new("Rate it", [{:not_a_string, "desc"}, "other"]))

      assert message =~ "Score level labels must be strings"
    end

    test "rejects nil instructions" do
      assert {:error, message} = Question.validate(Score.new(nil, ["low", "high"]))
      assert message =~ "instructions is required"
    end
  end

  describe "Choice.new/2 with a map" do
    test "accepts small maps and rejects maps that cannot preserve order" do
      assert %Choice{criteria: [a: nil, b: nil]} = Choice.new("?", %{a: nil, b: nil})

      big = Map.new(1..33, &{:"opt_#{&1}", nil})

      assert_raise ArgumentError, ~r/does not preserve order past 32 entries/, fn ->
        Choice.new("?", big)
      end
    end
  end

  describe "validate/1 for Choice" do
    test "rejects more than 255 options and accepts exactly 255" do
      ok = Choice.new("Which?", for(i <- 1..255, do: {"opt_#{i}", nil}))
      assert :ok = Question.validate(ok)

      too_many = Choice.new("Which?", for(i <- 1..256, do: {"opt_#{i}", nil}))
      assert {:error, message} = Question.validate(too_many)
      assert message =~ "at most 255 options, got 256"
    end

    test "rejects fewer than two options" do
      assert {:error, message} = Question.validate(Choice.new("Dept?", []))
      assert message =~ "Choice needs at least 2 options, got 0"

      assert {:error, message} = Question.validate(Choice.new("Dept?", billing: nil))
      assert message =~ "Choice needs at least 2 options, got 1"

      assert :ok = Question.validate(Choice.new("Dept?", billing: nil, sales: nil))
    end

    test "rejects duplicate options where an atom and a string collide on the wire" do
      question = Choice.new("Dept?", [{:a, "Option A"}, {"a", "Option A again"}])

      assert {:error, message} = Question.validate(question)
      assert message =~ "given more than once"
    end

    test "rejects duplicate options given as plain duplicate atoms" do
      question = Choice.new("Dept?", [{:a, "one"}, {:a, "two"}])

      assert {:error, message} = Question.validate(question)
      assert message =~ "given more than once"
    end

    test "accepts two options" do
      assert :ok = Question.validate(Choice.new("Dept?", billing: "Money stuff", other: nil))
    end

    test "rejects nil instructions" do
      assert {:error, message} = Question.validate(Choice.new(nil, billing: nil))
      assert message =~ "instructions is required"
    end
  end

  describe "validate/1 for Noul" do
    test "rejects nil instructions" do
      assert {:error, message} = Question.validate(Noul.new(nil))
      assert message =~ "instructions is required"
    end

    test "accepts nil criteria (criteria is optional)" do
      assert :ok = Question.validate(Noul.new("Urgent?"))
    end

    test "accepts full true/false criteria" do
      assert :ok = Question.validate(Noul.new("Urgent?", true: "yes", false: "no"))
    end

    test "new/2 keeps a misspelled criteria key for validate/1 to report" do
      question = Noul.new("Urgent?", ture: "sorta")
      assert question.criteria == %{ture: "sorta"}
      assert {:error, message} = Question.validate(question)
      assert message =~ ":ture"
    end

    test "rejects a criteria key that isn't true or false" do
      question = %Noul{instructions: "Urgent?", criteria: %{maybe: "sorta"}}
      assert {:error, message} = Question.validate(question)
      assert message =~ "Noul criteria keys must be true or false"
    end
  end

  describe "Score.label/1 and Score.description/1" do
    test "string levels are their own label and description" do
      assert Score.label("Calm") == "Calm"
      assert Score.description("Calm") == "Calm"
    end

    test "{label, description} levels split apart" do
      assert Score.label({"Calm", %{"detail" => "..."}}) == "Calm"
      assert Score.description({"Calm", %{"detail" => "..."}}) == %{"detail" => "..."}
    end

    test "structured levels without a label get a truncated inspect string" do
      long = %{"what" => String.duplicate("x", 200), "examples" => Enum.to_list(1..50)}
      label = Score.label(long)
      assert is_binary(label)
      assert String.length(label) <= 60
      assert String.ends_with?(label, "...")
      assert Score.label(%{"what" => "Cosmetic"}) == ~s(%{"what" => "Cosmetic"})
      assert Score.description(long) == long
    end
  end

  describe "validate!/1" do
    test "returns a valid question unchanged" do
      question = Noul.new("Urgent?", true: "yes")
      assert Question.validate!(question) == question
    end

    test "raises ArgumentError with the validation message" do
      assert_raise ArgumentError, ~r/invalid question: Score needs at least 2 levels/, fn ->
        Question.validate!(Score.new("Anger?", ["Calm"]))
      end

      assert_raise ArgumentError, ~r/Noul criteria keys must be true or false, got: :ture/, fn ->
        Question.validate!(Noul.new("Urgent?", ture: "sorta"))
      end
    end
  end

  describe "validate/1 accepts structured (map/list) instructions and descriptions" do
    test "Noul with map instructions and map criteria descriptions" do
      question =
        Noul.new(%{"text" => "Urgent?"}, true: %{"text" => "yes"}, false: ["no", "urgency"])

      assert :ok = Question.validate(question)
    end

    test "Choice with list instructions and structured option descriptions" do
      question =
        Choice.new(["Which", "department?"], billing: %{"desc" => "money"}, other: nil)

      assert :ok = Question.validate(question)
    end

    test "Score with map instructions and structured level descriptions" do
      question = Score.new(%{"text" => "Rate it"}, [%{"level" => "low"}, %{"level" => "high"}])
      assert :ok = Question.validate(question)
    end
  end

  describe "encode/1 for Noul" do
    test "encodes without criteria" do
      assert Question.encode(Noul.new("Urgent?")) == %{
               "type" => "noul",
               "instructions" => "Urgent?"
             }
    end

    test "encodes with criteria" do
      question = Noul.new("Urgent?", true: "Explicitly time-sensitive", false: "No urgency")

      assert Question.encode(question) == %{
               "type" => "noul",
               "instructions" => "Urgent?",
               "criteria" => %{
                 "true" => "Explicitly time-sensitive",
                 "false" => "No urgency"
               }
             }
    end
  end

  describe "encode/1 for Score" do
    test "encodes plain string levels" do
      question = Score.new("Rate it", ["Calm", "Frustrated", "Very angry"])

      assert Question.encode(question) == %{
               "type" => "score",
               "instructions" => "Rate it",
               "criteria" => ["Calm", "Frustrated", "Very angry"]
             }
    end

    test ~s(encodes a {label, description} level as {"label": ..., "description": ...}) do
      question =
        Score.new("Rate it", [
          "Calm",
          {"Very angry", "Threats to cancel, profanity, all caps"}
        ])

      assert Question.encode(question) == %{
               "type" => "score",
               "instructions" => "Rate it",
               "criteria" => [
                 "Calm",
                 %{
                   "label" => "Very angry",
                   "description" => "Threats to cancel, profanity, all caps"
                 }
               ]
             }
    end
  end

  describe "encode_all/1 for Choice: caller order" do
    # A fixed scramble of 1..40 (x * 17 mod 41 is a permutation): alphabetical,
    # numeric and map-hash ordering all differ from it, so any reordering on the
    # way to the wire fails this test rather than passing by luck.
    @scrambled Enum.map(1..40, &rem(&1 * 17, 41))

    test "encodes 40 criteria in caller order, byte for byte, on the wire" do
      options = Enum.map(@scrambled, fn n -> {:"option_#{n}", "Description #{n}"} end)

      {:ok, questions} = Question.normalize(department: Choice.new("Which option?", options))

      encoded_json = JSON.encode!(Question.encode_all(questions))

      expected_criteria =
        Enum.map_join(@scrambled, ",", fn n -> ~s("option_#{n}":"Description #{n}") end)

      assert String.contains?(encoded_json, ~s("criteria":{) <> expected_criteria <> "}")

      names_in_order =
        ~r/"option_(\d+)":/
        |> Regex.scan(encoded_json)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      assert names_in_order == @scrambled
      refute names_in_order == Enum.sort(@scrambled)

      decoded = JSON.decode!(encoded_json)
      criteria = decoded["department"]["criteria"]

      assert map_size(criteria) == 40

      for n <- @scrambled do
        assert criteria["option_#{n}"] == "Description #{n}"
      end
    end

    test "keeps caller order for 40 options sent through the whole request body" do
      options = Enum.map(@scrambled, fn n -> {:"option_#{n}", nil} end)

      {:ok, questions} = Question.normalize(department: Choice.new("Which option?", options))

      body_json = JSON.encode!(%{"state" => "x", "questions" => Question.encode_all(questions)})

      names_in_order =
        ~r/"option_(\d+)":/
        |> Regex.scan(body_json)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      assert names_in_order == @scrambled
    end
  end

  describe "encode_all/1" do
    test "encodes each question keyed by its wire id" do
      {:ok, questions} =
        Question.normalize([
          {:is_urgent, Noul.new("Urgent?")},
          {"department", Choice.new("Dept?", billing: nil, sales: nil)}
        ])

      encoded = Question.encode_all(questions)

      assert %TypeSafe.JSON.OrderedObject{pairs: pairs} = encoded
      assert Enum.map(pairs, fn {key, _} -> key end) == ["is_urgent", "department"]
    end
  end
end
