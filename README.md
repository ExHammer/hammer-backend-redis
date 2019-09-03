# HammerBackendRedis

[![Build Status](https://travis-ci.org/ExHammer/hammer-backend-redis.svg?branch=master)](https://travis-ci.org/ExHammer/hammer-backend-redis)

[![Coverage Status](https://coveralls.io/repos/github/ExHammer/hammer-backend-redis/badge.svg?branch=master)](https://coveralls.io/github/ExHammer/hammer-backend-redis?branch=master)


A Redis backend for the [Hammer](https://github.com/ExHammer/hammer) rate-limiter.

## Installation

Hammer-backend-redis
is [available in Hex](https://hex.pm/packages/hammer_backend_redis), the package
can be installed by adding `hammer_backend_redis` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:hammer_backend_redis, "~> 6.1"},
   {:hammer, "~> 6.0"}]
end
```

## Usage

Configure the `:hammer` application to use the Redis backend:

```elixir
config :hammer,
  backend: {Hammer.Backend.Redis, [expiry_ms: 60_000 * 60 * 2,
                                   redix_config: [host: "localhost",
                                                  port: 6379]]}
```

(the `redix_config` arg is a keyword-list which is passed to
[Redix](https://hex.pm/packages/redix), it's also aliased to `redis_config`,
with an `s`)

And that's it, calls to `Hammer.check_rate/3` and so on will use Redis to store
the rate-limit counters.

See the [Hammer Tutorial](https://hexdocs.pm/hammer/tutorial.html) for more.

## Documentation

On hexdocs: [https://hexdocs.pm/hammer_backend_redis/](https://hexdocs.pm/hammer_backend_redis/)


## Getting Help

If you're having trouble, either open an issue on this repo, or reach out to the maintainers ([@shanekilkelly](https://twitter.com/shanekilkelly)) on Twitter.
