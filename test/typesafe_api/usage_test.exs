defmodule TypeSafeAPI.UsageTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.Usage

  doctest TypeSafeAPI.Usage

  describe "decode/1" do
    test "decodes the wire object" do
      assert Usage.decode(%{"input_tokens" => 312, "output_tokens" => 48}) ==
               %Usage{input_tokens: 312, output_tokens: 48}
    end

    test "anything that is not a usage object decodes to nil counts" do
      empty = %Usage{input_tokens: nil, output_tokens: nil}

      assert Usage.decode(nil) == empty
      assert Usage.decode(%{}) == empty
      assert Usage.decode("nope") == empty
      assert Usage.decode(42) == empty
      assert Usage.decode(%{"input_tokens" => 1.5, "output_tokens" => "48"}) == empty
      assert Usage.decode(%{"input_tokens" => -1}) == empty
    end
  end

  describe "total_tokens/1" do
    test "sums the two counts, treating a missing one as zero" do
      assert Usage.total_tokens(%Usage{input_tokens: 312, output_tokens: 48}) == 360
      assert Usage.total_tokens(%Usage{input_tokens: 312, output_tokens: nil}) == 312
      assert Usage.total_tokens(%Usage{input_tokens: nil, output_tokens: 48}) == 48
      assert Usage.total_tokens(%Usage{}) == 0
    end
  end

  describe "add/2" do
    test "sums two usages field by field" do
      a = %Usage{input_tokens: 10, output_tokens: 2}
      b = %Usage{input_tokens: 5, output_tokens: 3}

      assert Usage.add(a, b) == %Usage{input_tokens: 15, output_tokens: 5}
    end

    test "a nil count counts as zero, so summing a batch never raises" do
      assert Usage.add(%Usage{input_tokens: 10}, %Usage{output_tokens: 3}) ==
               %Usage{input_tokens: 10, output_tokens: 3}

      assert Usage.add(%Usage{}, %Usage{}) == %Usage{input_tokens: 0, output_tokens: 0}
    end

    test "folds over a batch" do
      batch = [
        %Usage{input_tokens: 10, output_tokens: 2},
        %Usage{input_tokens: nil, output_tokens: 3},
        %Usage{input_tokens: 5, output_tokens: nil}
      ]

      assert Enum.reduce(batch, %Usage{}, &Usage.add/2) ==
               %Usage{input_tokens: 15, output_tokens: 5}
    end
  end
end
