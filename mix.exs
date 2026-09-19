defmodule PhoenixAnalytics.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lbesecker195/Phoenix-Analytics"

  def project do
    [
      app: :phoenix_analytics_middleware,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "PhoenixAnalytics",
      description:
        "Server-side analytics middleware for Phoenix. A plug that shares one session " <>
          "with the Seriously Simple Analytics browser tag and records the traffic " <>
          "JavaScript never sees — AI agents, crawlers and API clients.",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      # inets and ssl carry the default transport. Depending on them here rather
      # than on an HTTP client keeps this library's dependency list to plug and
      # a JSON codec, which matters for something every host app installs.
      extra_applications: [:logger, :inets, :ssl],
      mod: {PhoenixAnalytics.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Seriously Simple Analytics" => "https://seriouslysimpleanalytics.com"
      },
      files: ~w(lib mix.exs README.md LICENSE NOTICE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
