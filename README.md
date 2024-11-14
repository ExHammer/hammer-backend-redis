# Hammer.Redis

[![Build Status](https://github.com/ExHammer/hammer-backend-redis/actions/workflows/ci.yml/badge.svg)](https://github.com/ExHammer/hammer-backend-redis/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/hammer_backend_redis.svg)](https://hex.pm/packages/hammer_backend_redis)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/hammer_backend_redis)
[![Total Download](https://img.shields.io/hexpm/dt/hammer_backend_redis.svg)](https://hex.pm/packages/hammer_backend_redis)
[![License](https://img.shields.io/hexpm/l/hammer_backend_redis.svg)](https://github.com/ExHammer/hammer-backend-redis/blob/master/LICENSE.md)

A Redis backend for the [Hammer](https://github.com/ExHammer/hammer) rate-limiter.

This backend uses the [Redix](https://hex.pm/packages/redix) library to connect to Redis. And [poolboy](https://hex.pm/packages/poolboy) to pool the connections.

The algorithm we are using is the first method described (called "bucketing") in [Rate Limiting with Redis](https://youtu.be/CRGPbCbRTHA?t=753).
In other sources it's sometimes called a "fixed window counter".

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
