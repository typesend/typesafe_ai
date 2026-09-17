defmodule SupportTriageTest do
  @moduledoc """
  The whole suite runs offline. No API key, no network, no fixtures: every
  answer below is described by question id and `TypeSafeAPI.Test` builds the same
  structs a real call would decode.

  `async: false` because the batch test fans out into `Task` processes, which
  need the shared (rather than per-process) `Req.Test` ownership mode.
  """
  use ExUnit.Case, async: false

  alias TypeSafeAPI.{Error, Test}

  doctest SupportTriage

  setup :typesafe_stubs

  def typesafe_stubs(context), do: Test.typesafe_stubs(context)

  describe "triage/2" do
    test "escalates an urgent, confidently routed message" do
      client =
        stub(
          urgent: {:noul, 0.96},
          dept: {:choice, :technical, 0.91},
          frustration: {:score, 2, 0.84}
        )

      assert {:ok, {:escalate, :technical}} =
               SupportTriage.triage(client, "The payouts API has returned 500 for an hour.")
    end

    test "escalates an angry customer even when nothing is blocked" do
      client =
        stub(urgent: {:noul, 0.05}, dept: {:choice, :billing, 0.9}, frustration: {:score, 2, 0.88})

      assert {:ok, {:escalate, :billing}} =
               SupportTriage.triage(client, "Third billing mistake this year. I am done.")
    end

    test "queues a calm, non-blocking message" do
      client =
        stub(urgent: {:noul, 0.04}, dept: {:choice, :billing, 0.93}, frustration: {:score, 0, 0.9})

      assert {:ok, {:queue, :billing}} =
               SupportTriage.triage(client, "Could you send me last month's invoice?")
    end

    test "asks for a human when the department is a coin flip" do
      client =
        stub(urgent: {:noul, 0.71}, dept: {:choice, :billing, 0.44}, frustration: {:score, 1, 0.61})

      assert {:ok, {:needs_human_review, reasons}} =
               SupportTriage.triage(client, "Charged twice and the dashboard errors too.")

      assert [{:urgent, _, :review}, {:dept, _, :escalate}, {:frustration, _, :review}] = reasons
    end

    test "a single low-confidence answer is enough to block the automatic route" do
      client =
        stub(
          urgent: {:noul, 0.95},
          dept: {:choice, :technical, 0.65},
          frustration: {:score, 0, 0.9}
        )

      assert {:ok, {:needs_human_review, [{:dept, answer, :review}]}} =
               SupportTriage.triage(client, "Something is broken, not sure what.")

      assert answer.choice == :technical
      assert answer.confidence == 0.65
    end

    test "surfaces a rate limit as an error the caller can match on" do
      client =
        Test.client()
        |> Test.stub_error(429, %{"error" => "slow down"}, headers: [{"retry-after-ms", "1500"}])

      assert {:error, %Error{type: :rate_limited} = error} =
               SupportTriage.triage(client, "Anything at all.")

      assert error.retry_after_ms == 1500
      assert SupportTriage.describe({:error, error}) =~ "rate_limited (HTTP 429)"
    end
  end

  describe "triage_many/2" do
    test "returns one decision per message, in input order" do
      client = Test.client()

      by_state = %{
        "Refund never arrived." =>
          answers(
            urgent: {:noul, 0.1},
            dept: {:choice, :billing, 0.9},
            frustration: {:score, 0, 0.9}
          ),
        "Webhooks are timing out." =>
          answers(
            urgent: {:noul, 0.93},
            dept: {:choice, :technical, 0.9},
            frustration: {:score, 1, 0.9}
          ),
        "How much for 50 seats?" =>
          answers(
            urgent: {:noul, 0.02},
            dept: {:choice, :sales, 0.9},
            frustration: {:score, 0, 0.9}
          )
      }

      stub_by_state(by_state)

      messages = ["Refund never arrived.", "Webhooks are timing out.", "How much for 50 seats?"]

      assert [
               {:ok, {:queue, :billing}},
               {:ok, {:escalate, :technical}},
               {:ok, {:queue, :sales}}
             ] = SupportTriage.triage_many(client, messages)
    end

    test "one failing message does not sink the batch" do
      client = Test.client()

      ok =
        answers(urgent: {:noul, 0.1}, dept: {:choice, :billing, 0.9}, frustration: {:score, 0, 0.9})

      stub_by_state(%{"fine" => ok})

      assert [{:ok, {:queue, :billing}}, {:error, %Error{status: 422}}] =
               SupportTriage.triage_many(client, ["fine", "unknown"])
    end
  end

  # -- stubs -------------------------------------------------------------------

  defp stub(specs), do: Test.client() |> Test.stub(specs)

  # A stub that answers differently per state, for the batch tests. It builds the
  # wire body by hand, which is what `TypeSafeAPI.Test.stub/2` does for you when one
  # set of answers is enough.
  defp stub_by_state(by_state) do
    Req.Test.stub(TypeSafeAPI.Test, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"state" => state, "model" => model} = JSON.decode!(body)

      case Map.fetch(by_state, state) do
        {:ok, answers} ->
          Test.json(conn, 200, %{
            "model" => model,
            "answers" => answers,
            "usage" => %{"input_tokens" => 100, "output_tokens" => 24}
          })

        :error ->
          Test.json(conn, 422, %{"detail" => "no stub for state #{inspect(state)}"})
      end
    end)
  end

  # Turns the same `{:noul, p}` / `{:choice, option, c}` / `{:score, level, c}`
  # specs into the JSON the API would send.
  defp answers(specs) do
    Map.new(specs, fn {id, spec} -> {Atom.to_string(id), wire_answer(id, spec)} end)
  end

  defp wire_answer(_id, {:noul, probability}) do
    %{"type" => "noul", "noul" => probability}
  end

  defp wire_answer(id, {:choice, option, confidence}) do
    options = SupportTriage.questions()[id].criteria |> Enum.map(fn {key, _} -> to_string(key) end)

    %{
      "type" => "choice",
      "choice" => to_string(option),
      "probabilities" => spread(options, to_string(option), confidence),
      "confidence" => confidence
    }
  end

  defp wire_answer(id, {:score, level, confidence}) do
    levels = SupportTriage.questions()[id].levels
    keys = Enum.map(0..(length(levels) - 1), &Integer.to_string/1)
    probabilities = spread(keys, Integer.to_string(level), confidence)

    score =
      Enum.reduce(probabilities, 0.0, fn {key, p}, acc -> acc + String.to_integer(key) * p end)

    %{
      "type" => "score",
      "score" => score,
      "legend" => Map.new(Enum.zip(keys, levels)),
      "probabilities" => probabilities,
      "confidence" => confidence
    }
  end

  defp spread(keys, chosen, confidence) do
    each = (1 - confidence) / (length(keys) - 1)
    Map.new(keys, fn key -> {key, if(key == chosen, do: confidence, else: each)} end)
  end
end
