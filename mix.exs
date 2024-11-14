defmodule Hammer.Redis.MixProject do
  use Mix.Project

  @version "7.0.0-rc.0"

  def project do
    [
      app: :hammer_backend_redis,
      description: "Redis backend for Hammer rate-limiter",
      source_url: "https://github.com/ExHammer/hammer-backend-redis",
      homepage_url: "https://github.com/ExHammer/hammer-backend-redis",
      version: @version,
      elixir: "~> 1.15",
      deps: deps(),
      docs: docs(),
      package: package(),
      test_coverage: [summary: [threshold: 90]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.6", only: [:dev, :test]},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.28", only: :dev},
      {:hammer, github: "ruslandoga/hammer", branch: "just-use"},
      {:redix, "~> 1.1"},
      {:poolboy, "~> 1.5"}
    ]
  end

  defp package do
    [
      name: :hammer_backend_redis,
      maintainers: ["Emmanuel Pinault", "June Kelly"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/ExHammer/hammer-backend-redis",
        "Changelog" => "https://github.com/ExHammer/hammer-backend-redis/blob/master/CHANGELOG.md"
      }
    ]
  end
end
