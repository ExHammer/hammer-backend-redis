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

      MyApp.RateLimit.start_link(clean_period: :timer.minutes(1))

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
          timeout :: non_neg_integer()
        ) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(connection_name, prefix, key, refill_rate, capacity, cost, timeout) do
    {:ok, [allowed, value]} =
      Redix.command(
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
      )

    if allowed == 1 do
      {:allow, value}
    else
      {:deny, 1000}
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
          timeout :: non_neg_integer()
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

      _ ->
        0
    end
  end

  defp redis_script do
    """
    -- Get current time in seconds
    local now = redis.call("TIME")[1]

    -- Get current bucket state
    local bucket = redis.call("HMGET", KEYS[1], "level", "last_update")
    local current_level = tonumber(bucket[1]) or ARGV[1] -- Default to capacity if new
    local last_update = tonumber(bucket[2]) or now

    -- Calculate tokens to add since last update
    local elapsed = now - last_update
    local new_tokens = math.floor(elapsed * ARGV[2]) -- refill_rate per second
    local capacity = tonumber(ARGV[1])
    local current_tokens = math.min(capacity, current_level + new_tokens)

    -- Try to consume tokens
    local cost = tonumber(ARGV[3])
    if current_tokens >= cost then
      local final_level = current_tokens - cost
      redis.call("HMSET", KEYS[1], "level", final_level, "last_update", now)
      -- Set TTL to time needed to refill to capacity plus a small buffer
      local time_to_full = math.ceil((capacity - final_level) / ARGV[2])
      local ttl = time_to_full + 60 -- Add 60 second buffer
      redis.call("EXPIRE", KEYS[1], ttl)
      return {1, final_level} -- Allow with new level
    else
      -- Calculate time until enough tokens available
      local tokens_needed = cost - current_tokens
      local time_needed = tokens_needed / ARGV[2]
      return {0, math.ceil(time_needed * 1000)} -- Deny with ms wait time
    end
    """
  end
end
