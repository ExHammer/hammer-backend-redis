import Config

config :hammer,
  backend:
    {Hammer.Backend.Redis,
     [
       expiry_ms: 60_000 * 60 * 2,
       delete_buckets_timeout: 5000,
       redis_url: System.get_env("HAMMER_REDIS_URL")
     ]}
