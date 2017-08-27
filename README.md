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
  [{:hammer_backend_redis, "~> 1.0.0"},
   {:hammer, "~> 1.0.0"}]
end
```

## Usage

```elixir
      worker(Hammer.Backend.Redis, [[expiry_ms: 1000 * 60 * 2,
                                     redix_config: []]]),
```

See the [Hammer Tutorial](https://hexdocs.pm/hammer/tutorial.html#content) for more.

## Documentation

On hexdocs: [https://hexdocs.pm/hammer_backend_redis/](https://hexdocs.pm/hammer_backend_redis/)
