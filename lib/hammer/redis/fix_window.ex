defmodule Hammer.Redis.FixWindow do
  @moduledoc """
  This module implements the Fix Window algorithm.

  The fixed window algorithm works by dividing time into fixed intervals or "windows"
  of a specified duration (scale). Each window tracks request counts independently.

  For example, with a 60 second window:
  - Window 1: 0-60 seconds
  - Window 2: 60-120 seconds
  - And so on...

  ## The algorithm:

  1. When a request comes in, we:
     - Calculate which window it belongs to based on current time
     - Increment the counter for that window
     - Store expiration time as end of window
  2. To check if rate limit is exceeded:
     - If count <= limit: allow request
     - If count > limit: deny and return time until window expires
  3. Old windows are automatically cleaned up after expiration

  This provides simple rate limiting but has edge cases where a burst of requests
  spanning a window boundary could allow up to 2x the limit in a short period.
  For more precise limiting, consider using the sliding window algorithm instead.

  The fixed window algorithm is a good choice when:

  - You need simple, predictable rate limiting with clear time boundaries
  - The exact precision of the rate limit is not critical
  - You want efficient implementation with minimal storage overhead
  - Your use case can tolerate potential bursts at window boundaries

  ## Common use cases include:

  - Basic API rate limiting where occasional bursts are acceptable
  - Protecting backend services from excessive load
  - Implementing fair usage policies
  - Scenarios where clear time-based quotas are desired (e.g. "100 requests per minute")

  The main tradeoff is that requests near window boundaries can allow up to 2x the
  intended limit in a short period. For example with a limit of 100 per minute:
  - 100 requests at 11:59:59
  - Another 100 requests at 12:00:01

  This results in 200 requests in 2 seconds, while still being within limits.
  If this behavior is problematic, consider using the sliding window algorithm instead.

  ## Example usage:

      defmodule MyApp.RateLimit do
        use Hammer, backend: Hammer.Redis, algorithm: :fix_window
      end

      MyApp.RateLimit.start_link([])

      # Allow 10 requests per second
      MyApp.RateLimit.hit("user_123", 1000, 10)

  ## Hitting several windows at once

  `hit_many/1` checks several counters in a single atomic round trip, and
  increments them only if every one of them stays within its limit. Use it when
  one action is subject to more than one limit:

      # 1 SMS per minute and 6 per hour
      MyApp.RateLimit.hit_many([
        {"{user_123}:sms:minute", :timer.minutes(1), 1},
        {"{user_123}:sms:hour", :timer.hours(1), 6}
      ])
      # => {:allow, [1, 3]} or {:deny, retry_after_ms}

  Each bucket is `{key, scale, limit}` or `{key, scale, limit, increment}`,
  with `increment` defaulting to 1. On allow the counts are returned in the
  same order as the buckets. On deny the wait is the longest one among the
  denying windows.

  Unlike `hit/4`, which counts a hit even when it is denied, a denied
  `hit_many/1` increments nothing. Otherwise a request rejected by one limit
  would still use up the others.

  > #### Redis Cluster {: .warning}
  >
  > All keys in one `hit_many/1` call are touched by a single script, so on
  > Redis Cluster they must hash to the same slot. Wrap the shared part of the
  > key in a [hash tag](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/#hash-tags),
  > such as `{user_123}` above, or the call fails with a `CROSSSLOT` error.

  ## Redis version requirement

  This algorithm sets key expiration with `PEXPIREAT ... NX`; the `NX` option requires
  Redis 7.0 or later. On older Redis versions the command fails, so counter keys never
  expire and accumulate until Redis runs out of memory.
  """
  @doc false
  @spec hit(
          Redix.connection(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          timeout()
        ) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(name, prefix, key, scale, limit, increment, timeout) do
    now = now()
    {full_key, expires_at} = window(prefix, key, scale, now)

    commands = [
      ["INCRBY", full_key, increment],
      ["PEXPIREAT", full_key, expires_at, "NX"]
    ]

    [count, _] =
      Hammer.Redis.pipeline!(name, commands, timeout)

    if count <= limit do
      {:allow, count}
    else
      {:deny, expires_at - now}
    end
  end

  @type bucket ::
          {key :: String.t(), scale :: pos_integer(), limit :: non_neg_integer()}
          | {key :: String.t(), scale :: pos_integer(), limit :: non_neg_integer(),
             increment :: non_neg_integer()}

  @doc false
  @spec hit_many(Redix.connection(), String.t(), [bucket(), ...], timeout()) ::
          {:allow, [non_neg_integer()]} | {:deny, non_neg_integer()}
  def hit_many(name, prefix, buckets, timeout) do
    # One clock reading for every bucket, so they all see the same instant
    now = now()

    buckets =
      Hammer.Redis.normalize_buckets!(buckets, ~w(key scale limit increment), fn
        {key, scale, _, _} -> elem(window(prefix, key, scale, now), 0)
      end)

    # A window never allows more than `limit`, so a larger increment could
    # never be allowed and a caller retrying on the returned wait would spin.
    for {key, _, limit, increment} <- buckets, increment > limit do
      raise ArgumentError,
            "hit_many/1 got increment #{increment} greater than limit #{limit} for #{key}, " <>
              "which can never be allowed"
    end

    Hammer.Redis.eval_many!(
      name,
      hit_many_script(),
      buckets,
      fn {_, scale, limit, increment} ->
        expires_at = window_end(scale, now)
        [limit, increment, expires_at, expires_at - now]
      end,
      timeout
    )
  end

  # Checks every counter in KEYS (with limit, increment, expires_at_ms,
  # wait_ms in ARGV) and increments them only if all of them stay within
  # their limit. Returns {1, count_1, ..., count_n} on allow, or {0, wait_ms}
  # with the longest wait among the denying windows.
  defp hit_many_script do
    """
    local denied = false
    local wait = 0

    -- First pass: check every counter, writing nothing
    for i, key in ipairs(KEYS) do
      local limit = tonumber(ARGV[4 * i - 3])
      local increment = tonumber(ARGV[4 * i - 2])
      local count = tonumber(redis.call("GET", key)) or 0

      if count + increment > limit then
        denied = true
        wait = math.max(wait, tonumber(ARGV[4 * i]))
      end
    end

    -- Any denial increments nothing, and the caller waits for the slowest window
    if denied then
      return {0, wait}
    end

    -- Second pass: every counter allowed, increment all of them
    local reply = {1}
    for i, key in ipairs(KEYS) do
      reply[i + 1] = redis.call("INCRBY", key, ARGV[4 * i - 2])
      redis.call("PEXPIREAT", key, ARGV[4 * i - 1], "NX")
    end
    return reply
    """
  end

  @doc false
  @spec inc(
          Redix.connection(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          timeout()
        ) :: non_neg_integer()
  def inc(name, prefix, key, scale, increment, timeout) do
    now = now()
    {full_key, expires_at} = window(prefix, key, scale, now)

    commands = [
      ["INCRBY", full_key, increment],
      ["PEXPIREAT", full_key, expires_at, "NX"]
    ]

    [count, _] =
      Hammer.Redis.pipeline!(name, commands, timeout)

    count
  end

  @doc false
  @spec set(
          Redix.connection(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          timeout()
        ) :: non_neg_integer()
  def set(name, prefix, key, scale, count, timeout) do
    now = now()
    {full_key, expires_at} = window(prefix, key, scale, now)

    commands = [
      ["SET", full_key, count],
      ["PEXPIREAT", full_key, expires_at, "NX"]
    ]

    Hammer.Redis.pipeline!(name, commands, timeout)

    count
  end

  @doc false
  @spec get(
          Redix.connection(),
          String.t(),
          String.t(),
          non_neg_integer(),
          timeout()
        ) :: non_neg_integer()
  def get(name, prefix, key, scale, timeout) do
    {full_key, _expires_at} = window(prefix, key, scale, now())
    count = Redix.command!(name, ["GET", full_key], timeout: timeout)

    case count do
      nil -> 0
      count -> String.to_integer(count)
    end
  end

  # The Redis key of the window containing `now`, and when that window ends
  # (ms). The expiry is set with PEXPIREAT: EXPIREAT takes whole seconds, so a
  # window not ending on a second boundary (any scale that isn't a multiple
  # of 1000ms) expired early, or at once, and its limit was not enforced.
  @compile inline: [window: 4, window_end: 2]
  defp window(prefix, key, scale, now) do
    {"#{prefix}:#{key}:#{div(now, scale)}", window_end(scale, now)}
  end

  defp window_end(scale, now), do: (div(now, scale) + 1) * scale

  @compile inline: [now: 0]
  defp now do
    System.system_time(:millisecond)
  end
end
