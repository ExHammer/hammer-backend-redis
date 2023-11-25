# Overview

A Redis backend for the Hammer rate-limiter

[Hammer](https://github.com/ExHammer/hammer) is a rate-limiter for
the [Elixir](https://elixir-lang.org/) language. It's killer feature is a
pluggable backend system, allowing you to use whichever storage suits your
needs.

This package provides a Redis backend for Hammer, using
the [Redix](https://github.com/whatyouhide/redix) library to connect to the
Redis server.

To get started, read
the [Hammer Tutorial](https://hexdocs.pm/hammer/tutorial.html) first, then add
the `hammer_backend_redis` dependency:

```elixir
def deps do
  [
    {:hammer_backend_redis, "~> 7.0"}
  ]
end
```

... then configure the `:hammer` application to use the Redis backend:

```elixir
config :hammer, backend: Hammer.Backend.Redis
```

... and then add it to the supervision tree

```elixir
children = [
  {Hammer.Backend.Redis, redis_url: "redis://localhost:6379"}
]
```

And that's it, calls to `Hammer.check_rate/3` and so on will use Redis to store
the rate-limit counters.
