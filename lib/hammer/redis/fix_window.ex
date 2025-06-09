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
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    expires_at = (window + 1) * scale

    commands = [
      ["INCRBY", full_key, increment],
      ["EXPIREAT", full_key, div(expires_at, 1000), "NX"]
    ]

    [count, _] =
      Redix.pipeline!(name, commands, timeout: timeout)

    if count <= limit do
      {:allow, count}
    else
      {:deny, expires_at - now}
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
    now = now()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    expires_at = (window + 1) * scale

    commands = [
      ["INCRBY", full_key, increment],
      ["EXPIREAT", full_key, div(expires_at, 1000), "NX"]
    ]

    [count, _] =
      Redix.pipeline!(name, commands, timeout: timeout)

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
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    expires_at = (window + 1) * scale

    commands = [
      ["SET", full_key, count],
      ["EXPIREAT", full_key, div(expires_at, 1000), "NX"]
    ]

    Redix.pipeline!(name, commands, timeout: timeout)

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
    now = now()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    count = Redix.command!(name, ["GET", full_key], timeout: timeout)

    case count do
      nil -> 0
      count -> String.to_integer(count)
    end
  end

  @compile inline: [redis_key: 3]
  defp redis_key(prefix, key, window) do
    "#{prefix}:#{key}:#{window}"
  end

  @compile inline: [now: 0]
  defp now do
    System.system_time(:millisecond)
  end
end
