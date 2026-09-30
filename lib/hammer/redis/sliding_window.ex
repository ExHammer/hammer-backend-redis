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

  ## Example usage:

      defmodule MyApp.RateLimit do
        use Hammer, backend: Hammer.Redis, algorithm: :sliding_window
      end

      MyApp.RateLimit.start_link([])

      # Allow 10 requests in any 1 second window
      MyApp.RateLimit.hit("user_123", 1000, 10)

  ## Storage

  Each key is a sorted set of the requests in its window, scored by their
  timestamp in seconds with millisecond precision. `hit/4`, `inc/3`, `set/3`
  and `get/2` all read and write the same set, and use the Redis server clock.
  """
  @doc false
  @spec hit(
          Redix.connection(),
          String.t(),
          String.t(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          timeout()
        ) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(name, prefix, key, scale, limit, increment, timeout) do
    case eval(name, prefix, key, scale, ["hit", limit, increment], timeout) do
      [1, count] -> {:allow, count}
      [0, wait] -> {:deny, wait}
    end
  end

  @doc false
  @spec inc(
          Redix.connection(),
          String.t(),
          String.t(),
          pos_integer(),
          non_neg_integer(),
          timeout()
        ) :: non_neg_integer()
  def inc(name, prefix, key, scale, increment, timeout) do
    eval(name, prefix, key, scale, ["inc", 0, increment], timeout)
  end

  @doc false
  @spec set(
          Redix.connection(),
          String.t(),
          String.t(),
          pos_integer(),
          non_neg_integer(),
          timeout()
        ) :: non_neg_integer()
  def set(name, prefix, key, scale, count, timeout) do
    eval(name, prefix, key, scale, ["set", 0, count], timeout)
  end

  @doc false
  @spec get(
          Redix.connection(),
          String.t(),
          String.t(),
          pos_integer(),
          timeout()
        ) :: non_neg_integer()
  def get(name, prefix, key, scale, timeout) do
    eval(name, prefix, key, scale, ["get", 0, 0], timeout)
  end

  defp eval(name, prefix, key, scale, [mode, limit, amount], timeout) do
    command = [
      "EVAL",
      redis_script(),
      "1",
      redis_key(prefix, key, scale),
      mode,
      scale,
      limit,
      amount
    ]

    case Redix.command(name, command, timeout: timeout) do
      {:ok, reply} -> reply
      {:error, error} -> raise error
    end
  end

  # One set per key and scale, shared by hit/inc/set/get. The window slides,
  # so the key must not change over time.
  @compile inline: [redis_key: 3]
  defp redis_key(prefix, key, scale) do
    "#{prefix}:#{key}:#{scale}"
  end

  # KEYS[1] is the set; ARGV is mode ("hit", "inc", "set" or "get"), the
  # window in ms, the limit (hit only) and the amount (increment or count).
  #
  # Scores are seconds with a millisecond fraction, so entries written by
  # earlier versions (whole seconds) are still counted and trimmed correctly.
  defp redis_script do
    """
    local key = KEYS[1]
    local mode = ARGV[1]
    local window_ms = tonumber(ARGV[2])
    local limit = tonumber(ARGV[3])
    local amount = tonumber(ARGV[4])

    local time = redis.call("TIME")
    local now_ms = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
    -- An entry is in the window while its score is > threshold
    local threshold = string.format("%.3f", (now_ms - window_ms) / 1000)

    if mode == "get" then
      return redis.call("ZCOUNT", key, "(" .. threshold, "+inf")
    end

    redis.call("ZREMRANGEBYSCORE", key, "-inf", threshold)
    local count = redis.call("ZCARD", key)

    if mode == "set" then
      redis.call("DEL", key)
      count = 0
    end

    if mode == "hit" and count + amount > limit then
      -- Deny with the time until enough of the oldest entries leave the
      -- window for this hit to fit: the (count + amount - limit)-th oldest.
      -- A hit larger than the limit never fits; answer with a full window.
      local needed = count + amount - limit
      if needed > count then
        return {0, window_ms}
      end
      local entry = redis.call("ZRANGE", key, needed - 1, needed - 1, "WITHSCORES")
      local entry_ms = math.floor(tonumber(entry[2]) * 1000 + 0.5)
      return {0, math.max(entry_ms + window_ms - now_ms, 1)}
    end

    -- Members only need to be unique. Two calls in the same microsecond see
    -- different counts, since entries from that instant can't be trimmed yet.
    local score = string.format("%.3f", now_ms / 1000)
    for i = 1, amount do
      redis.call("ZADD", key, score, time[1] .. time[2] .. "-" .. count .. "-" .. i)
    end

    if amount > 0 then
      redis.call("PEXPIRE", key, window_ms)
    end

    if mode == "hit" then
      return {1, count + amount}
    end
    return count + amount
    """
  end
end
