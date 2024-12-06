# Hammer.Redis

[![Build Status](https://github.com/ExHammer/hammer-backend-redis/actions/workflows/ci.yml/badge.svg)](https://github.com/ExHammer/hammer-backend-redis/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/hammer_backend_redis.svg)](https://hex.pm/packages/hammer_backend_redis)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/hammer_backend_redis)
[![Total Download](https://img.shields.io/hexpm/dt/hammer_backend_redis.svg)](https://hex.pm/packages/hammer_backend_redis)
[![License](https://img.shields.io/hexpm/l/hammer_backend_redis.svg)](https://github.com/ExHammer/hammer-backend-redis/blob/master/LICENSE.md)

A Redis backend for the [Hammer](https://github.com/ExHammer/hammer) rate-limiter.

This backend is a thin [Redix](https://hex.pm/packages/redix) wrapper. A single connection is used per rate-limiter. It should be enough for most use-cases since packets for rate limiting requests are short (i.e. no head of line blocking) and Redis is OK with [pipelining](https://redis.io/learn/operate/redis-at-scale/talking-to-redis/client-performance-improvements#pipelining) (i.e. we don't block awaiting replies). Consider benchmarking before introducing more connections since TCP performance might be unintuitive. For possible pooling approaches, see Redix docs on [pooling](https://hexdocs.pm/redix/real-world-usage.html#name-based-pool) and also [PartitionSupervisor.](https://hexdocs.pm/elixir/1.17.3/PartitionSupervisor.html) Do not use poolboy or db_connection-like pools since they practically disable pipelining which leads to worse connection utilisation and worse performance.

The algorithm we are using is the first method described (called "bucketing") in [Rate Limiting with Redis](https://youtu.be/CRGPbCbRTHA?t=753).
In other sources it's sometimes called a "fixed window counter".

**TODO:** document ttl issues if servers are misconfigured

## Installation

Hammer-backend-redis
is [available in Hex](https://hex.pm/packages/hammer_backend_redis), the package
can be installed by adding `hammer_backend_redis` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hammer_backend_redis, "~> 7.0"}
  ]
end
```

## Usage

Define the rate limiter:

```elixir
defmodule MyApp.RateLimit do
  use Hammer, backend: Hammer.Redis
end
```

And add it to your app's supervision tree:

```elixir
children = [
  {MyApp.RateLimit, url: "redis://localhost:6379"}
]
```

And that's it, calls to `MyApp.RateLimit.hit/3` and so on will use Redis to store
the rate-limit counters. See the [documentation](https://hexdocs.pm/hammer_backend_redis/Hammer.Redis.html) for more details.

## Run tests locally

You need a running Redis instance. One can be started locally using `docker compose up -d redis`.
See the [compose.yml](./compose.yml) for more details.

## Getting Help

If you're having trouble, open an issue on this repo.
