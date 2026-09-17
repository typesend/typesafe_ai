defmodule TypeSafeAPI.TelemetryMetricsTest do
  # The ConsoleReporter attaches global handlers and reads stdout, so this
  # module runs on its own.
  use TypeSafeAPI.StubCase, async: false

  import ExUnit.CaptureIO

  @events [
    [:typesafe_api, :request, :start],
    [:typesafe_api, :request, :stop],
    [:typesafe_api, :request, :exception]
  ]

  defp evaluate(client) do
    TypeSafeAPI.evaluate(client, "hi", urgent: TypeSafeAPI.noul("Urgent?"))
  end

  defp stub_answer do
    stub(
      json(200, %{
        "model" => "jev-1",
        "answers" => %{"urgent" => %{"type" => "noul", "noul" => 0.5}},
        "usage" => %{"input_tokens" => 11, "output_tokens" => 3}
      })
    )
  end

  test "every definition points at an event this library emits" do
    metrics = TypeSafeAPI.Telemetry.metrics()

    assert length(metrics) > 6
    assert Enum.all?(metrics, &is_struct/1)

    for metric <- metrics do
      assert metric.event_name in @events,
             "#{Enum.join(metric.name, ".")} listens to #{inspect(metric.event_name)}"
    end

    names = Enum.map(metrics, &Enum.join(&1.name, "."))

    assert "typesafe_api.request.count" in names
    assert "typesafe_api.request.duration" in names
    assert "typesafe_api.request.retry_count" in names
    assert "typesafe_api.request.error.count" in names
    assert "typesafe_api.request.input_tokens" in names
    assert "typesafe_api.request.output_tokens" in names
  end

  test "duration is a distribution with buckets, which every reporter implements" do
    duration =
      TypeSafeAPI.Telemetry.metrics()
      |> Enum.find(&(Enum.join(&1.name, ".") == "typesafe_api.request.duration"))

    assert %Telemetry.Metrics.Distribution{} = duration
    assert [_ | _] = duration.reporter_options[:buckets]
  end

  test "a transport failure tags status as \"none\" rather than an empty label" do
    assert TypeSafeAPI.Telemetry.request_tags(%{status: nil}).status == "none"
    assert TypeSafeAPI.Telemetry.request_tags(%{status: 200}).status == 200
  end

  test "tag values and measurements read the metadata the library emits" do
    metadata = %{
      method: :post,
      path: "/v1/systemone",
      model: "jev-1",
      status: 200,
      retry_count: 2,
      input_tokens: 11,
      output_tokens: 3,
      error: %TypeSafeAPI.Error{type: :rate_limited, message: "slow down"}
    }

    assert TypeSafeAPI.Telemetry.retry_count(%{duration: 1}, metadata) == 2
    assert TypeSafeAPI.Telemetry.input_tokens(%{duration: 1}, metadata) == 11
    assert TypeSafeAPI.Telemetry.output_tokens(%{duration: 1}, metadata) == 3
    assert TypeSafeAPI.Telemetry.error_tags(metadata).error_type == :rate_limited
    assert TypeSafeAPI.Telemetry.error_tags(%{error: nil}).error_type == nil

    assert TypeSafeAPI.Telemetry.retry_count(%{}, %{}) == 0
    assert TypeSafeAPI.Telemetry.input_tokens(%{}, %{}) == 0
    assert TypeSafeAPI.Telemetry.output_tokens(%{}, %{}) == 0
  end

  test "a reporter sees the metrics fire after a request" do
    metrics = TypeSafeAPI.Telemetry.metrics()
    stub_answer()
    client = client()

    output =
      capture_io(fn ->
        start_supervised!({Telemetry.Metrics.ConsoleReporter, metrics: metrics})
        assert {:ok, _result} = evaluate(client)
        stop_supervised!(Telemetry.Metrics.ConsoleReporter)
      end)

    assert output =~ "Event name: typesafe_api.request.stop"
    assert output =~ "(counter)"
    assert output =~ "millisecond"
    assert output =~ "&TypeSafeAPI.Telemetry.input_tokens/2] (sum)\nWith value: 11"
    assert output =~ "&TypeSafeAPI.Telemetry.output_tokens/2] (sum)\nWith value: 3"
    assert output =~ "Tag values: %{status: 200, path: \"/v1/systemone\", method: :post}"
    # the error counter keeps only failures, so this successful call drops it
    assert output =~ "Event dropped"
  end

  test "a hand-rolled handler sees the error metric keep only failures" do
    metrics = TypeSafeAPI.Telemetry.metrics()
    errors = Enum.find(metrics, &(Enum.join(&1.name, ".") == "typesafe_api.request.error.count"))

    ok = %{method: :post, path: "/v1/systemone", error: nil}
    failed = %{ok | error: %TypeSafeAPI.Error{type: :auth, message: "bad key"}}

    refute errors.keep.(ok)
    assert errors.keep.(failed)
    assert errors.tag_values.(failed)[:error_type] == :auth
  end
end
