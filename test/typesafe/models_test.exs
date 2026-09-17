defmodule TypeSafe.ModelsTest do
  use TypeSafe.StubCase, async: true

  alias TypeSafe.{Error, Model}

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

    assert {:ok, [first, second, third]} = TypeSafe.models(client())
    assert_receive {:request, "GET", "/v1/models"}

    assert first == %Model{
             name: "jev-1.13.0",
             description: "Flagship",
             release_date: ~D[2026-03-01]
           }

    assert second.release_date == "latest"
    assert third.release_date == ~U[2026-09-10 18:39:06.057655Z]
  end

  test "malformed bodies are :unexpected errors" do
    stub(json(200, %{"data" => []}))
    assert {:error, %Error{type: :unexpected}} = TypeSafe.models(client())

    stub(json(200, %{"models" => [%{"description" => "no name"}]}))
    assert {:error, %Error{type: :unexpected}} = TypeSafe.models(client())
  end

  test "HTTP errors pass through" do
    stub(json(401, %{"error" => "nope"}))
    assert {:error, %Error{type: :auth}} = TypeSafe.models(client())
  end
end
