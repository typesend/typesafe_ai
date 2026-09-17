defmodule TypeSafeAPI.MixProject do
  use Mix.Project

  @version "0.1.0-alpha.2"
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
    [extra_applications: [:logger], mod: {TypeSafeAPI.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:plug, "~> 1.16", optional: true},
      {:telemetry_metrics, "~> 1.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Typed Elixir client for TypeSafe AI and its Jev System One model, with offline test " <>
      "stubs, concurrent fan-out, and atom-keyed answers. Unofficial; not affiliated with " <>
      "TypeSafe AI."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "TypeSafe AI docs" => "https://docs.typesafe.ai"},
      files:
        ~w(lib priv/openapi.json mix.exs README.md CHANGELOG.md LICENSE DESIGN.md guides livebooks)
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
        "guides/getting_started.md",
        "guides/errors_and_retries.md",
        "guides/configuration_and_concurrency.md",
        "guides/system_one.md",
        "guides/live_dashboard.md",
        "guides/broadway_and_oban.md",
        "guides/cheatsheet.cheatmd",
        "guides/speculative_fan_out.md",
        "guides/confidence_gated_routing.md",
        "guides/composite_scoring.md",
        "livebooks/live_walkthrough.livemd",
        "examples/support_triage/README.md": [
          title: "Support triage example",
          filename: "support_triage_example"
        ]
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/,
        Livebooks: ~r/livebooks\/.*/,
        Examples: ~r/examples\/.*/
      ],
      groups_for_modules: [
        "Getting started": [TypeSafeAPI, TypeSafeAPI.Client],
        Evaluating: [
          TypeSafeAPI.SystemOne,
          TypeSafeAPI.SystemOne.Prepared,
          TypeSafeAPI.FanOut,
          TypeSafeAPI.Models
        ],
        Questions: [
          TypeSafeAPI.Question,
          TypeSafeAPI.Question.Noul,
          TypeSafeAPI.Question.Choice,
          TypeSafeAPI.Question.Score
        ],
        Answers: [
          TypeSafeAPI.Answer,
          TypeSafeAPI.Answer.Noul,
          TypeSafeAPI.Answer.Choice,
          TypeSafeAPI.Answer.Score
        ],
        "Results and errors": [
          TypeSafeAPI.Result,
          TypeSafeAPI.Usage,
          TypeSafeAPI.Model,
          TypeSafeAPI.Error
        ],
        "Raw HTTP, retries, telemetry": [
          TypeSafeAPI.HTTP,
          TypeSafeAPI.HTTP.Response,
          TypeSafeAPI.Retry,
          TypeSafeAPI.Telemetry
        ],
        Testing: [TypeSafeAPI.Test],
        Internals: [
          TypeSafeAPI.Application,
          TypeSafeAPI.Keys,
          TypeSafeAPI.JSON.OrderedObject
        ]
      ]
    ]
  end
end
