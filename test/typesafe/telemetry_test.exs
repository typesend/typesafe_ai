defmodule TypeSafe.TelemetryTest do
  use TypeSafe.StubCase, async: true

  alias TypeSafe.HTTP

  # Telemetry handlers are global, so every concurrently running test's
  # requests reach every handler. Each test tags its requests with a unique
  # ref and only matches events carrying that ref.
  setup do
    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      [[:typesafe, :request, :start], [:typesafe, :request, :stop]],
      &__MODULE__.forward/4,
      %{pid: test_pid, ref: ref}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{ref: ref, opts: [telemetry: %{ref: ref}]}
  end

  def forward(event, measurements, %{ref: ref} = metadata, %{pid: pid, ref: ref}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  def forward(_event, _measurements, _metadata, _config), do: :ok

  test "emits start and stop with request and usage metadata", %{opts: opts} do
    stub(
      json(200, %{
        "model" => "jev-1",
        "answers" => %{},
        "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
      })
    )

    body = %{"state" => "x", "model" => "jev-latest", "questions" => %{"a" => %{}, "b" => %{}}}
    assert {:ok, _} = HTTP.post(client(), "/v1/systemone", body, opts)

    assert_receive {:telemetry, [:typesafe, :request, :start], %{system_time: _}, start}
    assert %{method: :post, path: "/v1/systemone", model: "jev-latest", question_count: 2} = start

    assert_receive {:telemetry, [:typesafe, :request, :stop], %{duration: _}, stop}
    assert %{status: 200, retry_count: 0, input_tokens: 10, output_tokens: 2, error: nil} = stop
    assert stop.question_count == 2
  end

  test "stop metadata carries retry_count and the error", %{opts: opts} do
    stub_sequence([json(529, %{}), json(529, %{})])
    client = client(retry: Keyword.merge(fake_clock(), max_retries: 1))
    assert {:error, error} = HTTP.post(client, "/v1/systemone", %{"state" => "x"}, opts)

    assert_receive {:telemetry, [:typesafe, :request, :stop], _, stop}
    assert stop.retry_count == 1
    assert stop.status == 529
    assert stop.error == error
    assert stop.input_tokens == nil
  end

  test "atom-keyed request bodies are described too", %{opts: opts} do
    stub(json(200, %{}))
    body = %{state: "x", model: "jev-x", questions: %{a: %{}}}
    assert {:ok, _} = HTTP.post(client(), "/v1/systemone", body, opts)

    assert_receive {:telemetry, [:typesafe, :request, :start], _,
                    %{model: "jev-x", question_count: 1}}
  end
end
