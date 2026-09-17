defmodule SupportTriage.Demo do
  @moduledoc """
  Runs `SupportTriage.triage/2` over a handful of sample messages and prints
  what it decided.

  With `TYPESAFE_API_KEY` set the demo calls the real API. Without one it runs
  against `TypeSafeAPI.Test` stubs, so it works on a laptop with no key and in CI
  with no secrets. Each sample carries the stub answers used in offline mode;
  they are ignored when a key is present.
  """

  alias TypeSafeAPI.Test

  @samples [
    {"The payouts API has returned 500 for every call since 09:00. We are down.",
     [urgent: {:noul, 0.96}, dept: {:choice, :technical, 0.91}, frustration: {:score, 2, 0.84}]},
    {"Could you send me a copy of last month's invoice when you get a chance?",
     [urgent: {:noul, 0.04}, dept: {:choice, :billing, 0.93}, frustration: {:score, 0, 0.9}]},
    {"What does the Enterprise plan include? We are comparing options for Q3.",
     [urgent: {:noul, 0.06}, dept: {:choice, :sales, 0.88}, frustration: {:score, 0, 0.86}]},
    {"My card was charged twice and the dashboard is also throwing an error.",
     [urgent: {:noul, 0.71}, dept: {:choice, :billing, 0.44}, frustration: {:score, 1, 0.61}]}
  ]

  @doc "Prints one line per sample message. Returns `:ok`."
  @spec run() :: :ok
  def run do
    {client, mode} = client()
    IO.puts("mode: #{mode}\n")

    Enum.each(@samples, fn {message, stubs} ->
      client = maybe_stub(client, mode, stubs)
      IO.puts(message)
      IO.puts("  -> " <> SupportTriage.describe(SupportTriage.triage(client, message)) <> "\n")
    end)
  end

  @doc "The sample messages, paired with the stub answers used offline."
  @spec samples() :: [{String.t(), keyword()}]
  def samples, do: @samples

  defp client do
    case System.get_env("TYPESAFE_API_KEY") do
      nil -> {Test.client(), :stubs}
      key -> {TypeSafeAPI.new(api_key: key), :live}
    end
  end

  defp maybe_stub(client, :stubs, stubs), do: Test.stub(client, stubs)
  defp maybe_stub(client, :live, _stubs), do: client
end
