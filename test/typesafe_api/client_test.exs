defmodule TypeSafeAPI.ClientTest do
  use ExUnit.Case, async: false

  alias TypeSafeAPI.{Client, Retry}

  setup do
    original = System.get_env()

    for key <- ~w(TYPESAFE_API_KEY TYPESAFE_BASE_URL TYPESAFE_DEFAULT_MODEL),
        do: System.delete_env(key)

    for key <- [:api_key, :base_url, :model, :timeout],
        do: Application.delete_env(:typesafe_api, key)

    on_exit(fn ->
      for key <- ~w(TYPESAFE_API_KEY TYPESAFE_BASE_URL TYPESAFE_DEFAULT_MODEL) do
        case Map.fetch(original, key) do
          {:ok, value} -> System.put_env(key, value)
          :error -> System.delete_env(key)
        end
      end

      for key <- [:api_key, :base_url, :model, :timeout],
          do: Application.delete_env(:typesafe_api, key)
    end)

    :ok
  end

  test "explicit options win and defaults fill the rest" do
    client = Client.new(api_key: "k", model: "jev-2", timeout: 5_000, retry: [max_retries: 9])
    assert %Client{api_key: "k", model: "jev-2", timeout: 5_000} = client
    assert client.base_url == "https://api.typesafe.ai"
    assert %Retry{max_retries: 9} = client.retry
    assert client.req_options == []
  end

  test "reads TYPESAFE_* environment variables" do
    System.put_env("TYPESAFE_API_KEY", "env-key")
    System.put_env("TYPESAFE_BASE_URL", "https://example.test/")
    System.put_env("TYPESAFE_DEFAULT_MODEL", "jev-env")

    client = Client.new()
    assert client.api_key == "env-key"
    assert client.base_url == "https://example.test"
    assert client.model == "jev-env"
    assert client.timeout == 10_000
  end

  test "application config beats environment variables" do
    System.put_env("TYPESAFE_API_KEY", "env-key")
    Application.put_env(:typesafe_api, :api_key, "app-key")
    Application.put_env(:typesafe_api, :timeout, 1_234)

    client = Client.new()
    assert client.api_key == "app-key"
    assert client.timeout == 1_234
  end

  test "blank environment variables are ignored" do
    System.put_env("TYPESAFE_API_KEY", "   ")
    assert_raise ArgumentError, ~r/no TypeSafe API key found/, fn -> Client.new() end
  end

  test "raises without an API key" do
    assert_raise ArgumentError, ~r/TYPESAFE_API_KEY/, fn -> Client.new() end
  end

  test "validates option types" do
    assert_raise NimbleOptions.ValidationError, fn -> Client.new(api_key: "k", timeout: 0) end
    assert_raise NimbleOptions.ValidationError, fn -> Client.new(api_key: "k", model: 1) end
  end

  test "accepts a prebuilt retry struct" do
    retry = Retry.new(max_retries: 1)
    assert Client.new(api_key: "k", retry: retry).retry == retry
  end

  test "inspect redacts the API key" do
    rendered = inspect(Client.new(api_key: "super-secret"))
    refute rendered =~ "super-secret"
    assert rendered =~ "[REDACTED]"
    assert rendered =~ "TypeSafeAPI.Client"
  end
end
