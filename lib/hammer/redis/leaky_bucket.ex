defmodule Hammer.Redis.LeakyBucket do
  @moduledoc """
  This module implements the Leaky Bucket algorithm.

  The leaky bucket algorithm works by modeling a bucket that:
  - Fills up with requests at the input rate
  - "Leaks" requests at a constant rate
  - Has a maximum capacity (the bucket size)

  For example, with a leak rate of 10 requests/second and bucket size of 100:
  - Requests add to the bucket's current level
  - The bucket leaks 10 requests per second steadily
  - If bucket reaches capacity (100), new requests are denied
  - Once bucket level drops, new requests are allowed again

  The algorithm:
  1. When a request comes in, we:
     - Calculate how much has leaked since last request
     - Subtract leaked amount from current bucket level
     - Try to add new request to bucket
     - Store new bucket level and timestamp
  2. To check if rate limit is exceeded:
     - If new bucket level <= capacity: allow request
     - If new bucket level > capacity: deny and return time until enough leaks
  3. Old entries are automatically cleaned up after expiration

  This provides smooth rate limiting with ability to handle bursts up to bucket size.
  The leaky bucket is a good choice when:

  - You need to enforce a constant processing rate
  - Want to allow temporary bursts within bucket capacity
  - Need to smooth out traffic spikes
  - Want to prevent resource exhaustion

  Common use cases include:

  - API rate limiting needing consistent throughput
  - Network traffic shaping
  - Service protection from sudden load spikes
  - Queue processing rate control
  - Scenarios needing both burst tolerance and steady-state limits

  The main advantages are:
  - Smooth, predictable output rate
  - Configurable burst tolerance
  - Natural queueing behavior

  The tradeoffs are:
  - More complex implementation than fixed windows
  - Need to track last request time and current bucket level
  - May need tuning of bucket size and leak rate parameters

  For example, with 100 requests/sec limit and 500 bucket size:
  - Can handle bursts of up to 500 requests
  - But long-term average rate won't exceed 100/sec
  - Provides smoother traffic than fixed windows
  """

  @doc """
  Checks if a key is allowed to perform an action, and increment the counter by the given amount.
  """
  @spec hit(
          connection_name :: atom(),
          prefix :: String.t(),
          key :: String.t(),
          leak_rate :: pos_integer(),
          capacity :: pos_integer(),
          cost :: pos_integer(),
          timeout :: non_neg_integer()
        ) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(connection_name, prefix, key, leak_rate, capacity, cost, timeout) do
    {:ok, [allowed, value]} =
      Redix.command(
        connection_name,
        [
          "EVAL",
          redis_script(),
          "1",
          redis_key(prefix, key),
          capacity,
          leak_rate,
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
    res =
      Redix.command(
        connection_name,
        [
          "HGET",
          redis_key(prefix, key),
          "level"
        ],
        timeout: timeout
      )

    case res do
      {:ok, nil} ->
        0

      {:ok, level} ->
        String.to_integer(level)

      _ ->
        0
    end
  end

  @compile inline: [redis_key: 2]
  defp redis_key(prefix, key) do
    "#{prefix}:#{key}"
  end

  defp redis_script do
    """
    -- Get current time in seconds
    local now = redis.call("TIME")[1]

    -- Get current bucket state
    local bucket = redis.call("HMGET", KEYS[1], "level", "last_update")
    local current_level = tonumber(bucket[1]) or 0 -- Default to capacity if new
    local last_update = tonumber(bucket[2]) or now
    local capacity = tonumber(ARGV[1])

    -- Calculate leak amount since last update
    local elapsed = now - last_update
    local leak_amount = elapsed * ARGV[2] -- leak_rate per second

    -- Update bucket level
    local new_level = math.max(0, current_level - leak_amount)

    -- Try to consume tokens
    local cost = tonumber(ARGV[3])
    if new_level < capacity then
      new_level = new_level + cost
      redis.call("HMSET", KEYS[1], "level", new_level, "last_update", now)
      -- Set TTL to time needed to leak current level plus a small buffer
      local time_to_empty = math.ceil(new_level / ARGV[2])
      local ttl = time_to_empty + 60 -- Add 60 second buffer
      redis.call("EXPIRE", KEYS[1], ttl)
      return {1, new_level}
    else
      -- Calculate time until enough tokens available
      local time_needed = (cost - new_level) / ARGV[2]
      return {0, math.ceil(time_needed * 1000)} -- Deny with ms wait time
    end
    """
  end
end