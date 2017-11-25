defmodule HammerBackendRedis.Mixfile do
  use Mix.Project

  def project do
    [app: :hammer_backend_redis,
     description: "Redis backend for Hammer rate-limiter",
     package: [name: :hammer_backend_redis,
               maintainers: ["Shane Kilkelly (shane@kilkelly.me)"],
               licenses: ["MIT"],
               links: %{"GitHub" => "https://github.com/ExHammer/hammer-backend-redis"}],
     source_url: "https://github.com/ExHammer/hammer-backend-redis",
     homepage_url: "https://github.com/ExHammer/hammer-backend-redis",
     version: "2.1.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps(),
     docs: [main: "frontpage",
            extras: ["doc_src/Frontpage.md"]],
     test_coverage: [tool: ExCoveralls],
     preferred_cli_env: ["coveralls": :test,
                         "coveralls.detail": :test,
                         "coveralls.post": :test,
                         "coveralls.html": :test]]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [{:redix, "~> 0.6"},
     {:hammer, "~> 2.1.0"},
     {:mock, "~> 0.2.0", only: :test},
     {:ex_doc, "~> 0.16", only: :dev},
     {:dialyxir, "~> 0.5", only: [:dev], runtime: false},
     {:credo, "~> 0.8", only: [:dev, :test], runtime: false},
     {:excoveralls, "~> 0.5", only: :test}]
  end
end
