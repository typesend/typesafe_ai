defmodule TypeSafe.SystemOneTest do
  use TypeSafe.StubCase, async: true

  alias TypeSafe.{Answer, Error, Result, Usage}

  @state "Help! My payouts have been failing for 3 days."

  @response %{
    "model" => "jev-1.13.0",
    "answers" => %{
      "urgent" => %{"type" => "noul", "noul" => 0.92},
      "dept" => %{
        "type" => "choice",
        "choice" => "technical",
        "probabilities" => %{"billing" => 0.08, "technical" => 0.85, "sales" => 0.07},
        "confidence" => 0.82
      },
      "anger" => %{
        "type" => "score",
        "score" => 1.6,
        "legend" => %{"0" => "Calm", "1" => "Frustrated", "2" => "Very angry"},
        "probabilities" => %{"0" => 0.05, "1" => 0.3, "2" => 0.65},
        "confidence" => 0.78
      }
    },
    "usage" => %{"input_tokens" => 312, "output_tokens" => 48}
  }

  defp questions do
    [
      urgent:
        TypeSafe.noul("Does this convey urgency?",
          true: "Explicitly time-sensitive",
          false: "No urgency expressed"
        ),
      dept:
        TypeSafe.choice("Which team should handle this?",
          billing: "Payments, invoicing, refunds",
          technical: "Bugs, outages, integrations",
          sales: nil
        ),
      anger: TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
    ]
  end

  describe "evaluate/4" do
    test "sends the documented request body and decodes the README example" do
      test_pid = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, raw})
        json(200, @response).(conn)
      end)

      assert {:ok, %Result{} = result} = TypeSafe.evaluate(client(), @state, questions())

      assert_receive {:body, raw}
      body = JSON.decode!(raw)
      assert body["state"] == @state
      assert body["model"] == "jev-latest"

      assert body["questions"] == %{
               "urgent" => %{
                 "type" => "noul",
                 "instructions" => "Does this convey urgency?",
                 "criteria" => %{
                   "true" => "Explicitly time-sensitive",
                   "false" => "No urgency expressed"
                 }
               },
               "dept" => %{
                 "type" => "choice",
                 "instructions" => "Which team should handle this?",
                 "criteria" => %{
                   "billing" => "Payments, invoicing, refunds",
                   "technical" => "Bugs, outages, integrations",
                   "sales" => nil
                 }
               },
               "anger" => %{
                 "type" => "score",
                 "instructions" => "How frustrated is the customer?",
                 "criteria" => ["Calm", "Frustrated", "Very angry"]
               }
             }

      # The wire keeps caller order for questions and options.
      assert position(raw, ~s("urgent":)) < position(raw, ~s("dept":))
      assert position(raw, ~s("dept":)) < position(raw, ~s("anger":))
      assert position(raw, ~s("billing":)) < position(raw, ~s("technical":))
      assert position(raw, ~s("technical":)) < position(raw, ~s("sales":))

      assert result.model == "jev-1.13.0"
      assert result.usage == %Usage{input_tokens: 312, output_tokens: 48}
      assert result.raw == @response
      assert result.request_id == nil

      assert %Answer.Noul{id: :urgent, noul: 0.92} = result.answers.urgent

      assert %Answer.Choice{id: :dept, choice: :technical, confidence: 0.82} = result.answers.dept
      assert result.answers.dept.probabilities == %{billing: 0.08, technical: 0.85, sales: 0.07}

      assert %Answer.Score{id: :anger, score: 1.6, level: 2, label: "Very angry", confidence: 0.78} =
               result.answers.anger

      assert result.answers.anger.levels == [
               {"Calm", 0.05},
               {"Frustrated", 0.3},
               {"Very angry", 0.65}
             ]

      assert result.answers.anger.probabilities == %{0 => 0.05, 1 => 0.3, 2 => 0.65}

      assert Answer.gate(result.answers.dept, act: 0.8, review: 0.5) == :act
      assert Answer.gate(result.answers.anger, act: 0.8, review: 0.5) == :review
      assert Answer.yes?(result.answers.urgent)
    end

    test "carries the x-typesafe-request-id header" do
      stub(json(200, @response, [{"x-typesafe-request-id", "req_01"}]))
      assert {:ok, %Result{request_id: "req_01"}} = TypeSafe.evaluate(client(), @state, questions())
    end

    test "string ids and options come back as strings" do
      stub(json(200, @response))

      questions = %{
        "urgent" => TypeSafe.noul("Urgent?"),
        "dept" => TypeSafe.choice("Team?", [{"billing", nil}, {"technical", nil}, {"sales", nil}]),
        "anger" => TypeSafe.score("Anger?", ["Calm", "Frustrated", "Very angry"])
      }

      assert {:ok, result} = TypeSafe.evaluate(client(), @state, questions)
      assert Map.keys(result.answers) |> Enum.sort() == ["anger", "dept", "urgent"]
      assert result.answers["dept"].choice == "technical"
      assert result.answers["dept"].probabilities["billing"] == 0.08
    end

    test "accepts a map state and per-call model override" do
      test_pid = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, JSON.decode!(raw)})
        json(200, @response).(conn)
      end)

      state = %{"ticket" => %{"subject" => "Payouts failing", "age_days" => 3}}
      assert {:ok, _} = TypeSafe.evaluate(client(), state, questions(), model: "jev-2")
      assert_receive {:body, %{"state" => ^state, "model" => "jev-2"}}
    end

    test "rejects invalid questions locally without a request" do
      stub(fn _conn -> flunk("no request expected") end)

      assert {:error, %Error{type: :validation, status: nil, message: message}} =
               TypeSafe.evaluate(client(), @state, bad: TypeSafe.score("Only one level?", ["One"]))

      assert message =~ "question :bad"
      assert message =~ "at least 2 levels"

      assert {:error, %Error{type: :validation}} =
               TypeSafe.evaluate(client(), @state, dept: TypeSafe.choice("Team?", []))

      assert {:error, %Error{type: :validation}} = TypeSafe.evaluate(client(), @state, [])

      assert {:error, %Error{type: :validation}} =
               TypeSafe.evaluate(client(), @state, bad: %{type: "noul"})
    end

    test "rejects a non-JSON state locally" do
      stub(fn _conn -> flunk("no request expected") end)
      assert {:error, %Error{type: :validation}} = TypeSafe.evaluate(client(), 42, questions())
    end

    test "surfaces HTTP errors" do
      stub(json(401, %{"error" => "bad key"}))

      assert {:error, %Error{type: :auth, status: 401}} =
               TypeSafe.evaluate(client(), @state, questions())
    end

    test "a missing answer is an :unexpected error" do
      stub(json(200, put_in(@response, ["answers"], %{})))
      assert {:error, %Error{type: :unexpected}} = TypeSafe.evaluate(client(), @state, questions())
    end

    test "validates per-call options" do
      assert_raise NimbleOptions.ValidationError, fn ->
        TypeSafe.evaluate(client(), @state, questions(), model: 42)
      end
    end
  end

  defp position(haystack, needle) do
    {position, _length} = :binary.match(haystack, needle)
    position
  end

  describe "evaluate!/4" do
    test "returns the result or raises the error" do
      stub(json(200, @response))
      assert %Result{model: "jev-1.13.0"} = TypeSafe.evaluate!(client(), @state, questions())

      stub(json(429, %{"error" => "slow down"}))

      assert_raise Error, "rate_limited (HTTP 429): slow down", fn ->
        TypeSafe.evaluate!(client(), @state, questions())
      end
    end
  end
end
