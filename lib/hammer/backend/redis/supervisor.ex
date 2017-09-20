defmodule Hammer.Backend.Redis.Supervisor do
  @moduledoc """
  Supervisor for Hammer.Backend.Redis
  """

  use Supervisor

  def start_link do
    start_link([], [])
  end

  def start_link(config, opts) do
    Supervisor.start_link(__MODULE__, config, opts)
  end

  def init(config) do
    # If redix_config is not present, fall back to redis_config (with an 's'),
    # and then fall back to an empty list. We do this as end Users are bound to
    # misread 'redix' as 'redis'
    redix_config = Keyword.get(
      config,
      :redix_config,
      Keyword.get(config, :redis_config, [])
    )
    redix_process_name = Keyword.get(
      config,
      :redix_process_name,
      :hammer_backend_redis_redix
    )
    backend_config = [
      expiry_ms: Keyword.get(config, :expiry_ms, 60_000 * 60 * 2),
      redix_process_name: redix_process_name
    ]
    children = [
      worker(Redix, [redix_config, [name: redix_process_name]]),
      worker(Hammer.Backend.Redis, [backend_config])
    ]
    supervise(children, strategy: :one_for_one, name: __MODULE__)
  end

end
