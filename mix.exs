defmodule HammerBackendRedis.Mixfile do
  use Mix.Project

  @version "6.1.2"

  def project do
    [
      app: :hammer_backend_redis,
      description: "Redis backend for Hammer rate-limiter",
      source_url: "https://github.com/ExHammer/hammer-backend-redis",
      homepage_url: "https://github.com/ExHammer/hammer-backend-redis",
      version: "#{@version}",
      elixir: "~> 1.12",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      test_coverage: [summary: [threshold: 75]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def docs do
    [
      main: "overview",
      extras: ["guides/Overview.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      main: "overview",
      formatters: ["html", "epub"]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.6", only: [:dev, :test]},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.28", only: :dev},
      {:hammer, "~> 6.0"},
      {:mock, "~> 0.3.7", only: :test},
      {:redix, "~> 1.1"}
    ]
  end

  defp package do
    [
      name: :hammer_backend_redis,
      maintainers: ["Emmanuel Pinault", "Shane Kilkelly (shane@kilkelly.me)"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/ExHammer/hammer-backend-redis",
        "Changelog" => "https://github.com/ExHammer/hammer-backend-redis/blob/master/CHANGELOG.md"
      }
    ]
  end
end
