defmodule TypeSafeAPI.Guides.BroadwayAndObanTest do
  use TypeSafeAPI.StubCase, async: true

  alias TypeSafeAPI.Error

  # These two modules mirror, function for function, the `MyApp.Classifier.Core`
  # and `MyApp.ClassifyWorker.Core` modules shown in guides/broadway_and_oban.md.
  # Neither :broadway nor :oban is a dependency of this library, so what's
  # tested here is the plain-function core the guide pulls out of each
  # `handle_batch/4` and `perform/1` callback; the callbacks themselves are
  # untested wrappers around these.

  defmodule BroadwayCore do
    @moduledoc false

    def classify_batch(client, questions, states, opts \\ []) do
      opts = Keyword.merge([max_concurrency: 8, on_error: :collect], opts)
      TypeSafeAPI.evaluate_many(client, states, questions, opts)
    end
  end

  defmodule ObanCore do
    @moduledoc false

    @default_snooze_seconds 30

    def to_oban_result(%Error{type: type, retry_after_ms: retry_after_ms})
        when type in [:rate_limited, :overloaded] do
      seconds =
        case retry_after_ms do
          ms when is_integer(ms) and ms > 0 -> ceil(ms / 1000)
          _ -> @default_snooze_seconds
        end

      {:snooze, seconds}
    end

    def to_oban_result(%Error{type: type} = error) when type in [:validation, :auth] do
      {:cancel, Exception.message(error)}
    end

    def to_oban_result(%Error{} = error) do
      {:error, Exception.message(error)}
    end
  end

  defp questions do
    [
      category:
        TypeSafeAPI.choice("Classify this support message",
          bug_report: "Something is broken or producing errors",
          billing: "Charges, invoices, refunds, subscriptions",
          other: "Anything else"
        ),
      urgent: TypeSafeAPI.noul("Does this convey urgency?")
    ]
  end

  describe "Broadway pattern: classify_batch/4" do
    test "returns one outcome per state, in order" do
      client = client()

      TypeSafeAPI.Test.stub(client,
        category: {:choice, :bug_report, 0.9},
        urgent: {:noul, 0.8}
      )

      states = ["Checkout is broken", "How do I update my card?", "Refund please"]
      outcomes = BroadwayCore.classify_batch(client, questions(), states)

      assert length(outcomes) == 3
      assert Enum.all?(outcomes, &match?({:ok, %TypeSafeAPI.Result{}}, &1))
      assert Enum.all?(outcomes, fn {:ok, r} -> r.answers.category.choice == :bug_report end)
    end

    test "on_error: :collect keeps a failure in place next to successes" do
      client = client()

      stub(fn conn ->
        {:ok, raw, _conn} = Plug.Conn.read_body(conn)
        %{"state" => state, "questions" => qs} = JSON.decode!(raw)

        if state == "boom" do
          json(500, %{"error" => "boom"}).(conn)
        else
          answers =
            Map.new(qs, fn
              {"category", _} ->
                {"category",
                 %{
                   "type" => "choice",
                   "choice" => "other",
                   "probabilities" => %{"other" => 0.5},
                   "confidence" => 0.5
                 }}

              {"urgent", _} ->
                {"urgent", %{"type" => "noul", "noul" => 0.1}}
            end)

          json(200, %{
            "model" => "jev-1",
            "answers" => answers,
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }).(conn)
        end
      end)

      outcomes = BroadwayCore.classify_batch(client, questions(), ["ok-1", "boom", "ok-2"])

      assert [{:ok, _}, {:error, %TypeSafeAPI.Error{}}, {:ok, _}] = outcomes
    end
  end

  describe "Oban pattern: to_oban_result/1" do
    test "maps :rate_limited with retry_after_ms to a snooze in seconds" do
      error = %Error{type: :rate_limited, status: 429, message: "slow down", retry_after_ms: 4_500}
      assert ObanCore.to_oban_result(error) == {:snooze, 5}
    end

    test "maps :overloaded with no retry_after_ms to the default snooze" do
      error = %Error{type: :overloaded, status: 529, message: "busy", retry_after_ms: nil}
      assert ObanCore.to_oban_result(error) == {:snooze, 30}
    end

    test "maps :validation to a cancel" do
      error = %Error{type: :validation, status: 422, message: "bad question"}
      assert {:cancel, reason} = ObanCore.to_oban_result(error)
      assert reason =~ "bad question"
    end

    test "maps :auth to a cancel" do
      error = %Error{type: :auth, status: 401, message: "invalid key"}
      assert {:cancel, _reason} = ObanCore.to_oban_result(error)
    end

    test "maps :timeout, :connection and :unexpected to a retryable error" do
      for type <- [:timeout, :connection, :unexpected] do
        error = %Error{type: type, message: "transient"}
        assert {:error, reason} = ObanCore.to_oban_result(error)
        assert reason =~ "transient"
      end
    end

    test "perform-style integration: stubbed 429 flows through evaluate/4 to a snooze" do
      client = client()

      TypeSafeAPI.Test.stub_error(client, 429, %{"error" => "slow down"},
        headers: [{"retry-after-ms", "2000"}]
      )

      result =
        case TypeSafeAPI.evaluate(client, "Where is my refund?", questions()) do
          {:ok, result} -> {:ok, result}
          {:error, error} -> ObanCore.to_oban_result(error)
        end

      assert result == {:snooze, 2}
    end
  end

  describe "prepare/1 used for fail-fast startup validation" do
    test "a valid question set prepares cleanly" do
      assert {:ok, _prepared} = TypeSafeAPI.SystemOne.prepare(questions())
    end

    test "an invalid question set fails prepare/1 instead of the first batch" do
      bad_questions = [dept: TypeSafeAPI.choice("Pick one", [])]

      assert {:error, %TypeSafeAPI.Error{type: :validation}} =
               TypeSafeAPI.SystemOne.prepare(bad_questions)
    end
  end
end
