defmodule TypeSafeAPI.JSON.EncodedTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.JSON.{Encoded, OrderedObject}

  describe "new/1" do
    test "serializes once and keeps both the term and its bytes" do
      object = OrderedObject.new([{"b", 1}, {"a", nil}])
      encoded = Encoded.new(object)

      assert Encoded.object(encoded) == object
      assert Encoded.to_string(encoded) == ~s({"b":1,"a":null})
    end
  end

  describe "JSON.Encoder" do
    test "encodes as the cached bytes, in place" do
      encoded = Encoded.new(OrderedObject.new([{"a", 1}]))

      assert JSON.encode!(%{"questions" => encoded}) == ~s({"questions":{"a":1}})
    end

    test "does not re-walk the term: tampering with object leaves the bytes alone" do
      # The point of the struct is that the term is serialized exactly once. If
      # encoding still walked `object`, swapping it would change the output.
      encoded = Encoded.new(OrderedObject.new([{"a", 1}]))
      tampered = %{encoded | object: OrderedObject.new([{"z", 99}])}

      assert JSON.encode!(tampered) == ~s({"a":1})
    end

    test "encodes the same bytes no matter how many times it is spliced in" do
      encoded = Encoded.new(OrderedObject.new([{"a", 1}, {"b", 2}]))

      bodies = Enum.map(1..5, fn _ -> JSON.encode!(%{"questions" => encoded}) end)

      assert Enum.uniq(bodies) == [~s({"questions":{"a":1,"b":2}})]
    end
  end

  describe "Inspect" do
    test "shows the encoded bytes" do
      encoded = Encoded.new(OrderedObject.new([{"a", 1}]))

      assert inspect(encoded) == ~s(#TypeSafeAPI.JSON.Encoded<"{\\"a\\":1}">)
    end
  end
end
