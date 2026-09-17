defmodule TypeSafeAPI.TestRecorderTest do
  use ExUnit.Case, async: true

  defmodule FakeAdapter do
    @moduledoc false
    # Stands in for Req.Finch: a client with no plug is recorded by wrapping
    # whatever adapter it has.

    def run(request) do
      send(
        self(),
        {:adapter_saw, Req.Request.get_header(request, "authorization"),
         Req.Request.get_header(request, "x-typesafe-record-to"),
         Req.Request.get_header(request, "x-typesafe-record-adapter")}
      )

      {request, models_response(200)}
    end

    @doc false
    def models_response(status) do
      Req.Response.new(
        status: status,
        headers: [
          {"content-type", "application/json"},
          {"x-typesafe-request-id", "req_123"},
          {"set-cookie", "session=nope"}
        ],
        body:
          JSON.encode!(%{
            "models" => [%{"name" => "jev-9", "description" => "", "release_date" => "2026-01-01"}]
          })
      )
    end
  end

  defmodule FlakyAdapter do
    @moduledoc false
    # Fails once, then succeeds. Runs in the calling process, so the attempt
    # counter can live in its process dictionary.

    def run(request) do
      attempt = Process.get(:flaky_attempts, 0)
      Process.put(:flaky_attempts, attempt + 1)

      send(
        self(),
        {:flaky_attempt, attempt, Req.Request.get_header(request, "x-typesafe-record-to"),
         Req.Request.get_header(request, "authorization")}
      )

      status = if attempt == 0, do: 500, else: 200
      {request, FakeAdapter.models_response(status)}
    end
  end

  alias TypeSafeAPI.Result

  @moduletag :tmp_dir

  setup :typesafe_stubs

  defp typesafe_stubs(context), do: TypeSafeAPI.Test.typesafe_stubs(context)

  defp questions do
    [
      urgent: TypeSafeAPI.noul("Urgent?"),
      dept: TypeSafeAPI.choice("Team?", billing: "b", technical: "t"),
      anger: TypeSafeAPI.score("Anger?", ["Calm", "Frustrated", "Very angry"])
    ]
  end

  defp recording_client(path) do
    TypeSafeAPI.Test.client()
    |> TypeSafeAPI.Test.stub(
      urgent: {:noul, 0.3},
      dept: {:choice, :billing, 0.9},
      anger: {:score, 2, 0.8}
    )
    |> TypeSafeAPI.Test.record(path)
  end

  # A fixture is JSON Lines: one entry per line.
  defp entries(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  test "records a live run and replays it into an identical result", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "triage.jsonl")

    assert {:ok, %Result{} = recorded} =
             TypeSafeAPI.evaluate(recording_client(path), "Where is my refund?", questions())

    assert [entry] = entries(path)
    assert entry["request"]["method"] == "POST"
    assert entry["request"]["path"] == "/v1/systemone"
    assert entry["request"]["body"]["state"] == "Where is my refund?"
    assert entry["response"]["status"] == 200
    assert entry["response"]["headers"]["content-type"] =~ "application/json"
    assert entry["response"]["body"]["answers"]["dept"]["choice"] == "billing"

    assert {:ok, %Result{} = replayed} =
             TypeSafeAPI.evaluate(
               TypeSafeAPI.Test.replay(path),
               "Where is my refund?",
               questions()
             )

    assert replayed == recorded
  end

  test "the fixture holds one self-contained JSON object per line", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "lines.jsonl")
    client = recording_client(path)

    assert {:ok, _} = TypeSafeAPI.evaluate(client, "one", questions())
    assert {:ok, _} = TypeSafeAPI.evaluate(client, "two", questions())

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2
    assert Enum.all?(lines, &match?({:ok, %{"request" => _}}, JSON.decode(&1)))
  end

  test "appends one entry per call and serves repeats in order", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "models.jsonl")
    client = TypeSafeAPI.Test.client()

    TypeSafeAPI.Test.stub_models(client, [%{name: "jev-1"}])
    assert {:ok, _} = TypeSafeAPI.models(TypeSafeAPI.Test.record(client, path))

    TypeSafeAPI.Test.stub_models(client, [%{name: "jev-2"}])
    assert {:ok, _} = TypeSafeAPI.models(TypeSafeAPI.Test.record(client, path))

    assert length(entries(path)) == 2

    replay = TypeSafeAPI.Test.replay(path)
    assert {:ok, [%TypeSafeAPI.Model{name: "jev-1"}]} = TypeSafeAPI.models(replay)
    assert {:ok, [%TypeSafeAPI.Model{name: "jev-2"}]} = TypeSafeAPI.models(replay)
  end

  test "body-agnostic replay serves recordings in the order they were written", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "sequence.jsonl")
    client = TypeSafeAPI.Test.client()

    for probability <- [0.1, 0.2, 0.3] do
      TypeSafeAPI.Test.stub(client, urgent: {:noul, probability})

      assert {:ok, _} =
               TypeSafeAPI.evaluate(TypeSafeAPI.Test.record(client, path), "state #{probability}",
                 urgent: TypeSafeAPI.noul("?")
               )
    end

    replay = TypeSafeAPI.Test.replay(path, match: [:method, :path])

    nouls =
      for _ <- 1..3 do
        {:ok, result} = TypeSafeAPI.evaluate(replay, "anything", urgent: TypeSafeAPI.noul("?"))
        result.answers.urgent.noul
      end

    assert nouls == [0.1, 0.2, 0.3]
  end

  test "a concurrent fan-out records every call and replays each state to its own answers", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "fan.jsonl")
    states = for i <- 1..5, do: "state #{i}"

    client =
      TypeSafeAPI.Test.client()
      |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.3})
      |> TypeSafeAPI.Test.record(path)

    recorded = TypeSafeAPI.evaluate_many(client, states, urgent: TypeSafeAPI.noul("Urgent?"))
    assert length(recorded) == 5
    assert Enum.all?(recorded, &match?({:ok, _}, &1))

    # No entry was lost or half-written by the concurrent appends.
    assert length(entries(path)) == 5

    replayed =
      TypeSafeAPI.evaluate_many(TypeSafeAPI.Test.replay(path), states,
        urgent: TypeSafeAPI.noul("Urgent?")
      )

    assert replayed == recorded
  end

  test "a 4xx response is recorded and replayed", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "error.jsonl")

    client =
      TypeSafeAPI.Test.client()
      |> TypeSafeAPI.Test.stub_error(422, %{"detail" => "nope"})
      |> TypeSafeAPI.Test.record(path)

    assert {:error, %TypeSafeAPI.Error{type: :validation, message: "nope"}} =
             TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("?"))

    assert [%{"response" => %{"status" => 422}}] = entries(path)

    assert {:error, %TypeSafeAPI.Error{type: :validation, status: 422, message: "nope"}} =
             TypeSafeAPI.evaluate(TypeSafeAPI.Test.replay(path), "hi",
               urgent: TypeSafeAPI.noul("?")
             )
  end

  test "a request with no recording names the closest recording and the first difference", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "triage.jsonl")

    assert {:ok, _} =
             TypeSafeAPI.evaluate(recording_client(path), "Where is my refund?", questions())

    client = TypeSafeAPI.Test.replay(path)

    error =
      assert_raise ArgumentError, ~r/no recording in .* matches this request/s, fn ->
        TypeSafeAPI.evaluate(client, "Something else entirely", questions())
      end

    message = Exception.message(error)
    assert message =~ "Closest unserved recording"
    assert message =~ "POST /v1/systemone"
    assert message =~ ~s(first difference: "state")
    assert message =~ "Where is my refund?"
  end

  test "match: [:method, :path] ignores the body", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "triage.jsonl")

    assert {:ok, recorded} =
             TypeSafeAPI.evaluate(recording_client(path), "Where is my refund?", questions())

    client = TypeSafeAPI.Test.replay(path, match: [:method, :path])

    assert {:ok, replayed} =
             TypeSafeAPI.evaluate(client, "A completely different message", questions())

    assert replayed == recorded
  end

  test "replay rejects an unknown match key", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "triage.jsonl")
    assert {:ok, _} = TypeSafeAPI.evaluate(recording_client(path), "hi", questions())

    assert_raise ArgumentError, ~r/:match must be a non-empty subset/, fn ->
      TypeSafeAPI.Test.replay(path, match: [:headers])
    end
  end

  test "replay explains a missing fixture", %{tmp_dir: tmp_dir} do
    assert_raise ArgumentError, ~r/cannot read .* Record it with TypeSafeAPI.Test.record/s, fn ->
      TypeSafeAPI.Test.replay(Path.join(tmp_dir, "nope.jsonl"))
    end
  end

  test "replay still reads a fixture written as a JSON array", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "legacy.json")

    File.write!(
      path,
      JSON.encode!([
        %{
          "request" => %{"method" => "GET", "path" => "/v1/models", "body" => nil},
          "response" => %{
            "status" => 200,
            "headers" => %{"content-type" => "application/json"},
            "body" => %{"models" => [%{"name" => "jev-legacy"}]}
          }
        }
      ])
    )

    assert {:ok, [%TypeSafeAPI.Model{name: "jev-legacy"}]} =
             TypeSafeAPI.models(TypeSafeAPI.Test.replay(path))
  end

  test "no secret reaches the fixture", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "secrets.jsonl")

    client =
      TypeSafeAPI.Test.client(api_key: "sk-super-secret-42")
      |> TypeSafeAPI.Test.stub(urgent: {:noul, 0.3})
      |> TypeSafeAPI.Test.record(path)

    assert {:ok, _} = TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("Urgent?"))

    contents = File.read!(path)
    refute contents =~ "sk-super-secret-42"
    refute String.downcase(contents) =~ "authorization"
    refute String.downcase(contents) =~ "bearer"
    refute String.downcase(contents) =~ "api_key"
    assert [%{"request" => request}] = entries(path)
    assert request |> Map.keys() |> Enum.sort() == ["body", "method", "path"]
  end

  test "records a client that has no plug by wrapping its adapter", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "models.jsonl")

    client =
      TypeSafeAPI.new(
        api_key: "sk-secret",
        retry: [max_retries: 0],
        req_options: [adapter: FakeAdapter]
      )

    assert {:ok, [%TypeSafeAPI.Model{name: "jev-9"}]} =
             TypeSafeAPI.models(TypeSafeAPI.Test.record(client, path))

    # the recorder strips its own headers before the real adapter runs
    assert_received {:adapter_saw, [_authorization], [], []}

    assert [entry] = entries(path)
    assert entry["request"] == %{"method" => "GET", "path" => "/v1/models", "body" => nil}
    assert entry["response"]["status"] == 200

    assert entry["response"]["headers"] == %{
             "content-type" => "application/json",
             "x-typesafe-request-id" => "req_123"
           }

    refute File.read!(path) =~ "sk-secret"
    refute File.read!(path) =~ "set-cookie"

    assert {:ok, [%TypeSafeAPI.Model{name: "jev-9"}]} =
             TypeSafeAPI.models(TypeSafeAPI.Test.replay(path))
  end

  test "a retried recording stays on the wrapped adapter and records both attempts", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "flaky.jsonl")

    client =
      TypeSafeAPI.new(
        api_key: "sk-secret",
        retry: [max_retries: 2, backoff_initial: 0, backoff_max: 0],
        req_options: [adapter: FlakyAdapter]
      )

    assert {:ok, [%TypeSafeAPI.Model{name: "jev-9"}]} =
             TypeSafeAPI.models(TypeSafeAPI.Test.record(client, path))

    # Both attempts went through the wrapped adapter, and neither carried the
    # recorder's own headers on to it.
    assert_received {:flaky_attempt, 0, [], [_auth]}
    assert_received {:flaky_attempt, 1, [], [_auth]}
    refute_received {:flaky_attempt, 2, _, _}

    assert [%{"response" => %{"status" => 500}}, %{"response" => %{"status" => 200}}] =
             entries(path)
  end

  test "record/2 refuses an adapter it cannot name" do
    client = TypeSafeAPI.new(api_key: "k", req_options: [adapter: fn request -> request end])

    assert_raise ArgumentError, ~r/can only wrap an adapter module/, fn ->
      TypeSafeAPI.Test.record(client, "unused.jsonl")
    end
  end
end
