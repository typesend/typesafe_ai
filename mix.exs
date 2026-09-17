defmodule TypeSafe.MixProject do
  use Mix.Project

  @version "0.1.0-alpha.1"
  @source_url "https://github.com/typesend/typesafe_ai"

  def project do
    [
      app: :typesafe_api,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "TypeSafe AI",
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:plug, "~> 1.16", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Unofficial Elixir client for the TypeSafe AI API. Not affiliated with or endorsed by TypeSafe AI."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "TypeSafe AI docs" => "https://docs.typesafe.ai"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE DESIGN.md guides)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "DESIGN.md",
        "guides/cheatsheet.cheatmd",
        "guides/speculative_fan_out.md",
        "guides/confidence_gated_routing.md",
        "guides/composite_scoring.md"
      ],
      groups_for_extras: [Guides: ~r/guides\/.*/],
      groups_for_modules: [
        "Getting started": [TypeSafe, TypeSafe.Client],
        Evaluating: [
          TypeSafe.SystemOne,
          TypeSafe.SystemOne.Prepared,
          TypeSafe.FanOut,
          TypeSafe.Models
        ],
        Questions: [
          TypeSafe.Question,
          TypeSafe.Question.Noul,
          TypeSafe.Question.Choice,
          TypeSafe.Question.Score
        ],
        Answers: [
          TypeSafe.Answer,
          TypeSafe.Answer.Noul,
          TypeSafe.Answer.Choice,
          TypeSafe.Answer.Score
        ],
        "Results and errors": [TypeSafe.Result, TypeSafe.Usage, TypeSafe.Model, TypeSafe.Error],
        "Raw HTTP, retries, telemetry": [
          TypeSafe.HTTP,
          TypeSafe.HTTP.Response,
          TypeSafe.Retry,
          TypeSafe.Telemetry
        ],
        Testing: [TypeSafe.Test],
        Internals: [TypeSafe.Keys, TypeSafe.JSON.OrderedObject]
      ]
    ]
  end
end
