defmodule TypeSafe.TelemetryLoggerTest do
  # The logger handler is global, so this module runs alone.
  use TypeSafe.StubCase, async: false

  alias TypeSafe.{HTTP, Telemetry}

  setup do
    :ok = Telemetry.attach_logger(level: :info)
    on_exit(fn -> Telemetry.detach_logger() end)
    :ok
  end

  test "logs one line per request, including errors" do
    stub(json(200, %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}}))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = HTTP.post(client(), "/v1/systemone", %{"model" => "jev-latest"})
      end)

    assert log =~ "typesafe post /v1/systemone -> 200"
    assert log =~ "model: jev-latest"

    stub(json(529, %{"error" => "overloaded"}))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:error, _} = HTTP.post(client(), "/v1/systemone", %{})
      end)

    assert log =~ "-> 529"
    assert log =~ "error: overloaded (HTTP 529): overloaded"
  end

  test "attaching twice returns an error instead of raising" do
    assert {:error, :already_exists} = Telemetry.attach_logger()
  end
end
