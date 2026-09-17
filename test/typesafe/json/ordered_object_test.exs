defmodule TypeSafe.JSON.OrderedObjectTest do
  use ExUnit.Case, async: true

  alias TypeSafe.JSON.OrderedObject

  describe "new/1" do
    test "wraps a list of pairs" do
      assert %OrderedObject{pairs: [{"a", 1}, {"b", 2}]} = OrderedObject.new([{"a", 1}, {"b", 2}])
    end

    test "wraps an empty list" do
      assert %OrderedObject{pairs: []} = OrderedObject.new([])
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

    test "preserves insertion order past 32 pairs, where plain maps would not" do
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
