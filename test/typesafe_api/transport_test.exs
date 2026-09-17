defmodule TypeSafeAPI.TransportTest do
  @moduledoc """
  Regression tests for the transport-layer review findings: the no-replay
  guard, retry delay clamping and merging, the `finch:` option, error types,
  and response metadata on failures.
  """

  use TypeSafeAPI.StubCase, async: true

  alias TypeSafeAPI.{Client, Error, HTTP, Retry}

  defp ok, do: json(200, %{"ok" => true})
  defp post(client), do: HTTP.post(client, "/v1/systemone", %{"state" => "x"})
  defp retrying_client(opts), do: client(retry: Keyword.merge(fake_clock(), opts))

  # -- 1. retry_timeout_errors honours the :auto no-replay guard ---------------

  describe "retry_timeout_errors: :auto" do
    test "defaults to :auto and resolves per method like connection errors" do
      policy = Retry.new([])
      assert policy.retry_timeout_errors == :auto
      assert Retry.for_method(policy, :get).retry_timeout_errors == true
      assert Retry.for_method(policy, :post).retry_timeout_errors == false
    end

    test "a timed-out POST is not replayed by default" do
      counter = :counters.new(1, [])

      stub(fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Error{type: :timeout}} = post(retrying_client(max_retries: 2))
      assert :counters.get(counter, 1) == 1
      assert sleeps() == []
    end

    test "a timed-out GET is retried by default" do
      stub_sequence([transport_error(:timeout), ok()])
      client = retrying_client(max_retries: 1, backoff_jitter: 0)
      assert {:ok, _} = HTTP.get(client, "/v1/models")
      assert sleeps() == [500]
    end

    test "an explicit true replays a POST timeout" do
      stub_sequence([transport_error(:timeout), ok()])

      assert {:ok, _} =
               post(retrying_client(max_retries: 1, backoff_jitter: 0, retry_timeout_errors: true))

      assert sleeps() == [500]
    end
  end

  # -- 2. a server-sent delay of 0 does not remove backoff ---------------------

  describe "server-sent delay clamping" do
    test "retry-after: 0 is floored at retry_after_min instead of looping" do
      stub(json(529, %{}, [{"retry-after", "0"}]))

      assert {:error, %Error{type: :overloaded}} =
               post(retrying_client(max_retries: 2, backoff_jitter: 0))

      assert sleeps() == [100, 100]
    end

    test "a short server delay is honored below the backoff schedule" do
      stub_sequence([json(429, %{}, [{"retry-after-ms", "200"}]), ok()])

      assert {:ok, _} = post(retrying_client(max_retries: 1, backoff_jitter: 0))
      assert sleeps() == [200]
    end

    test "retry_after_min is configurable" do
      stub(json(529, %{}, [{"retry-after", "0"}]))

      assert {:error, _} =
               post(retrying_client(max_retries: 1, backoff_jitter: 0, retry_after_min: 750))

      assert sleeps() == [750]
    end

    test "an empty retry-after-ms header is floored, not zero" do
      stub(json(429, %{}, [{"retry-after-ms", ""}]))

      assert {:error, %Error{type: :rate_limited}} =
               post(retrying_client(max_retries: 1, backoff_jitter: 0))

      assert sleeps() == [100]
    end

    test "a past HTTP date is floored, not zero" do
      stub(json(429, %{}, [{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}]))

      assert {:error, _} = post(retrying_client(max_retries: 1, backoff_jitter: 0))
      assert sleeps() == [100]
    end

    test "a server delay above retry_after_max is clamped" do
      stub_sequence([json(429, %{}, [{"retry-after", "3600"}]), ok()])

      assert {:ok, _} =
               post(retrying_client(max_retries: 1, budget: nil, retry_after_max: 10_000))

      assert sleeps() == [10_000]
    end
  end

  # -- 3. req_options cannot re-enable Req's own retry step --------------------

  describe "req_options guard rails" do
    test "the client schema rejects options the library owns" do
      for {key, value} <- [retry: :transient, auth: {:bearer, "x"}, base_url: "https://x"] do
        assert_raise NimbleOptions.ValidationError, ~r/#{key}/, fn ->
          Client.new(api_key: "k", req_options: [{key, value}])
        end
      end
    end

    test "the client schema rejects :finch in req_options and names the option" do
      assert_raise NimbleOptions.ValidationError, ~r/finch:/, fn ->
        Client.new(api_key: "k", req_options: [finch: MyApp.Finch])
      end
    end

    test "a per-call retry: :transient in req_options cannot re-enable Req's retry step" do
      request =
        HTTP.build(client(), :post, "/v1/systemone", %{}, req_options: [retry: :transient])

      assert request.options[:retry] == false
    end
  end

  # -- 4. a first-class finch: option ------------------------------------------

  describe "finch:" do
    test "names the pool and omits connect_options entirely" do
      client = client(finch: MyApp.Finch)
      request = HTTP.build(client, :post, "/v1/systemone", %{})

      assert request.options[:finch] == MyApp.Finch
      refute Map.has_key?(request.options, :connect_options)
    end

    test "connect_options from req_options keep the client's connect timeout" do
      client = client(connect_timeout: 7_777, req_options: [connect_options: [proxy: :p]])
      request = HTTP.build(client, :post, "/v1/systemone", %{})

      assert Enum.sort(request.options[:connect_options]) == [proxy: :p, timeout: 7_777]
    end

    test "an explicit timeout inside connect_options wins" do
      client = client(connect_timeout: 7_777, req_options: [connect_options: [timeout: 10]])
      request = HTTP.build(client, :post, "/v1/systemone", %{})

      assert request.options[:connect_options][:timeout] == 10
    end

    test "finch and connect_options together are rejected at build time" do
      assert_raise ArgumentError, ~r/cannot set both/, fn ->
        Client.new(api_key: "k", finch: MyApp.Finch, req_options: [connect_options: [proxy: :p]])
      end
    end
  end

  # -- 5. a per-call retry keyword merges onto the client policy ---------------

  describe "per-call retry overrides" do
    test "a keyword list layers onto the client policy" do
      client = client(retry: [max_retries: 7, budget: 60_000, backoff_initial: 25])
      request = HTTP.build(client, :post, "/v1/systemone", %{}, retry: [max_retries: 1])
      policy = Req.Request.get_private(request, :typesafe_retry)

      assert policy.max_retries == 1
      assert policy.budget == 60_000
      assert policy.backoff_initial == 25
    end

    test "a struct replaces the client policy wholesale" do
      client = client(retry: [max_retries: 7, budget: 60_000])
      override = Retry.new(max_retries: 1)
      request = HTTP.build(client, :post, "/v1/systemone", %{}, retry: override)
      policy = Req.Request.get_private(request, :typesafe_retry)

      assert policy.max_retries == 1
      assert policy.budget == 30_000
    end
  end

  # -- 6. empty and non-JSON 2xx bodies ----------------------------------------

  describe "2xx bodies" do
    test "a 204 with no body succeeds with an empty map" do
      stub(fn conn -> send_resp(conn, 204, "") end)

      assert {:ok, %HTTP.Response{status: 204, body: %{}}} =
               HTTP.request(client(), :post, "/v1/systemone", %{})

      assert {:ok, %{}} = post(client())
    end

    test "an empty 200 body succeeds with an empty map" do
      stub(fn conn -> send_resp(conn, 200, "") end)
      assert {:ok, %{}} = post(client())
    end

    test "a non-JSON 2xx body keeps the status, request id and raw body" do
      stub(fn conn ->
        conn
        |> put_resp_header("x-typesafe-request-id", "req_42")
        |> send_resp(200, "not json")
      end)

      assert {:error, error} = post(client())
      assert %Error{type: :unexpected, status: 200, body: "not json"} = error
      assert error.request_id == "req_42"
      assert error.headers["x-typesafe-request-id"] == ["req_42"]
    end

    test "a JSON array 2xx body keeps the status" do
      stub(fn conn -> send_resp(conn, 200, "[1]") end)
      assert {:error, %Error{type: :unexpected, status: 200}} = post(client())
    end
  end

  # -- 7. server errors are their own type -------------------------------------

  describe "error types" do
    test "5xx other than 503 and 529 map to :server_error" do
      for status <- [500, 502, 504, 599] do
        stub(json(status, %{"error" => "boom"}))
        assert {:error, %Error{type: :server_error, status: ^status}} = post(client())
      end
    end

    test "503 and 529 stay :overloaded" do
      for status <- [503, 529] do
        stub(json(status, %{}))
        assert {:error, %Error{type: :overloaded, status: ^status}} = post(client())
      end
    end

    test "408 is a timeout" do
      stub(json(408, %{}))
      assert {:error, %Error{type: :timeout, status: 408}} = post(client())
    end

    test "retryable?/1 matches the default retry policy status set" do
      policy = Retry.new([])

      for status <- [408, 429, 500, 503, 529, 599] do
        assert Error.retryable?(Error.from_response(Req.Response.new(status: status)))
        assert Retry.retryable?(policy, Req.Response.new(status: status))
      end

      for status <- [400, 401, 404, 422] do
        refute Error.retryable?(Error.from_response(Req.Response.new(status: status)))
        refute Retry.retryable?(policy, Req.Response.new(status: status))
      end
    end

    test "retryable?/1 covers transport errors and rejects local failures" do
      assert Error.retryable?(Error.from_exception(%Req.TransportError{reason: :timeout}))
      assert Error.retryable?(Error.from_exception(%Req.TransportError{reason: :econnrefused}))
      refute Error.retryable?(Error.validation("nope"))
      refute Error.retryable?(Error.unexpected("nope"))
    end
  end

  # -- 8. a Finch pool checkout timeout ----------------------------------------

  describe "pool checkout timeouts" do
    test "map to :timeout rather than :connection" do
      error = Error.from_exception(%Req.HTTPError{protocol: :http2, reason: :pool_timeout})
      assert %Error{type: :timeout} = error
      assert Error.retryable?(error)
    end

    # Finch does not return an error for a pool checkout timeout: it reraises a
    # bare RuntimeError, which is what this adapter reproduces, wording and all.
    @finch_message """
    Finch was unable to provide a connection within the timeout due to excess queuing \
    for connections. Consider adjusting the pool size, count, timeout or reducing the \
    rate of requests if it is possible that the downstream service is unable to keep up \
    with the current rate.
    """

    defmodule PoolTimeoutAdapter do
      @moduledoc false
      def run(request) do
        case Process.get(:pool_timeouts_left, 0) do
          n when n > 0 ->
            Process.put(:pool_timeouts_left, n - 1)
            raise Process.get(:pool_timeout_message)

          _ ->
            {request, Req.Response.new(status: 200, body: JSON.encode!(%{"ok" => true}))}
        end
      end
    end

    test "a raising Finch checkout becomes an error instead of escaping the call" do
      Process.put(:pool_timeouts_left, 1)
      Process.put(:pool_timeout_message, @finch_message)

      client =
        TypeSafeAPI.new(
          api_key: "test-key",
          retry: [max_retries: 0],
          req_options: [adapter: PoolTimeoutAdapter]
        )

      assert {:error, %Error{type: :timeout} = error} = post(client)
      assert error.message =~ "never sent"
    end

    test "a RuntimeError that is not a pool timeout still raises" do
      Process.put(:pool_timeouts_left, 1)
      Process.put(:pool_timeout_message, "something else went wrong")

      client =
        TypeSafeAPI.new(
          api_key: "test-key",
          retry: [max_retries: 0],
          req_options: [adapter: PoolTimeoutAdapter]
        )

      assert_raise RuntimeError, "something else went wrong", fn -> post(client) end
    end

    test "are retried on POST even though timeouts are not" do
      Process.put(:pool_timeouts_left, 1)
      Process.put(:pool_timeout_message, @finch_message)

      # Not the Req.Test stub: a plug: option would replace the adapter.
      client =
        TypeSafeAPI.new(
          api_key: "test-key",
          retry: Keyword.merge(fake_clock(), max_retries: 1, backoff_jitter: 0),
          req_options: [adapter: PoolTimeoutAdapter]
        )

      assert {:ok, %{"ok" => true}} = post(client)
      assert sleeps() == [500]
      assert Process.get(:pool_timeouts_left) == 0
    end
  end

  # -- 9. metadata on failures -------------------------------------------------

  describe "error metadata" do
    test "an error carries headers and the retry count" do
      stub_sequence([
        json(529, %{}, [{"retry-after-ms", "1"}]),
        json(529, %{"error" => "still overloaded"}, [{"x-typesafe-request-id", "req_7"}])
      ])

      assert {:error, error} = post(retrying_client(max_retries: 1, backoff_jitter: 0))
      assert error.retry_count == 1
      assert error.request_id == "req_7"
      assert error.headers["x-typesafe-request-id"] == ["req_7"]
    end

    test "a transport failure carries the retry count and no headers" do
      stub(transport_error(:econnrefused))

      assert {:error, error} =
               HTTP.get(retrying_client(max_retries: 1, backoff_jitter: 0), "/v1/models")

      assert error.retry_count == 1
      assert error.headers == %{}
    end

    test "Response.first_header/2 reads a single header value" do
      reply = json(200, %{})

      stub(fn conn ->
        conn |> put_resp_header("x-typesafe-request-id", "req_9") |> then(reply)
      end)

      assert {:ok, response} = HTTP.request(client(), :post, "/v1/systemone", %{})
      assert HTTP.Response.first_header(response, "x-typesafe-request-id") == "req_9"
      assert HTTP.Response.first_header(response, "x-missing") == nil
    end

    test "a Response can be built with only status and body" do
      assert %HTTP.Response{headers: %{}, request_id: nil, retry_count: 0} =
               struct!(HTTP.Response, status: 200, body: %{})
    end
  end
end
