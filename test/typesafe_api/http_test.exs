defmodule TypeSafeAPI.HTTPTest do
  use TypeSafeAPI.StubCase, async: true

  alias TypeSafeAPI.{Error, HTTP}

  @ok_body %{
    "model" => "jev-1",
    "answers" => %{},
    "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
  }

  describe "post/4 request shape" do
    test "sends bearer auth, user agent, JSON content type and the encoded body" do
      test_pid = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn, raw})
        json(200, @ok_body).(conn)
      end)

      assert {:ok, @ok_body} = HTTP.post(client(), "/v1/systemone", %{"state" => "hi"})
      assert_receive {:request, conn, raw}

      assert get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert get_req_header(conn, "user-agent") == [HTTP.user_agent()]
      assert HTTP.user_agent() == "typesafe_api/#{Mix.Project.config()[:version]} (Elixir)"
      assert get_req_header(conn, "content-type") == ["application/json"]
      assert get_req_header(conn, "accept") == ["application/json"]
      assert conn.method == "POST"
      assert conn.request_path == "/v1/systemone"
      assert JSON.decode!(raw) == %{"state" => "hi"}
    end

    test "get/3 sends no body" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:method, conn.method, conn.request_path})
        json(200, %{"models" => []}).(conn)
      end)

      assert {:ok, %{"models" => []}} = HTTP.get(client(), "/v1/models")
      assert_receive {:method, "GET", "/v1/models"}
    end

    test "respects a custom base_url path prefix" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:host, conn.host, conn.request_path})
        json(200, %{}).(conn)
      end)

      client = client(base_url: "https://proxy.example.com/typesafe/")
      assert {:ok, %{}} = HTTP.post(client, "/v1/systemone", %{})
      assert_receive {:host, "proxy.example.com", "/typesafe/v1/systemone"}
    end

    test "per-call req_options are merged" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:header, get_req_header(conn, "x-extra")})
        json(200, %{}).(conn)
      end)

      opts = [req_options: [headers: [x_extra: "yes"]]]
      assert {:ok, %{}} = HTTP.post(client(), "/v1/systemone", %{}, opts)
      assert_receive {:header, ["yes"]}
    end
  end

  describe "raw questions (README: Raw questions and unknown question types)" do
    test "post/4 against SystemOne.path/0 round-trips an unmodeled question type" do
      stub(
        json(200, %{
          "model" => "jev-1",
          "answers" => %{"region" => %{"type" => "bounding_box", "box" => [0, 0, 1, 1]}},
          "usage" => %{}
        })
      )

      client = client()

      {:ok, raw} =
        TypeSafeAPI.HTTP.post(client, TypeSafeAPI.SystemOne.path(), %{
          "state" => "A photo of a storefront.",
          "model" => client.model,
          "questions" => %{
            "region" => %{"type" => "bounding_box", "instructions" => "The storefront sign"}
          }
        })

      assert raw["answers"]["region"]["type"] == "bounding_box"
      assert raw["answers"]["region"]["box"] == [0, 0, 1, 1]
    end
  end

  describe "request/5" do
    test "returns the full response with request_id, headers, and retry count" do
      stub(json(200, @ok_body, [{"x-typesafe-request-id", "req_abc"}]))

      assert {:ok, %TypeSafeAPI.HTTP.Response{} = response} =
               HTTP.request(client(), :post, "/v1/systemone", %{"state" => "x"})

      assert response.status == 200
      assert response.body == @ok_body
      assert response.request_id == "req_abc"
      assert response.retry_count == 0
      assert response.headers["x-typesafe-request-id"] == ["req_abc"]
    end

    test "request_id is nil when the header is absent" do
      stub(json(200, @ok_body))

      assert {:ok, %TypeSafeAPI.HTTP.Response{request_id: nil}} =
               HTTP.request(client(), :get, "/v1/models", nil)
    end
  end

  describe "build/5" do
    test "applies the client timeout and per-call overrides" do
      request = HTTP.build(client(timeout: 1_234), :post, "/v1/systemone", %{})
      assert request.options.receive_timeout == 1_234

      request = HTTP.build(client(), :post, "/v1/systemone", %{}, timeout: 99)
      assert request.options.receive_timeout == 99
      assert request.options.retry == false
    end

    test "every call from one client resolves to the same Finch pool" do
      client = client()

      pool_names =
        for {path, opts} <- [
              {"/v1/systemone", []},
              {"/v1/systemone", [timeout: 25]},
              {"/v1/models", [timeout: 90_000, retry: [max_retries: 0]]}
            ] do
          request = HTTP.build(client, :post, path, %{}, opts)
          request.options |> Req.Finch.pool_options() |> Req.Finch.pool_name()
        end

      assert [name, name, name] = pool_names

      other = HTTP.build(client(connect_timeout: 750), :post, "/v1/systemone", %{})
      refute other.options |> Req.Finch.pool_options() |> Req.Finch.pool_name() == name
    end

    test "the per-call timeout does not change the connection pool" do
      client = client()

      slow = HTTP.build(client, :post, "/v1/systemone", %{}, timeout: 1_000)
      fast = HTTP.build(client, :post, "/v1/systemone", %{}, timeout: 25)

      assert slow.options.receive_timeout == 1_000
      assert fast.options.receive_timeout == 25
      assert slow.options.connect_options == fast.options.connect_options
      assert slow.options.connect_options == [timeout: 5_000]
    end

    test "connect_timeout is a client setting" do
      request = HTTP.build(client(connect_timeout: 750), :get, "/v1/models", nil, timeout: 1)
      assert request.options.connect_options == [timeout: 750]
      assert request.options.receive_timeout == 1
    end
  end

  describe "error mapping" do
    test "401 -> :auth" do
      stub(json(401, %{"error" => "invalid api key"}))
      assert {:error, %Error{type: :auth, status: 401, message: "invalid api key"}} = post()
    end

    test "400 -> :validation, reading the live API's detail.message shape" do
      stub(
        json(400, %{
          "detail" => %{"error_type" => "api_usage_error", "message" => "Unknown model: jev"}
        })
      )

      assert {:error, %Error{type: :validation, status: 400, message: "Unknown model: jev"}} =
               post()

      stub(json(400, %{"detail" => "Too many choices. Must have at most 255 choices."}))
      assert {:error, %Error{type: :validation, message: "Too many choices" <> _}} = post()
    end

    test "422 -> :validation with the offending field in the message" do
      stub(
        json(422, %{
          "detail" => [
            %{
              "loc" => ["body", "questions", "dept", "criteria"],
              "msg" => "field required",
              "type" => "missing"
            }
          ]
        })
      )

      assert {:error, %Error{type: :validation, status: 422, message: message, body: body}} = post()
      assert message == "body.questions.dept.criteria: field required"
      assert %{"detail" => [_]} = body
    end

    test "429 -> :rate_limited with retry_after_ms and request id" do
      stub(
        json(429, %{"error" => "slow down"}, [
          {"retry-after", "3"},
          {"x-typesafe-request-id", "req_123"}
        ])
      )

      assert {:error, error} = post()

      assert %Error{type: :rate_limited, status: 429, retry_after_ms: 3000, request_id: "req_123"} =
               error

      assert Exception.message(error) == "rate_limited (HTTP 429): slow down"
    end

    test "529 -> :overloaded" do
      stub(json(529, %{"message" => "overloaded"}))
      assert {:error, %Error{type: :overloaded, status: 529, message: "overloaded"}} = post()
    end

    test "unknown status -> :unexpected with a default message" do
      stub(fn conn -> send_resp(conn, 418, "") end)

      assert {:error, %Error{type: :unexpected, status: 418, message: "Unexpected HTTP status 418"}} =
               post()
    end

    test "non-JSON error body is kept as a string" do
      stub(fn conn -> send_resp(conn, 500, "<html>boom</html>") end)

      assert {:error, %Error{type: :server_error, status: 500, message: "<html>boom</html>"}} =
               post()
    end

    test "a long error body is truncated in the message but kept whole in body" do
      page = "<html>" <> String.duplicate("x", 5_000) <> "</html>"
      stub(fn conn -> send_resp(conn, 502, page) end)

      assert {:error, %Error{type: :server_error, status: 502, message: message, body: body}} =
               post()

      assert body == page
      assert byte_size(message) < 600
      assert String.starts_with?(message, "<html>xxx")
      assert String.ends_with?(message, "(#{byte_size(page)} bytes, see body)")
    end

    test "2xx with invalid JSON -> :unexpected" do
      stub(fn conn -> send_resp(conn, 200, "not json") end)
      assert {:error, %Error{type: :unexpected, status: 200, body: "not json"}} = post()
    end

    test "2xx with a JSON array -> :unexpected" do
      stub(fn conn -> send_resp(conn, 200, "[1]") end)
      assert {:error, %Error{type: :unexpected}} = post()
    end

    test "connection refused -> :connection" do
      stub(transport_error(:econnrefused))
      assert {:error, %Error{type: :connection, status: nil}} = post()
    end

    test "timeout -> :timeout" do
      stub(transport_error(:timeout))
      assert {:error, %Error{type: :timeout, status: nil}} = post()
    end
  end

  defp post, do: HTTP.post(client(), "/v1/systemone", %{"state" => "x"})
end
