defmodule TypeSafeAPI.KeysTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.Keys
  alias TypeSafeAPI.Question.{Choice, Noul}

  describe "build/1 and id/2" do
    test "round-trips atom question ids" do
      keys = Keys.build([{:is_urgent, Noul.new("Urgent?")}])

      assert Keys.id(keys, "is_urgent") == :is_urgent
    end

    test "passes string question ids through" do
      keys = Keys.build([{"is_urgent", Noul.new("Urgent?")}])

      assert Keys.id(keys, "is_urgent") == "is_urgent"
    end

    test "returns unknown wire ids as strings" do
      keys = Keys.build([{:is_urgent, Noul.new("Urgent?")}])

      assert Keys.id(keys, "something_else") == "something_else"
    end

    test "builds an empty registry from an empty question list" do
      keys = Keys.build([])

      assert Keys.id(keys, "anything") == "anything"
    end
  end

  describe "build/1 and option/3" do
    test "round-trips atom Choice option keys" do
      question = Choice.new("Department?", billing: "Money stuff", technical: nil)
      keys = Keys.build([{:department, question}])

      assert Keys.option(keys, "department", "billing") == :billing
      assert Keys.option(keys, "department", "technical") == :technical
    end

    test "passes string Choice option keys through" do
      question = Choice.new("Department?", [{"billing", "Money stuff"}])
      keys = Keys.build([{:department, question}])

      assert Keys.option(keys, "department", "billing") == "billing"
    end

    test "returns unknown option strings from the API as strings" do
      question = Choice.new("Department?", billing: "Money stuff")
      keys = Keys.build([{:department, question}])

      assert Keys.option(keys, "department", "sales") == "sales"
    end

    test "returns the wire string for a wire_id with no recorded options (e.g. a Noul question)" do
      keys = Keys.build([{:is_urgent, Noul.new("Urgent?")}])

      assert Keys.option(keys, "is_urgent", "whatever") == "whatever"
    end

    test "returns the wire string for a completely unknown wire_id" do
      keys = Keys.build([])

      assert Keys.option(keys, "unknown_question", "unknown_option") == "unknown_option"
    end

    test "keeps options for different questions separate" do
      keys =
        Keys.build([
          {:department, Choice.new("Department?", billing: "Money")},
          {:priority, Choice.new("Priority?", high: "Urgent")}
        ])

      assert Keys.option(keys, "department", "high") == "high"
      assert Keys.option(keys, "priority", "high") == :high
    end
  end

  describe "wire/1" do
    test "passes strings through unchanged" do
      assert Keys.wire("already_a_string") == "already_a_string"
    end

    test "converts atoms to strings" do
      assert Keys.wire(:my_key) == "my_key"
    end

    test "raises ArgumentError for a non atom/string key" do
      assert_raise ArgumentError, fn -> Keys.wire(123) end
    end

    test "raises ArgumentError for nil" do
      assert_raise ArgumentError, fn -> Keys.wire(nil) end
    end

    test "raises ArgumentError for a list" do
      assert_raise ArgumentError, fn -> Keys.wire([:a, :b]) end
    end
  end

  describe "get/2" do
    test "reads an atom key" do
      assert Keys.get(%{model: "jev-x"}, :model) == "jev-x"
    end

    test "falls back to the string key" do
      assert Keys.get(%{"model" => "jev-x"}, :model) == "jev-x"
    end

    test "the atom key wins when both are present" do
      assert Keys.get(%{:model => "atom", "model" => "string"}, :model) == "atom"
    end

    test "a false value is a value, not an absent key" do
      assert Keys.get(%{:stream => false, "stream" => true}, :stream) == false
    end

    test "a nil value is a value, not an absent key" do
      assert Keys.get(%{:model => nil, "model" => "jev-x"}, :model) == nil
    end

    test "returns nil when neither key is present" do
      assert Keys.get(%{other: 1}, :model) == nil
    end

    test "returns nil for anything that is not a map" do
      assert Keys.get("not a map", :model) == nil
      assert Keys.get(nil, :model) == nil
    end
  end
end
