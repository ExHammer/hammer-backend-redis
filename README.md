# HammerBackendRedis

[![Build Status](https://github.com/ExHammer/hammer-backend-redis/actions/workflows/ci.yml/badge.svg)](https://github.com/ExHammer/hammer-backend-redis/actions/workflows/ci.yml) [![Hex.pm](https://img.shields.io/hexpm/v/hammer_backend_redis.svg)](https://hex.pm/packages/hammer_backend_redis) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/hammer_backend_redis)
[![Total Download](https://img.shields.io/hexpm/dt/hammer_backend_redis.svg)](https://hex.pm/packages/hammer_backend_redis)
[![License](https://img.shields.io/hexpm/l/hammer_backend_redis.svg)](https://github.com/ExHammer/hammer-backend-redis/blob/master/LICENSE.md)

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
  backend: {Hammer.Backend.Redis, [delete_buckets_timeout: 10_0000,
                                   expiry_ms: 60_000 * 60 * 2,
                                   redix_config: [host: "localhost",
                                                  port: 6379]]}
```

(the `redix_config` arg is a keyword-list which is passed to
[Redix](https://hex.pm/packages/redix), it's also aliased to `redis_config`,
with an `s`)

Another option to configure Redis is to use the Redis Url format (see https://hexdocs.pm/redix/Redix.html#start_link/1-using-a-redis-uri) to configure Redis. If both options are specified
the redis_url will be used first.

```elixir
config :hammer,
  backend: {Hammer.Backend.Redis, [delete_buckets_timeout: 10_0000,
                                   expiry_ms: 60_000 * 60 * 2,
                                   redis_url: "redis://HOST:PORT"]}
```

And that's it, calls to `Hammer.check_rate/3` and so on will use Redis to store
the rate-limit counters.

See the [Hammer Tutorial](https://hexdocs.pm/hammer/tutorial.html) for more.

## Documentation

On hexdocs: [https://hexdocs.pm/hammer_backend_redis/](https://hexdocs.pm/hammer_backend_redis/)

## Run tests locally

You need a running Redis instance. One can be started locally using `docker-compose up -d`.
See the docker-compose.yml for more details on.

## Getting Help

If you're having trouble, open an issue on this repo.
