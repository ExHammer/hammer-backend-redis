defmodule Hammer.Redis.SlidingWindow do
  @moduledoc """
  This module implements the Rate Limiting Sliding Window algorithm.

  The sliding window algorithm works by tracking requests within a moving time window.
  Unlike a fixed window that resets at specific intervals, the sliding window
  provides a smoother rate limiting experience by considering the most recent
  window of time.

  For example, with a 60 second window:
  - At time t, we look back 60 seconds and count all requests in that period
  - At time t+1, we look back 60 seconds from t+1, dropping any requests older than that
  - This creates a "sliding" effect where the window gradually moves forward in time

  ## The algorithm:
  1. When a request comes in, we store it with the current timestamp
  2. To check if rate limit is exceeded, we:
     - Count all requests within the last <scale> seconds
     - If count <= limit: allow the request
     - If count > limit: deny and return time until oldest request expires
  3. Old entries outside the window are automatically cleaned up

  This provides more precise rate limiting compared to fixed windows, avoiding
  the edge case where a burst of requests spans a fixed window boundary.

  The sliding window algorithm is a good choice when:

  - You need precise rate limiting without allowing bursts at window boundaries
  - Accuracy of the rate limit is critical for your application
  - You can accept slightly higher storage overhead compared to fixed windows
  - You want to avoid sudden changes in allowed request rates

  ## Common use cases include:

  - API rate limiting where consistent request rates are important
  - Financial transaction rate limiting
  - User action throttling requiring precise control
  - Gaming or real-time applications needing smooth rate control
  - Security-sensitive rate limiting scenarios

  The main advantages over fixed windows are:

  - No possibility of 2x burst at window boundaries
  - Smoother rate limiting behavior
  - More predictable request patterns

  The tradeoffs are:
  - Slightly more complex implementation
  - Higher storage requirements (need to store individual request timestamps)
  - More computation required to check limits (need to count requests in window)

  For example, with a limit of 100 requests per minute:
  - Fixed window might allow 200 requests across a boundary (100 at 11:59, 100 at 12:00)
  - Sliding window ensures no more than 100 requests in ANY 60 second period

  The sliding window algorithm supports the following options:

  - `:clean_period` - How often to run the cleanup process (in milliseconds)
    Defaults to 1 minute. The cleanup process removes expired window entries.

  ## Example usage:

      defmodule MyApp.RateLimit do
        use Hammer, backend: Hammer.Redis, algorithm: :sliding_window
      end

      MyApp.RateLimit.start_link(clean_period: :timer.minutes(1))

      # Allow 10 requests in any 1 second window
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
