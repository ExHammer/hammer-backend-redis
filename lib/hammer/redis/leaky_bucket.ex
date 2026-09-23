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

  ## The algorithm:

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

  ## Common use cases include:

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

  ## Example usage:

      defmodule MyApp.RateLimit do
        use Hammer, backend: Hammer.Redis, algorithm: :leaky_bucket
      end

      MyApp.RateLimit.start_link([])

      # Allow 100 requests/sec leak rate with max capacity of 500
      MyApp.RateLimit.hit("user_123", 100, 500, 1)
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
          timeout :: timeout()
        ) :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(connection_name, prefix, key, leak_rate, capacity, cost, timeout) do
    [allowed, value] =
      case Redix.command(
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

      {:error, error} ->
        raise error
    end
  end

  @compile inline: [redis_key: 2]
  defp redis_key(prefix, key) do
    "#{prefix}:#{key}"
  end

  defp redis_script do
    """
    -- Current time in milliseconds. Whole-second resolution only leaks when
    -- the second rolls over, so a sub-second wait can't be expressed and a
    -- caller retrying on one is denied until the next second.
    local time = redis.call("TIME")
    local now = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)

    local capacity = tonumber(ARGV[1])
    local leak_rate = tonumber(ARGV[2])
    local cost = tonumber(ARGV[3])

    -- Get current bucket state. Buckets written before the switch to
    -- milliseconds only carry `last_update` in seconds; convert it once.
    local bucket = redis.call("HMGET", KEYS[1], "level", "last_update_ms", "last_update")
    local current_level = tonumber(bucket[1]) or 0 -- Default to empty if new
    local last_update = tonumber(bucket[2])
    if not last_update then
      local legacy = tonumber(bucket[3])
      last_update = legacy and legacy * 1000 or now
    end

    -- Leak whole units only, so the stored level stays an integer
    local elapsed = math.max(0, now - last_update)
    local leaked = math.floor(elapsed * leak_rate / 1000)
    local new_level = math.max(0, current_level - leaked)

    if new_level < capacity then
      -- Advance the clock only by the time whose leak was actually applied,
      -- so the sub-unit remainder carries into the next hit. When the leak
      -- drained the bucket the surplus is discarded and the clock snaps to
      -- `now`, otherwise a long-idle bucket banks unbounded leak.
      local new_last_update
      if new_level == 0 and leaked > 0 then
        new_last_update = now
      else
        new_last_update = last_update + math.floor(leaked * 1000 / leak_rate)
      end

      new_level = new_level + cost
      redis.call("HSET", KEYS[1], "level", new_level, "last_update_ms", new_last_update)
      redis.call("HDEL", KEYS[1], "last_update")
      -- Set TTL to time needed to leak current level plus a small buffer
      local time_to_empty = math.ceil(new_level / leak_rate)
      local ttl = time_to_empty + 60 -- Add 60 second buffer
      redis.call("EXPIRE", KEYS[1], ttl)
      return {1, new_level}
    else
      -- Time in ms until the level drops below capacity, which is when the
      -- next hit is allowed. Integer ceiling division so the wait never
      -- rounds down into one that is still too short, floored at 1ms.
      local excess = new_level - capacity + 1
      return {0, math.max(math.floor((excess * 1000 + leak_rate - 1) / leak_rate), 1)}
    end
    """
  end
end
