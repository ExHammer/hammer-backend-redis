defmodule Hammer.Redis.TokenBucket do
  @moduledoc """
  This module implements the Token Bucket algorithm.
  The token bucket algorithm works by modeling a bucket that:
  - Fills with tokens at a constant rate (the refill rate)
  - Has a maximum capacity of tokens (the bucket size)
  - Each request consumes one or more tokens
  - If there are enough tokens, the request is allowed
  - If not enough tokens, the request is denied

  For example, with a refill rate of 10 tokens/second and bucket size of 100:
  - Tokens are added at 10 per second up to max of 100
  - Each request needs tokens to proceed
  - If bucket has enough tokens, request allowed and tokens consumed
  - If not enough tokens, request denied until bucket refills

  ## The algorithm:

  1. When a request comes in, we:
  - Calculate tokens added since last request based on time elapsed
  - Add new tokens to bucket (up to max capacity)
  - Try to consume tokens for the request
  - Store new token count and timestamp
  2. To check if rate limit is exceeded:
  - If enough tokens: allow request and consume tokens
  - If not enough: deny and return time until enough tokens refill
  3. Old entries are automatically cleaned up after expiration

  This provides smooth rate limiting with ability to handle bursts up to bucket size.
  The token bucket is a good choice when:

  - You need to allow temporary bursts of traffic
  - Want to enforce an average rate limit
  - Need to support different costs for different operations
  - Want to avoid the sharp edges of fixed windows

  ## Common use cases include:

  - API rate limiting with burst tolerance
  - Network traffic shaping
  - Resource allocation control
  - Gaming systems with "energy" mechanics
  - Scenarios needing flexible rate limits

  The main advantages are:
  - Natural handling of bursts
  - Flexible token costs for different operations
  - Smooth rate limiting behavior
  - Simple to reason about

  The tradeoffs are:
  - Need to track token count and last update time
  - May need tuning of bucket size and refill rate
  - More complex than fixed windows

  For example with 100 tokens/minute limit and 500 bucket size:
  - Can handle bursts using saved up tokens
  - Automatically smooths out over time
  - Different operations can cost different amounts
  - More flexible than fixed request counts

  ## Example usage:

      defmodule MyApp.RateLimit do
      use Hammer, backend: Hammer.Redis, algorithm: :token_bucket
      end

      MyApp.RateLimit.start_link([])

      # Allow 10 tokens per second with max capacity of 100
      MyApp.RateLimit.hit("user_123", 10, 100, 1)
  """

  @doc false
  @spec hit(
          connection_name :: atom(),
          prefix :: String.t(),
          key :: String.t(),
          refill_rate :: pos_integer(),
          capacity :: pos_integer(),
          cost :: pos_integer(),
          timeout :: timeout()
        ) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(connection_name, prefix, key, refill_rate, capacity, cost, timeout) do
    [allowed, value] =
      case Redix.command(
             connection_name,
             [
               "EVAL",
               redis_script(),
               "1",
               redis_key(prefix, key),
               capacity,
               refill_rate,
               cost
             ],
             timeout: timeout
           ) do
        {:ok, reply} -> reply
        {:error, error} -> raise error
      end

    if allowed == 1 do
      {:allow, value}
    else
      {:deny, value}
    end
  end

  @compile inline: [redis_key: 2]
  defp redis_key(prefix, key) do
    "#{prefix}:#{key}"
  end

  @doc """
  Returns the current level of the bucket for a given key.
  """
  @spec get(
          connection_name :: atom(),
          prefix :: String.t(),
          key :: String.t(),
          timeout :: timeout()
        ) ::
          non_neg_integer()
  def get(connection_name, prefix, key, timeout) do
    case Redix.command(
           connection_name,
           [
             "HGET",
             redis_key(prefix, key),
             "level"
           ],
           timeout: timeout
         ) do
      {:ok, nil} ->
        0

      {:ok, level} ->
        String.to_integer(level)

      {:error, error} ->
        raise error
    end
  end

  defp redis_script do
    """
    -- Current time in milliseconds. Whole-second resolution only credits
    -- tokens when the second rolls over, in one lump of refill_rate tokens:
    -- when refill_rate > capacity the lump overflows and sustained throughput
    -- is capped at capacity/sec, and a sub-second wait can't be expressed.
    local time = redis.call("TIME")
    local now = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)

    local capacity = tonumber(ARGV[1])
    local refill_rate = tonumber(ARGV[2])
    local cost = tonumber(ARGV[3])

    -- Get current bucket state. Buckets written before the switch to
    -- milliseconds only carry `last_update` in seconds; convert it once.
    local bucket = redis.call("HMGET", KEYS[1], "level", "last_update_ms", "last_update")
    local current_level = tonumber(bucket[1]) or capacity -- Default to capacity if new
    local last_update = tonumber(bucket[2])
    if not last_update then
      local legacy = tonumber(bucket[3])
      last_update = legacy and legacy * 1000 or now
    end

    -- Calculate tokens to add since last update
    local elapsed = math.max(0, now - last_update)
    local new_tokens = math.floor(elapsed * refill_rate / 1000)
    local current_tokens = math.min(capacity, current_level + new_tokens)

    -- Try to consume tokens
    if current_tokens >= cost then
      local final_level = current_tokens - cost

      -- Advance the clock only by the time whose tokens were actually
      -- credited, so the sub-token remainder carries into the next hit.
      -- Stamping `now` unconditionally discards it, and a caller hitting
      -- faster than one token-period would never refill at all.
      --
      -- The exception is an overflowing refill: the surplus is legitimately
      -- discarded, so the clock snaps to `now` or a long-idle bucket banks
      -- unbounded credit. That only applies when tokens actually accrued.
      local new_last_update
      if current_tokens == capacity and new_tokens > 0 then
        new_last_update = now
      else
        new_last_update = last_update + math.floor(new_tokens * 1000 / refill_rate)
      end

      redis.call("HSET", KEYS[1], "level", final_level, "last_update_ms", new_last_update)
      redis.call("HDEL", KEYS[1], "last_update")
      -- Set TTL to time needed to refill to capacity plus a small buffer
      local time_to_full = math.ceil((capacity - final_level) / refill_rate)
      local ttl = time_to_full + 60 -- Add 60 second buffer
      redis.call("EXPIRE", KEYS[1], ttl)
      return {1, final_level} -- Allow with new level
    else
      -- Time in ms until the bucket holds enough tokens to pay `cost`.
      -- Integer ceiling division so the wait never rounds down into one that
      -- is still too short, floored at 1ms.
      local deficit = cost - current_tokens
      return {0, math.max(math.floor((deficit * 1000 + refill_rate - 1) / refill_rate), 1)}
    end
    """
  end
end
