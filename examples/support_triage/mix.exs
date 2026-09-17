defmodule SupportTriage.MixProject do
  use Mix.Project

  def project do
    [
      app: :support_triage,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:typesafe_api, path: "../.."},
      # `TypeSafeAPI.Test` builds its stub responses with Plug.Conn. The demo task
      # falls back to those same stubs when no API key is set, so plug is needed in
      # :dev as well as :test.
      {:plug, "~> 1.16", only: [:dev, :test]}
    ]
  end
end
