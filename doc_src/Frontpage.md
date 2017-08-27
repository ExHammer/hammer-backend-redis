# A Redis backend for the Hammer rate-limiter

[Hammer](https://github.com/ExHammer/hammer) is a rate-limiter for the [Elixir](https://elixir-lang.org/) language. It's killer feature is a pluggable backend system, allowing you to use whichever storage suits your needs.

This package provides a Redis backend for Hammer, using the [Redix](https://github.com/whatyouhide/redix) library to connect to the Redis server.

To get started, read the [Hammer Tutorial](https://hexdocs.pm/hammer/tutorial.html) first, then add the `hammer_backend_redis` dependency:

```elixir
    def deps do
      [{:hammer_backend_redis, "~> 0.1.0"}]
    end
```

... then start a `Hammer.Backend.Redis` process:

```elixir
      worker(Hammer.Backend.Redis, [[expiry_ms: 1000 * 60 * 2,
                                     redix_config: [host: "localhost", port: 6379]]]),
```

(the `redix_config` arg is a keyword-list which is passed to Redix, it's also aliased to `redis_config`, with an `s`)

... and set the `backend` arg to the `Hammer` macro:

```elixir
    use Hammer, backend: Hammer.Backend.Redis
```
