# MIX_ENV=bench LIMIT=1 SCALE=5000 RANGE=10000 PARALLEL=500 mix run bench/base.exs
# inspired from https://github.com/PragTob/rate_limit/blob/master/bench/basic.exs
profile? = !!System.get_env("PROFILE")
parallel = String.to_integer(System.get_env("PARALLEL", "1"))
limit = String.to_integer(System.get_env("LIMIT", "1000000"))
scale = String.to_integer(System.get_env("SCALE", "60000"))
range = String.to_integer(System.get_env("RANGE", "1_000"))

IO.puts("""
parallel: #{parallel}
limit: #{limit}
scale: #{scale}
range: #{range}
""")

defmodule RedisFixWindowRateLimiter do
  @moduledoc false
  use Hammer, backend: Hammer.Redis, algorithm: :fix_window
end

defmodule RedisLeakyBucketRateLimiter do
  @moduledoc false
  use Hammer, backend: Hammer.Redis, algorithm: :leaky_bucket
end

defmodule RedisTokenBucketRateLimiter do
  @moduledoc false
  use Hammer, backend: Hammer.Redis, algorithm: :token_bucket
end

defmodule RedisSlidingWindowRateLimiter do
  @moduledoc false
  use Hammer, backend: Hammer.Redis, algorithm: :sliding_window
end

RedisFixWindowRateLimiter.start_link([])
RedisTokenBucketRateLimiter.start_link([])
RedisLeakyBucketRateLimiter.start_link([])
RedisSlidingWindowRateLimiter.start_link([])

Benchee.run(
  %{
    "hammer_redis_fix_window" => fn key -> RedisFixWindowRateLimiter.hit("sites:#{key}", scale, limit) end,
    "hammer_redis_leaky_bucket" => fn key -> RedisLeakyBucketRateLimiter.hit("sites:#{key}", scale, limit) end,
    "hammer_redis_token_bucket" => fn key -> RedisTokenBucketRateLimiter.hit("sites:#{key}", scale, limit) end,
    "hammer_redis_sliding_window" => fn key -> RedisSlidingWindowRateLimiter.hit("sites:#{key}", scale, limit) end
  },
  formatters: [{Benchee.Formatters.Console, extended_statistics: true}],
  before_each: fn _ -> :rand.uniform(range) end,
  print: [fast_warning: false],
  time: 6,
  # fill the table with some data
  warmup: 14,
  profile_after: profile?,
  parallel: parallel
)
