defmodule TypeSafeAPI.ModelsTest do
  use TypeSafeAPI.StubCase, async: true

  alias TypeSafeAPI.{Error, Model}

  test "lists models from GET /v1/models" do
    test_pid = self()

    stub(fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})

      json(200, %{
        "models" => [
          %{"name" => "jev-1.13.0", "description" => "Flagship", "release_date" => "2026-03-01"},
          %{"name" => "jev-latest", "description" => "Alias", "release_date" => "latest"},
          %{
            "name" => "jev-preview",
            "description" => "Preview",
            "release_date" => "2026-09-10T18:39:06.057655+00:00"
          }
        ]
      }).(conn)
    end)

    assert {:ok, [first, second, third]} = TypeSafeAPI.models(client())
    assert_receive {:request, "GET", "/v1/models"}

    assert first.name == "jev-1.13.0"
    assert first.description == "Flagship"
    assert first.release_date == ~D[2026-03-01]
    assert first.release_date_raw == "2026-03-01"

    assert second.release_date == nil
    assert second.release_date_raw == "latest"
    assert third.release_date == ~D[2026-09-10]
  end

  test "a malformed entry is skipped, warned about, and the rest are returned" do
    stub(
      json(200, %{
        "models" => [
          %{"name" => "jev-1.13.0"},
          %{"description" => "no name"},
          %{"name" => "jev-latest"}
        ]
      })
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, models} = TypeSafeAPI.models(client())
        assert Enum.map(models, & &1.name) == ["jev-1.13.0", "jev-latest"]
      end)

    assert log =~ "no name"
    assert log =~ "skipping"
  end

  test "a body with no models array is an :unexpected error" do
    stub(json(200, %{"data" => []}))
    assert {:error, %Error{type: :unexpected}} = TypeSafeAPI.models(client())
  end

  test "an unknown per-call option is a :validation error, not a silent no-op" do
    stub(fn _conn -> flunk("no request expected") end)

    assert {:error, %Error{type: :validation, message: message}} =
             TypeSafeAPI.models(client(), timout: 500)

    assert message =~ "timout"
  end

  test "models!/1 returns the list or raises the error" do
    stub(json(200, %{"models" => [%{"name" => "jev-latest"}]}))
    assert [%Model{name: "jev-latest"}] = TypeSafeAPI.models!(client())

    stub(json(401, %{"error" => "nope"}))
    assert_raise Error, "auth (HTTP 401): nope", fn -> TypeSafeAPI.models!(client()) end
  end

  test "HTTP errors pass through" do
    stub(json(401, %{"error" => "nope"}))
    assert {:error, %Error{type: :auth}} = TypeSafeAPI.models(client())
  end
end
