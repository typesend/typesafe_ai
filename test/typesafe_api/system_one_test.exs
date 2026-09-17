defmodule TypeSafeAPI.SystemOneTest do
  use TypeSafeAPI.StubCase, async: true

  alias TypeSafeAPI.{Answer, Error, Result, Usage}

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
        TypeSafeAPI.noul("Does this convey urgency?",
          true: "Explicitly time-sensitive",
          false: "No urgency expressed"
        ),
      dept:
        TypeSafeAPI.choice("Which team should handle this?",
          billing: "Payments, invoicing, refunds",
          technical: "Bugs, outages, integrations",
          sales: nil
        ),
      anger:
        TypeSafeAPI.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
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

      assert {:ok, %Result{} = result} = TypeSafeAPI.evaluate(client(), @state, questions())

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

      assert {:ok, %Result{request_id: "req_01"}} =
               TypeSafeAPI.evaluate(client(), @state, questions())
    end

    test "string ids and options come back as strings" do
      stub(json(200, @response))

      questions = [
        {"urgent", TypeSafeAPI.noul("Urgent?")},
        {"dept",
         TypeSafeAPI.choice("Team?", [{"billing", nil}, {"technical", nil}, {"sales", nil}])},
        {"anger", TypeSafeAPI.score("Anger?", ["Calm", "Frustrated", "Very angry"])}
      ]

      assert {:ok, result} = TypeSafeAPI.evaluate(client(), @state, questions)
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
      assert {:ok, _} = TypeSafeAPI.evaluate(client(), state, questions(), model: "jev-2")
      assert_receive {:body, %{"state" => ^state, "model" => "jev-2"}}
    end

    test "rejects invalid questions locally without a request" do
      stub(fn _conn -> flunk("no request expected") end)

      assert {:error, %Error{type: :validation, status: nil, message: message}} =
               TypeSafeAPI.evaluate(client(), @state,
                 bad: TypeSafeAPI.score("Only one level?", ["One"])
               )

      assert message =~ "question :bad"
      assert message =~ "at least 2 levels"

      assert {:error, %Error{type: :validation}} =
               TypeSafeAPI.evaluate(client(), @state, dept: TypeSafeAPI.choice("Team?", []))

      assert {:error, %Error{type: :validation}} = TypeSafeAPI.evaluate(client(), @state, [])

      assert {:error, %Error{type: :validation}} =
               TypeSafeAPI.evaluate(client(), @state, bad: %{type: "noul"})
    end

    test "rejects a non-JSON state locally" do
      stub(fn _conn -> flunk("no request expected") end)
      assert {:error, %Error{type: :validation}} = TypeSafeAPI.evaluate(client(), 42, questions())
    end

    test "surfaces HTTP errors" do
      stub(json(401, %{"error" => "bad key"}))

      assert {:error, %Error{type: :auth, status: 401}} =
               TypeSafeAPI.evaluate(client(), @state, questions())
    end

    test "a missing answer is an :unexpected error" do
      stub(json(200, put_in(@response, ["answers"], %{})))

      assert {:error, %Error{type: :unexpected}} =
               TypeSafeAPI.evaluate(client(), @state, questions())
    end

    test "an unknown or badly typed per-call option is a validation error, not a raise" do
      stub(fn _conn -> flunk("no request expected") end)

      assert {:error, %Error{type: :validation, status: nil, message: message}} =
               TypeSafeAPI.evaluate(client(), @state, questions(), model: 42)

      assert message =~ ":model"

      assert {:error, %Error{type: :validation}} =
               TypeSafeAPI.evaluate(client(), @state, questions(), nope: true)

      assert {:error, %Error{type: :validation}} =
               TypeSafeAPI.evaluate(client(), @state, questions(), %{model: "jev-2"})
    end

    test "a state with no JSON representation is a validation error, not a raise" do
      stub(fn _conn -> flunk("no request expected") end)

      for state <- [%URI{}, [a: 1], %{"at" => {1, 2}}] do
        assert {:error, %Error{type: :validation, message: message}} =
                 TypeSafeAPI.evaluate(client(), state, questions())

        assert message =~ "state cannot be encoded as JSON"
      end
    end

    test "a charlist state is rejected rather than sent as an array of code points" do
      stub(fn _conn -> flunk("no request expected") end)

      assert {:error, %Error{type: :validation, message: message}} =
               TypeSafeAPI.evaluate(client(), ~c"payouts failing", questions())

      assert message =~ "charlist"
      assert message =~ "List.to_string/1"
    end

    test "a Date state still encodes, so the check does not over-reject" do
      test_pid = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, JSON.decode!(raw)})
        json(200, @response).(conn)
      end)

      assert {:ok, _} = TypeSafeAPI.evaluate(client(), %{"on" => ~D[2026-01-01]}, questions())
      assert_receive {:body, %{"state" => %{"on" => "2026-01-01"}}}
    end

    test "accepts a Prepared question set in place of questions" do
      stub(json(200, @response))
      assert {:ok, prepared} = TypeSafeAPI.SystemOne.prepare(questions())

      assert {:ok, %Result{model: "jev-1.13.0"} = result} =
               TypeSafeAPI.SystemOne.evaluate(client(), @state, prepared)

      assert result.answers.dept.choice == :technical
    end

    test "a decode failure carries the response request id" do
      stub(
        json(200, put_in(@response, ["answers"], %{}), [
          {"x-typesafe-request-id", "req_decode_1"}
        ])
      )

      assert {:error, %Error{type: :unexpected, request_id: "req_decode_1"}} =
               TypeSafeAPI.evaluate(client(), @state, questions())
    end
  end

  defp position(haystack, needle) do
    {position, _length} = :binary.match(haystack, needle)
    position
  end

  describe "evaluate!/4" do
    test "returns the result or raises the error" do
      stub(json(200, @response))
      assert %Result{model: "jev-1.13.0"} = TypeSafeAPI.evaluate!(client(), @state, questions())

      stub(json(429, %{"error" => "slow down"}))

      assert_raise Error, "rate_limited (HTTP 429): slow down", fn ->
        TypeSafeAPI.evaluate!(client(), @state, questions())
      end
    end
  end

  describe "per-call retry overrides and retry_count" do
    test "a per-call retry keyword merges onto the client's policy instead of resetting it" do
      client =
        client(
          retry:
            Keyword.merge(fake_clock(), backoff_initial: 123, backoff_jitter: 0, max_retries: 5)
        )

      stub_sequence([json(529, %{}), json(529, %{}), json(200, @response)])

      assert {:ok, %Result{}} =
               TypeSafeAPI.evaluate(client, @state, questions(), retry: [max_retries: 2])

      # backoff_initial 123 from the client survived the per-call max_retries override
      assert sleeps() == [123, 246]
    end

    test "the result reports how many retries the call burned" do
      client = client(retry: Keyword.merge(fake_clock(), backoff_jitter: 0))
      stub_sequence([json(529, %{}), json(200, @response)])

      assert {:ok, %Result{retry_count: 1}} = TypeSafeAPI.evaluate(client, @state, questions())
    end
  end
end
