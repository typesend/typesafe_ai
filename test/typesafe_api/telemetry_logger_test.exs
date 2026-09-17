defmodule TypeSafeAPI.TelemetryLoggerTest do
  # The logger handler is global, so this module runs alone.
  use TypeSafeAPI.StubCase, async: false

  import ExUnit.CaptureLog

  alias TypeSafeAPI.{HTTP, Telemetry}

  setup do
    :ok = Telemetry.attach_logger(level: :info)
    on_exit(fn -> Telemetry.detach_logger() end)
    :ok
  end

  test "logs one line per request, including errors" do
    stub(json(200, %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}}))

    log =
      capture_log(fn ->
        {:ok, _} = HTTP.post(client(), "/v1/systemone", %{"model" => "jev-latest"})
      end)

    assert log =~ "typesafe post /v1/systemone -> 200"
    assert log =~ "model: jev-latest"

    stub(json(529, %{"error" => "overloaded"}))

    log =
      capture_log(fn ->
        {:error, _} = HTTP.post(client(), "/v1/systemone", %{})
      end)

    assert log =~ "-> 529"
    assert log =~ "error: overloaded (HTTP 529): overloaded"
  end

  test "failures are logged at :warning, not at the success level" do
    stub(json(529, %{"error" => "overloaded"}))

    log = capture_log([level: :warning], fn -> {:error, _} = post() end)
    assert log =~ "[warning]"
    assert log =~ "-> 529"
  end

  test "successes stay at the success level, so a :warning logger stays quiet" do
    stub(json(200, %{}))

    log = capture_log([level: :warning], fn -> {:ok, _} = post() end)
    assert log == ""
  end

  test "error_level is configurable" do
    :ok = Telemetry.attach_logger(level: :info, error_level: :error)
    stub(json(529, %{}))

    log = capture_log(fn -> {:error, _} = post() end)
    assert log =~ "[error]"
  end

  test "attaching twice replaces the handler rather than keeping the old levels" do
    assert :ok = Telemetry.attach_logger(level: :debug, error_level: :error)
    stub(json(529, %{}))

    log = capture_log(fn -> {:error, _} = post() end)
    assert log =~ "[error]"
  end

  test "warn is accepted as :warning and unknown levels raise" do
    assert :ok = Telemetry.attach_logger(level: :warn, error_level: "warn")
    stub(json(200, %{}))

    log = capture_log([level: :warning], fn -> {:ok, _} = post() end)
    assert log =~ "[warning]"

    assert_raise ArgumentError, ~r/:level must be a Logger level/, fn ->
      Telemetry.attach_logger(level: :chatty)
    end

    assert_raise ArgumentError, ~r/:error_level must be a Logger level/, fn ->
      Telemetry.attach_logger(error_level: "loud")
    end
  end

  test "an unusable TYPESAFE_LOG_LEVEL raises instead of silently logging everything" do
    System.put_env("TYPESAFE_LOG_LEVEL", "warn")
    on_exit(fn -> System.delete_env("TYPESAFE_LOG_LEVEL") end)

    assert :ok = Telemetry.attach_logger()
    stub(json(200, %{}))
    assert capture_log([level: :warning], fn -> {:ok, _} = post() end) =~ "[warning]"

    System.put_env("TYPESAFE_LOG_LEVEL", "loud")

    assert_raise ArgumentError, ~r/TYPESAFE_LOG_LEVEL/, fn -> Telemetry.attach_logger() end
  end

  defp post, do: HTTP.post(client(), "/v1/systemone", %{})
end
