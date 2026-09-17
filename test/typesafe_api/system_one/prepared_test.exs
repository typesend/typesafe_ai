defmodule TypeSafeAPI.SystemOne.PreparedTest do
  use TypeSafeAPI.StubCase, async: true

  alias TypeSafeAPI.JSON.{Encoded, OrderedObject}
  alias TypeSafeAPI.SystemOne.Prepared

  @response %{
    "model" => "jev-1.13.0",
    "answers" => %{"urgent" => %{"type" => "noul", "noul" => 0.9}},
    "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
  }

  defp questions do
    [
      urgent: TypeSafeAPI.noul("Urgent?", true: "time-sensitive"),
      dept: TypeSafeAPI.choice("Team?", billing: nil, sales: nil)
    ]
  end

  describe "new/1" do
    test "derives count, encoding and key registry from the questions" do
      {:ok, prepared} = TypeSafeAPI.prepare(questions())

      assert %Prepared{count: 2, encoded: %Encoded{}} = prepared
      assert Enum.map(prepared.questions, fn {id, _} -> id end) == [:urgent, :dept]
      assert TypeSafeAPI.Keys.id(prepared.keys, "urgent") == :urgent
      assert TypeSafeAPI.Keys.option(prepared.keys, "dept", "billing") == :billing
    end

    test "builds the same struct TypeSafeAPI.prepare/1 returns" do
      {:ok, normalized} = TypeSafeAPI.Question.normalize(questions())

      assert {:ok, prepared} = TypeSafeAPI.prepare(questions())
      assert Prepared.new(normalized) == prepared
    end
  end

  describe "the wire encoding is built once" do
    test "the cached bytes are the question object, serialized" do
      {:ok, prepared} = TypeSafeAPI.prepare(questions())

      assert Encoded.to_string(prepared.encoded) ==
               JSON.encode!(Encoded.object(prepared.encoded))
    end

    test "request bodies for different states carry byte-identical questions" do
      test_pid = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, raw})
        TypeSafeAPI.Test.json(conn, 200, @response)
      end)

      {:ok, prepared} = TypeSafeAPI.prepare(questions())
      expected = ~s("questions":) <> Encoded.to_string(prepared.encoded)

      states = ["first state", "second state", "third state"]
      TypeSafeAPI.evaluate_many(client(), states, questions(), ordered: true)

      bodies =
        for _ <- states do
          assert_receive {:body, raw}
          raw
        end

      for raw <- bodies, do: assert(String.contains?(raw, expected))

      assert bodies |> Enum.map(&JSON.decode!(&1)["state"]) |> Enum.sort() == Enum.sort(states)
    end

    test "the questions object is serialized once, not once per state" do
      # Encoding walks the term at `Encoded.new/1` only. Replacing `object`
      # afterwards cannot change the bytes on the wire, which is exactly the
      # property that makes evaluate_many/4 amortize the encoding.
      {:ok, prepared} = TypeSafeAPI.prepare(questions())
      before = Encoded.to_string(prepared.encoded)

      tampered = %{
        prepared
        | encoded: %{prepared.encoded | object: OrderedObject.new([{"x", 1}])}
      }

      assert JSON.encode!(%{"questions" => tampered.encoded}) ==
               ~s({"questions":) <> before <> "}"
    end
  end

  describe "Inspect" do
    test "prints the ids and the count, not the whole question set" do
      {:ok, prepared} = TypeSafeAPI.prepare(questions())

      assert inspect(prepared) ==
               "#TypeSafeAPI.SystemOne.Prepared<count: 2, ids: [:urgent, :dept]>"
    end

    test "does not leak the instructions or the cached bytes" do
      {:ok, prepared} = TypeSafeAPI.prepare(secret: TypeSafeAPI.noul("do not print me"))

      refute inspect(prepared) =~ "do not print me"
      refute inspect(prepared) =~ "noul"
    end
  end
end
