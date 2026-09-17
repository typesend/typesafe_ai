defmodule TypeSafe.RetryTest do
  use TypeSafe.StubCase, async: true

  alias TypeSafe.{Error, HTTP, Retry}

  defp ok, do: json(200, %{"ok" => true})

  defp retrying_client(retry_opts) do
    client(retry: Keyword.merge(fake_clock(), retry_opts))
  end

  defp post(client), do: HTTP.post(client, "/v1/systemone", %{"state" => "x"})

  describe "policy construction" do
    test "defaults mirror the official SDK" do
      policy = Retry.new([])
      assert policy.max_retries == 2
      assert policy.backoff_initial == 500
      assert policy.backoff_max == 5_000
      assert policy.backoff_jitter == 0.25
      assert policy.budget == 30_000
      assert policy.respect_retry_after
      assert MapSet.member?(policy.statuses, 408)
      assert MapSet.member?(policy.statuses, 429)
      assert MapSet.member?(policy.statuses, 500)
      assert MapSet.member?(policy.statuses, 599)
      refute MapSet.member?(policy.statuses, 422)
    end

    test "rejects invalid options" do
      assert_raise NimbleOptions.ValidationError, fn -> Retry.new(backoff_jitter: 2) end
      assert_raise NimbleOptions.ValidationError, fn -> Retry.new(max_retries: -1) end
    end

    test "accepts a struct unchanged" do
      policy = Retry.new(max_retries: 7)
      assert Retry.new(policy) == policy
    end
  end

  describe "backoff/2" do
    test "doubles from the initial delay up to the max, minus jitter" do
      policy = Retry.new(backoff_initial: 500, backoff_max: 5_000, backoff_jitter: 0.25)

      for {attempt, expected} <- [
            {1, 500},
            {2, 1_000},
            {3, 2_000},
            {4, 4_000},
            {5, 5_000},
            {9, 5_000}
          ],
          _ <- 1..200 do
        delay = Retry.backoff(policy, attempt)
        assert delay <= expected
        assert delay >= round(expected * 0.75)
      end
    end

    test "zero jitter is deterministic" do
      policy = Retry.new(backoff_jitter: 0)
      assert Enum.map(1..4, &Retry.backoff(policy, &1)) == [500, 1_000, 2_000, 4_000]
    end

    test "zero initial or max disables backoff" do
      assert Retry.backoff(Retry.new(backoff_initial: 0), 3) == 0
      assert Retry.backoff(Retry.new(backoff_max: 0), 3) == 0
    end
  end

  describe "retry_after_ms/1" do
    test "parses Retry-After seconds, including fractions" do
      assert Retry.retry_after_ms(Req.Response.new(headers: %{"retry-after" => ["2"]})) == 2_000
      assert Retry.retry_after_ms(Req.Response.new(headers: %{"retry-after" => ["0.25"]})) == 250
    end

    test "parses retry-after-ms and prefers it over Retry-After" do
      headers = %{"retry-after-ms" => ["750"], "retry-after" => ["9"]}
      assert Retry.retry_after_ms(Req.Response.new(headers: headers)) == 750
    end

    test "parses an HTTP date in Retry-After" do
      future = DateTime.utc_now() |> DateTime.add(90, :second)
      date = Calendar.strftime(future, "%a, %d %b %Y %H:%M:%S GMT")
      ms = Retry.retry_after_ms(Req.Response.new(headers: %{"retry-after" => [date]}))
      assert ms > 85_000 and ms <= 90_000
    end

    test "a past HTTP date yields zero" do
      assert Retry.retry_after_ms(
               Req.Response.new(headers: %{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]})
             ) ==
               0
    end

    test "ignores negative or garbage values" do
      assert Retry.retry_after_ms(Req.Response.new(headers: %{"retry-after" => ["-1"]})) == nil
      assert Retry.retry_after_ms(Req.Response.new(headers: %{"retry-after" => ["soon"]})) == nil
      assert Retry.retry_after_ms(Req.Response.new(headers: %{"retry-after-ms" => ["nope"]})) == nil
      assert Retry.retry_after_ms(Req.Response.new()) == nil
    end
  end

  describe "retrying requests" do
    test "retries 529 then succeeds, sending the retry count header" do
      test_pid = self()

      stub_sequence([
        json(529, %{"error" => "overloaded"}),
        fn conn ->
          send(test_pid, {:retry_header, get_req_header(conn, "x-typesafe-retry-count")})
          ok().(conn)
        end
      ])

      assert {:ok, %{"ok" => true}} = post(retrying_client(max_retries: 2, backoff_jitter: 0))
      assert_receive {:retry_header, ["1"]}
      assert sleeps() == [500]
    end

    test "retries 429 using Retry-After seconds" do
      stub_sequence([json(429, %{}, [{"retry-after", "2"}]), ok()])
      assert {:ok, _} = post(retrying_client(max_retries: 2))
      assert sleeps() == [2_000]
    end

    test "retries using retry-after-ms, which beats Retry-After" do
      stub_sequence([json(429, %{}, [{"retry-after-ms", "120"}, {"retry-after", "5"}]), ok()])
      assert {:ok, _} = post(retrying_client(max_retries: 2))
      assert sleeps() == [120]
    end

    test "ignores Retry-After when respect_retry_after is false" do
      stub_sequence([json(429, %{}, [{"retry-after", "2"}]), ok()])

      assert {:ok, _} =
               post(retrying_client(max_retries: 2, respect_retry_after: false, backoff_jitter: 0))

      assert sleeps() == [500]
    end

    test "gives up after max_retries and returns the last error" do
      stub(json(529, %{"error" => "still overloaded"}))

      assert {:error, %Error{type: :overloaded}} =
               post(retrying_client(max_retries: 2, backoff_jitter: 0))

      assert sleeps() == [500, 1_000]
    end

    test "does not retry non-retryable statuses" do
      stub(json(422, %{"detail" => "bad"}))
      assert {:error, %Error{type: :validation}} = post(retrying_client(max_retries: 3))
      assert sleeps() == []
    end

    test "retries connection errors" do
      stub_sequence([transport_error(:econnrefused), ok()])
      assert {:ok, _} = post(retrying_client(max_retries: 1, backoff_jitter: 0))
      assert sleeps() == [500]
    end

    test "retries timeouts" do
      stub_sequence([transport_error(:timeout), ok()])
      assert {:ok, _} = post(retrying_client(max_retries: 1, backoff_jitter: 0))
      assert sleeps() == [500]
    end

    test "connection and timeout retries can be disabled independently" do
      stub_sequence([transport_error(:timeout), ok()])

      assert {:error, %Error{type: :timeout}} =
               post(retrying_client(max_retries: 1, retry_timeout_errors: false))

      stub_sequence([transport_error(:econnrefused), ok()])

      assert {:error, %Error{type: :connection}} =
               post(retrying_client(max_retries: 1, retry_connection_errors: false))

      assert sleeps() == []
    end

    test "max_retries: 0 never retries" do
      stub(json(529, %{}))
      assert {:error, %Error{type: :overloaded}} = post(retrying_client(max_retries: 0))
      assert sleeps() == []
    end
  end

  describe "total time budget" do
    test "stops before a retry whose delay would reach the budget" do
      # Repeated 529s with Retry-After: 20 and a 30s budget: the first retry
      # fits (0 + 20s < 30s), the second would land at 40s, so we stop there.
      counter = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(counter, 1, 1)
        json(529, %{"error" => "overloaded"}, [{"retry-after", "20"}]).(conn)
      end)

      client = retrying_client(max_retries: 10, budget: 30_000)
      assert {:error, %Error{type: :overloaded, retry_after_ms: 20_000}} = post(client)
      assert :counters.get(counter, 1) == 2
      assert sleeps() == [20_000]
      assert Enum.sum(sleeps()) < 30_000
    end

    test "a delay exactly equal to the remaining budget is not attempted" do
      stub(json(529, %{}, [{"retry-after", "30"}]))
      assert {:error, _} = post(retrying_client(max_retries: 5, budget: 30_000))
      assert sleeps() == []
    end

    test "budget accounts for time spent in attempts" do
      clock = fake_clock()
      slow_sleep = clock[:sleep_fun]
      # Simulate each attempt taking 12s of wall time by advancing the clock in the stub.
      stub(fn conn ->
        slow_sleep.(12_000)
        json(529, %{}, [{"retry-after", "5"}]).(conn)
      end)

      client = client(retry: Keyword.merge(clock, max_retries: 10, budget: 30_000))
      assert {:error, _} = post(client)
      # attempt 1 ends at 12s, retry delay 5s -> 17s < 30 ok; attempt 2 ends at 29s,
      # 29 + 5 >= 30 -> stop. Two attempts, one retry sleep.
      assert sleeps() == [12_000, 5_000, 12_000]
    end

    test "nil budget disables the limit" do
      stub_sequence([json(529, %{}, [{"retry-after", "100"}]), ok()])
      assert {:ok, _} = post(retrying_client(max_retries: 1, budget: nil))
      assert sleeps() == [100_000]
    end
  end

  describe "real sleeping" do
    test "uses Process.sleep by default and really waits" do
      stub_sequence([json(529, %{}, [{"retry-after-ms", "30"}]), ok()])
      client = client(retry: [max_retries: 1])
      {elapsed_us, {:ok, _}} = :timer.tc(fn -> post(client) end)
      assert elapsed_us >= 30_000
    end
  end
end
