defmodule TypeSafeAPI.JSON.OrderedObjectTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.JSON.OrderedObject

  describe "new/1" do
    test "wraps a list of pairs" do
      assert %OrderedObject{pairs: [{"a", 1}, {"b", 2}]} = OrderedObject.new([{"a", 1}, {"b", 2}])
    end

    test "wraps an empty list" do
      assert %OrderedObject{pairs: []} = OrderedObject.new([])
    end

    test "raises for a key that is neither an atom nor a string" do
      assert_raise ArgumentError, ~r/keys must be atoms or strings, got: 1/, fn ->
        OrderedObject.new([{1, "one"}])
      end
    end

    test "raises for a nil key, which has no wire name" do
      assert_raise ArgumentError, ~r/keys must be atoms or strings, got: nil/, fn ->
        OrderedObject.new([{nil, "one"}])
      end
    end

    test "raises for an element that is not a two-element tuple" do
      assert_raise ArgumentError, ~r/takes \{key, value\} pairs, got: :a/, fn ->
        OrderedObject.new([:a, :b])
      end
    end

    test "raises for a three-element tuple" do
      assert_raise ArgumentError, ~r/takes \{key, value\} pairs/, fn ->
        OrderedObject.new([{"a", 1, 2}])
      end
    end
  end

  describe "Enumerable" do
    test "counts pairs, where map_size/1 would count struct fields" do
      object = OrderedObject.new([{"a", 1}, {"b", 2}])

      assert Enum.count(object) == 2
      assert map_size(Map.from_struct(object)) == 1
    end

    test "counts an empty object" do
      assert Enum.empty?(OrderedObject.new([]))
    end

    test "enumerates pairs in order" do
      object = OrderedObject.new([{"b", 1}, {"a", 2}])

      assert Enum.map(object, fn {key, _value} -> key end) == ["b", "a"]
      assert Enum.into(object, %{}) == %{"a" => 2, "b" => 1}
    end

    test "member?/2 sees pairs, not keys" do
      object = OrderedObject.new([{"a", 1}])

      assert Enum.member?(object, {"a", 1})
      refute Enum.member?(object, "a")
    end

    test "slices" do
      object = OrderedObject.new([{"a", 1}, {"b", 2}, {"c", 3}])

      assert Enum.slice(object, 1, 2) == [{"b", 2}, {"c", 3}]
    end
  end

  describe "JSON.Encoder / encode" do
    test "encodes an empty object" do
      assert JSON.encode!(OrderedObject.new([])) == "{}"
    end

    test "encodes nested values" do
      pairs = [
        {"nested_map", %{"inner" => 1}},
        {"nested_list", [1, 2, 3]},
        {"nested_object", OrderedObject.new([{"x", 1}])}
      ]

      encoded = JSON.encode!(OrderedObject.new(pairs))

      assert JSON.decode!(encoded) == %{
               "nested_map" => %{"inner" => 1},
               "nested_list" => [1, 2, 3],
               "nested_object" => %{"x" => 1}
             }
    end

    test "encodes atom keys as strings" do
      assert JSON.encode!(OrderedObject.new([{:a, 1}, {:b, 2}])) == ~s({"a":1,"b":2})
    end

    test "encodes string keys as-is" do
      assert JSON.encode!(OrderedObject.new([{"a", 1}, {"b", 2}])) == ~s({"a":1,"b":2})
    end

    test "mixes atom and string keys in one object" do
      assert JSON.encode!(OrderedObject.new([{:a, 1}, {"b", 2}])) == ~s({"a":1,"b":2})
    end

    test "preserves insertion order for many pairs, where a plain map would not" do
      pairs = for i <- 1..40, do: {"key_#{i}", i}

      encoded = JSON.encode!(OrderedObject.new(pairs))

      keys_in_order =
        Regex.scan(~r/"key_(\d+)":/, encoded)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      assert keys_in_order == Enum.to_list(1..40)
      assert JSON.decode!(encoded) == Map.new(pairs)
    end

    test "preserves order even when it is not sorted" do
      pairs = [{"z", 1}, {"a", 2}, {"m", 3}]

      assert JSON.encode!(OrderedObject.new(pairs)) == ~s({"z":1,"a":2,"m":3})
    end

    test "values that fail to encode raise, same as any other JSON.Encoder call" do
      assert_raise Protocol.UndefinedError, fn ->
        JSON.encode!(OrderedObject.new([{"a", self()}]))
      end
    end
  end
end
