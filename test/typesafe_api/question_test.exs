defmodule TypeSafeAPI.QuestionTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.Error
  alias TypeSafeAPI.Question
  alias TypeSafeAPI.Question.{Choice, Noul, Score}

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
    test "rejects a map, since a map has no question order" do
      assert {:error, %Error{type: :validation, message: message}} =
               Question.normalize(%{
                 "is_urgent" => Noul.new("Urgent?"),
                 "department" => Choice.new("Dept?", billing: nil, sales: nil)
               })

      assert message =~ "not a map"
      assert message =~ "question order is what the model sees"
    end

    test "rejects an empty map too" do
      assert {:error, %Error{type: :validation}} = Question.normalize(%{})
    end
  end

  describe "normalize/1 validation" do
    test "rejects an empty keyword list" do
      assert {:error, %Error{type: :validation, message: message}} = Question.normalize([])
      assert message =~ "at least one question is required"
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

      assert message =~ "expected a TypeSafeAPI.Question.Noul, Choice, or Score struct"
    end

    test "rejects something that is not a keyword list or map entirely" do
      assert {:error, %Error{type: :validation, message: message}} = Question.normalize("nope")
      assert message =~ "questions must be a keyword list or list of {id, question} pairs"
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

    test "accepts nil instructions" do
      assert :ok = Question.validate(Score.new(nil, ["low", "high"]))
    end
  end

  describe "Choice.new/2 rejects maps" do
    test "raises for a map of any size, since a map has no option order" do
      for criteria <- [%{a: nil, b: nil}, Map.new(1..33, &{:"opt_#{&1}", nil})] do
        assert_raise ArgumentError, ~r/must be a keyword list or list of/, fn ->
          Choice.new("?", criteria)
        end
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

    test "rejects an empty option set but accepts a single option" do
      assert {:error, message} = Question.validate(Choice.new("Dept?", []))
      assert message =~ "Choice needs at least 1 option, got 0"

      assert :ok = Question.validate(Choice.new("Dept?", billing: nil))
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

    test "accepts nil instructions" do
      assert :ok = Question.validate(Choice.new(nil, billing: nil, sales: nil))
    end
  end

  describe "validate/1 for Noul" do
    test "accepts nil instructions" do
      assert :ok = Question.validate(Noul.new(nil))
      assert :ok = Question.validate(Noul.new())
      assert :ok = Question.validate(Noul.new(nil, true: "yes", false: "no"))
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

  describe "encode/1 omits instructions when nil" do
    test "Noul without criteria" do
      assert Question.encode(Noul.new()) == %{"type" => "noul"}
    end

    test "Noul with criteria" do
      assert Question.encode(Noul.new(nil, true: "yes", false: "no")) == %{
               "type" => "noul",
               "criteria" => %{"true" => "yes", "false" => "no"}
             }
    end

    test "Choice" do
      encoded = Question.encode(Choice.new(nil, billing: "Money", sales: nil))

      refute Map.has_key?(encoded, "instructions")
      assert encoded["type"] == "choice"
      assert encoded["criteria"].pairs == [{"billing", "Money"}, {"sales", nil}]
    end

    test "Score" do
      assert Question.encode(Score.new(nil, ["low", "high"])) == %{
               "type" => "score",
               "criteria" => ["low", "high"]
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

      assert %TypeSafeAPI.JSON.OrderedObject{pairs: pairs} = encoded.object
      assert Enum.map(pairs, fn {key, _} -> key end) == ["is_urgent", "department"]
    end
  end

  describe "normalize/1 rejects duplicate question ids" do
    test "two identical atom ids" do
      assert {:error, %Error{type: :validation, message: message}} =
               Question.normalize(urgent: Noul.new("a?"), urgent: Noul.new("b?"))

      assert message =~ ~s(question id "urgent" is given more than once)
    end

    test "an atom and a string that collide on the wire" do
      assert {:error, %Error{type: :validation, message: message}} =
               Question.normalize([{:billing, Noul.new("a?")}, {"billing", Noul.new("b?")}])

      assert message =~ ~s(question id "billing" is given more than once)
    end

    test "a valid set with distinct ids still normalizes" do
      assert {:ok, [{:a, _}, {"b", _}]} =
               Question.normalize([{:a, Noul.new("a?")}, {"b", Noul.new("b?")}])
    end
  end

  describe "validate/1 closes the gap between validation and encoding" do
    # Every term here passed validate/1 before and then raised from inside
    # JSON.Encoder on the request path.
    @unencodable [
      {"a struct", ~D[2024-01-01], "Date struct"},
      {"a tuple inside a list", [{:ok, 1}, "b"], "tuple"},
      {"a keyword list", [ok: 1], "tuple"},
      {"a pid inside a map", %{"pid" => :erlang.list_to_pid(~c"<0.0.0>")}, "JSON-encodable"},
      {"a map keyed by an integer", %{1 => "a"}, "map key that is not a string or atom"},
      {"a nested struct", %{"when" => ~D[2024-01-01]}, "Date struct"}
    ]

    for {label, term, expected} <- @unencodable do
      test "rejects #{label} as Noul instructions" do
        assert {:error, message} =
                 Question.validate(%Noul{instructions: unquote(Macro.escape(term))})

        assert message =~ "instructions"
        assert message =~ unquote(expected)
      end
    end

    test "rejects a function inside a list" do
      assert {:error, message} = Question.validate(%Noul{instructions: [fn -> :x end]})
      assert message =~ "JSON-encodable"
    end

    test "rejects an unencodable Score level description" do
      assert {:error, message} = Question.validate(Score.new("x", [[ok: 1], "b"]))
      assert message =~ "levels[0]"
      assert message =~ "tuple"
    end

    test "rejects an unencodable Choice option description" do
      assert {:error, message} =
               Question.validate(Choice.new("x", a: %{"d" => ~D[2024-01-01]}, b: nil))

      assert message =~ "criteria.a"
    end

    test "anything that validates also JSON-encodes" do
      questions = [
        plain: Noul.new("Urgent?", true: "yes", false: nil),
        structured:
          Choice.new(%{"text" => "Which?", "notes" => ["a", 1, true, nil]},
            billing: %{"desc" => ["money", 2.5]},
            sales: nil
          ),
        scored: Score.new(["Rate", "it"], [{"Calm", %{"why" => "quiet"}}, "Angry"])
      ]

      assert {:ok, normalized} = Question.normalize(questions)
      assert is_binary(JSON.encode!(Question.encode_all(normalized)))
    end

    test "still accepts numbers, booleans and nil nested in a description" do
      assert :ok =
               Question.validate(
                 Noul.new(%{"score" => 1.5, "on" => true, "off" => false, "none" => nil})
               )
    end

    test "a bad description surfaces as a :validation error, not an exception" do
      assert {:error, %Error{type: :validation, message: message}} =
               TypeSafeAPI.prepare(urgent: TypeSafeAPI.noul([{:a, 1}]))

      assert message =~ "question :urgent"
      assert message =~ "tuple"
    end
  end

  describe "Noul criteria in the instructions position" do
    test "a true/false keyword list alone is read as criteria" do
      question = TypeSafeAPI.noul(true: "yes", false: "no")

      assert question.instructions == nil
      assert question.criteria == %{true: "yes", false: "no"}
      assert :ok = Question.validate(question)
      assert JSON.encode!(Question.encode(question)) =~ ~s("criteria")
    end

    test "a keyword list with other keys stays instructions, and is rejected" do
      question = TypeSafeAPI.noul(text: "Urgent?")

      assert question.instructions == [text: "Urgent?"]
      assert {:error, message} = Question.validate(question)
      assert message =~ "tuple"
    end

    test "an explicit criteria argument still wins" do
      question = TypeSafeAPI.noul("Urgent?", true: "yes")

      assert question.instructions == "Urgent?"
      assert question.criteria == %{true: "yes"}
    end

    test "a plain list of strings is still instructions" do
      assert TypeSafeAPI.noul(["Urgent", "?"]).instructions == ["Urgent", "?"]
    end
  end

  describe "Noul criteria shapes" do
    test "accepts a nil criteria description, like Choice does" do
      assert :ok = Question.validate(Noul.new("Urgent?", true: "time-sensitive", false: nil))
    end

    test ~s(normalizes "true"/"false" string keys to atoms) do
      question = Noul.new("Spam?", [{"true", "spam"}, {"false", "legit"}])

      assert question.criteria == %{true: "spam", false: "legit"}
      assert :ok = Question.validate(question)

      assert Question.encode(question) == %{
               "type" => "noul",
               "instructions" => "Spam?",
               "criteria" => %{"true" => "spam", "false" => "legit"}
             }
    end

    test "validate/1 accepts string keys written straight into the struct, and encode agrees" do
      question = %Noul{instructions: "Spam?", criteria: %{"true" => "spam"}}

      assert :ok = Question.validate(question)
      assert Question.encode(question)["criteria"] == %{"true" => "spam"}
    end

    test "validate/1 accepts keyword-list criteria, which encode/1 already accepted" do
      question = %Noul{instructions: "Urgent?", criteria: [true: "yes"]}

      assert :ok = Question.validate(question)
      assert Question.encode(question)["criteria"] == %{"true" => "yes"}
    end

    test "rejects a criteria entry that is not a pair" do
      assert {:error, message} = Question.validate(%Noul{criteria: [true]})
      assert message =~ "Noul criteria must be"
    end

    test "noul() with nothing is still valid, and asks nothing" do
      assert :ok = Question.validate(TypeSafeAPI.noul())
      assert Question.encode(TypeSafeAPI.noul()) == %{"type" => "noul"}
    end
  end

  describe "Choice.new/2 with a bare list of option names" do
    test "normalizes atoms to {key, nil} pairs" do
      assert Choice.new("Which team?", [:billing, :sales]) ==
               Choice.new("Which team?", billing: nil, sales: nil)
    end

    test "normalizes strings to {key, nil} pairs" do
      assert Choice.new("Which?", ["a", "b"]).criteria == [{"a", nil}, {"b", nil}]
    end

    test "mixes bare names and pairs" do
      assert Choice.new("Which?", [:a, {:b, "described"}]).criteria == [
               {:a, nil},
               {:b, "described"}
             ]
    end

    test "a bare list validates and encodes" do
      question = Choice.new("Which team?", [:billing, :sales])

      assert :ok = Question.validate(question)

      assert JSON.encode!(Question.encode(question)["criteria"]) ==
               ~s({"billing":null,"sales":null})
    end

    test "still catches duplicates across bare names" do
      assert {:error, message} = Question.validate(Choice.new("Which?", [:a, "a"]))
      assert message =~ "given more than once"
    end
  end

  describe "Score labels" do
    test ~s(label/1 reads the %{"label" => ...} map encode/1 produces) do
      assert Score.label(%{"label" => "Calm", "description" => "quiet"}) == "Calm"
      assert Score.description(%{"label" => "Calm", "description" => "quiet"}) == "quiet"
    end

    test ~s(a map with a non-string "label" still falls back to inspect) do
      assert Score.label(%{"label" => 1}) == ~s(%{"label" => 1})
    end

    test "rejects duplicate labels" do
      assert {:error, message} = Question.validate(Score.new("x", ["High", "High"]))
      assert message =~ ~s(Score level label "High" is given more than once)
    end

    test "rejects duplicate labels across level shapes" do
      assert {:error, message} =
               Question.validate(Score.new("x", ["High", {"High", "also high"}]))

      assert message =~ "given more than once"
    end

    test "rejects an empty label" do
      assert {:error, message} = Question.validate(Score.new("x", ["", "hot"]))
      assert message =~ "must not be empty"

      assert {:error, _} = Question.validate(Score.new("x", [{"", "cold"}, "hot"]))
    end

    test "unlabelled structured levels do not collide with each other" do
      assert :ok = Question.validate(Score.new("x", [%{"a" => 1}, %{"a" => 1}]))
    end
  end

  describe "validate!/1 and prepare/1 agree" do
    test "prepare/1 returns the prepared set for a valid keyword list" do
      assert {:ok, prepared} = TypeSafeAPI.prepare(urgent: TypeSafeAPI.noul("Urgent?"))
      assert prepared.count == 1
    end
  end
end
