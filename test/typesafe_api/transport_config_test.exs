defmodule TypeSafeAPI.TransportConfigTest do
  @moduledoc """
  The transport regressions that touch global state: application config, and a
  telemetry handler that would otherwise see every other test's requests.
  """

  use TypeSafeAPI.StubCase, async: false

  alias TypeSafeAPI.Client

  defp post(client), do: TypeSafeAPI.HTTP.post(client, "/v1/systemone", %{"state" => "x"})

  # -- 10. app config is validated like anything else ---------------------------

  describe "application config" do
    setup do
      on_exit(fn ->
        for key <- [:base_url, :model, :timeout, :connect_timeout, :finch],
            do: Application.delete_env(:typesafe_api, key)
      end)
    end

    test "a non-string base_url fails at new/1, naming the config key" do
      Application.put_env(:typesafe_api, :base_url, :production)

      assert_raise ArgumentError, ~r/config :typesafe_api, base_url: must be a string/, fn ->
        Client.new(api_key: "k")
      end
    end

    test "a bad connect_timeout names connect_timeout, not timeout" do
      Application.put_env(:typesafe_api, :connect_timeout, -1)

      assert_raise ArgumentError,
                   ~r/config :typesafe_api, connect_timeout: must be a positive integer/,
                   fn -> Client.new(api_key: "k") end
    end

    test "a non-atom finch fails at new/1" do
      Application.put_env(:typesafe_api, :finch, "MyApp.Finch")

      assert_raise ArgumentError, ~r/config :typesafe_api, finch: must be an atom/, fn ->
        Client.new(api_key: "k")
      end
    end

    test "blank and padded config values are trimmed like env values" do
      Application.put_env(:typesafe_api, :base_url, "  ")
      Application.put_env(:typesafe_api, :model, "  jev-7  ")

      client = Client.new(api_key: "k")
      assert client.base_url == "https://api.typesafe.ai"
      assert client.model == "jev-7"
    end
  end

  # -- 11. telemetry token values are decoded -----------------------------------

  describe "telemetry usage" do
    @doc false
    def send_metadata(_event, _measurements, metadata, pid), do: send(pid, {:usage, metadata})

    test "token counts go through Usage.decode, so a handler never sees a float" do
      stub(json(200, %{"ok" => true, "usage" => %{"input_tokens" => 11.0, "output_tokens" => 3}}))

      :telemetry.attach(
        "transport-usage-test",
        [:typesafe_api, :request, :stop],
        &__MODULE__.send_metadata/4,
        self()
      )

      on_exit(fn -> :telemetry.detach("transport-usage-test") end)

      assert {:ok, _} = post(client())
      assert_receive {:usage, metadata}
      assert metadata.input_tokens == nil
      assert metadata.output_tokens == 3
    end
  end
end
