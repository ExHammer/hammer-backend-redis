defmodule Hammer.Redis.SlidingWindow do
  @moduledoc """
  This module implements the Sliding Window algorithm.

  The sliding window algorithm works by dividing time into sliding intervals or "windows"
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

  The sliding window algorithm is a good choice when:

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
        use Hammer, backend: Hammer.Redis, algorithm: :sliding_window
      end

      MyApp.RateLimit.start_link(clean_period: :timer.minutes(1))

      # Allow 10 requests per second
      MyApp.RateLimit.hit("user_123", 1000, 10)
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
  def hit(connection_name, prefix, key, window_ms, limit, _increment, timeout) do
    full_key = redis_key(prefix, key, window_ms)
    window_seconds = div(window_ms, 1000)

    {:ok, [allowed, value]} =
      Redix.command(
        connection_name,
        [
          "EVAL",
          redis_script(:hit),
          "1",
          full_key,
          window_seconds,
          limit
        ],
        timeout: timeout
      )

    if allowed == 1 do
      {:allow, value}
    else
      {:deny, value * 1000}
    end
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
    now_ms = now_ms()
    window_ms = div(now_ms, scale)
    full_key = redis_key(prefix, key, window_ms)
    window_seconds = div(window_ms, 1000)

    commands =
      1..increment
      |> Enum.map(fn index ->
        now_microseconds = System.system_time(:microsecond)
        now_seconds = div(now_microseconds, 1_000_000)
        ["ZADD", full_key, to_string(now_seconds), to_string(now_microseconds) <> to_string(index)]
      end)
      |> Enum.concat([
        ["EXPIRE", full_key, window_seconds],
        ["ZCARD", full_key]
      ])

    name
    |> Redix.pipeline!(commands, timeout: timeout)
    |> List.last()
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
    now_ms = now_ms()
    window_ms = div(now_ms, scale)
    full_key = redis_key(prefix, key, window_ms)
    window_seconds = div(window_ms, 1000)

    commands =
      1..count
      |> Enum.map(fn index ->
        now_microseconds = System.system_time(:microsecond)
        now_seconds = div(now_microseconds, 1_000_000)
        ["ZADD", full_key, to_string(now_seconds), to_string(now_microseconds) <> to_string(index)]
      end)
      |> Enum.concat([
        ["EXPIRE", full_key, window_seconds],
        ["ZCARD", full_key]
      ])

    name
    |> Redix.pipeline!(commands, timeout: timeout)
    |> List.last()
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
    now = now_ms()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    count = Redix.command!(name, ["ZCARD", full_key], timeout: timeout)

    count || 0
  end

  @compile inline: [redis_key: 3]
  defp redis_key(prefix, key, window) do
    "#{prefix}:#{key}:#{window}"
  end

  @compile inline: [now_ms: 0]
  defp now_ms do
    System.system_time(:millisecond)
  end

  defp redis_script(:hit) do
    """
    local key = KEYS[1]
    local window = tonumber(ARGV[1])
    local max_requests = tonumber(ARGV[2])

    local current_time = redis.call("TIME")
    local trim_time = tonumber(current_time[1]) - window
    redis.call("ZREMRANGEBYSCORE", key, 0, trim_time)
    local request_count = redis.call("ZCARD", key) or 0
    request_count = tonumber(request_count)

    if request_count < max_requests then
      redis.call("ZADD", key, current_time[1], current_time[1] .. current_time[2])
      redis.call("EXPIRE", key, window)
      return {1, request_count + 1} -- Allow with requests
    else
      local expire_time = redis.call("EXPIRETIME", key)
      return {0, expire_time - tonumber(current_time[1])} -- Deny with ms wait time
    end
    """
  end
end
