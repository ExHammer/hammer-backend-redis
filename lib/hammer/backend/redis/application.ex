defmodule Hammer.Backend.Redis.Application do
  @moduledoc """
  The Hammer.Backend.Redis Application
  """
  use Application

  def start(_type, _args) do
    Hammer.Backend.Redis.Supervisor.start_link(
      Application.get_all_env(:hammer_backend_redis),
      name: :hammer_backend_redis_sup
    )
  end

end
