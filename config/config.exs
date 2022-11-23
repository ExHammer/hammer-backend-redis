# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
import Config

config :hammer,
  backend:
    {Hammer.Backend.Redis,
     [
       expiry_ms: 60_000 * 60 * 2,
       delete_buckets_timeout: 5000,
       redix_config: [
         host: System.get_env("REDIS_HOST", "localhost"),
         port: "REDIS_PORT" |> System.get_env("6379") |> String.to_integer()
       ]
     ]}
