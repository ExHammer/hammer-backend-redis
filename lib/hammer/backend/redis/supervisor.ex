defmodule Hammer.Backend.Redis.Supervisor do
  @moduledoc """
  Supervisor for Hammer.Backend.Redis
  """
  use Supervisor

  def start_link(config, opts) do
    Supervisor.start_link(__MODULE__, config, opts)
  end

  def init(config) do
    redix_config = Keyword.get(
      config,
      :redix_config,
      Keyword.get(config, :redis_config, [])
    )
    backend_config = [
      expiry_ms: Keyword.get(config, :expiry_ms, 60_000 * 60 * 2)
    ]
    children = [
      worker(Redix, [redix_config, [name: :hammer_backend_redis_redix]]),
      worker(Hammer.Backend.Redis, [backend_config])
    ]
    supervise(children, strategy: :one_for_one, name: __MODULE__)
  end

end
