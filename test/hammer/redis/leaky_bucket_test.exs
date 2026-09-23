defmodule Hammer.Redis.LeakyBucketTest do
  use ExUnit.Case, async: true

  @moduletag :redis

  defmodule RateLimitLeakyBucket do
    use Hammer, backend: Hammer.Redis, algorithm: :leaky_bucket
  end

  setup do
    start_supervised!({RateLimitLeakyBucket, url: "redis://localhost:6379"})
    key = "key#{:rand.uniform(1_000_000)}"

    {:ok, %{key: key}}
  end

  test "key prefix is set to the module name by default", %{key: key} do
    scale = :timer.seconds(10)
    limit = 5

    RateLimitLeakyBucket.hit(key, scale, limit)

    assert Redix.command!(RateLimitLeakyBucket, [
             "HGET",
             "Hammer.Redis.LeakyBucketTest.RateLimitLeakyBucket:#{key}",
             "level"
           ]) == "1"
  end

  describe "hit" do
    test "returns {:allow, 1} tuple on first access", %{key: key} do
      leak_rate = :timer.seconds(10)
      capacity = 10

      assert {:allow, 1} = RateLimitLeakyBucket.hit(key, leak_rate, capacity)
    end

    test "returns {:allow, 4} tuple on in-limit checks", %{key: key} do
      leak_rate = 2
      capacity = 10

      assert {:allow, 1} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
      assert {:allow, 2} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
      assert {:allow, 3} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
      assert {:allow, 4} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
    end

    test "returns expected tuples on mix of in-limit and out-of-limit checks", %{key: key} do
      leak_rate = 1
      capacity = 2

      assert {:allow, 1} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
      assert {:allow, 2} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)

      assert {:deny, 1000} =
               RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)

      assert {:deny, _retry_after} =
               RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
    end

    test "returns expected tuples after waiting for the next window", %{key: key} do
      leak_rate = 1
      capacity = 2

      assert {:allow, 1} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
      assert {:allow, 2} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)

      assert {:deny, retry_after} =
               RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)

      :timer.sleep(retry_after)

      assert {:allow, 2} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)

      assert {:deny, _retry_after} =
               RateLimitLeakyBucket.hit(key, leak_rate, capacity, 1)
    end
  end

  describe "millisecond leak" do
    test "returns a sub-second wait when leak_rate exceeds 1 unit/sec", %{key: key} do
      assert {:allow, 1} = RateLimitLeakyBucket.hit(key, 55, 1, 1)
      assert {:deny, retry_after} = RateLimitLeakyBucket.hit(key, 55, 1, 1)

      # ceil(1000 / 55)
      assert retry_after in 1..19
    end

    test "waits only until the level drops below capacity, regardless of cost", %{key: key} do
      seed(key, 10, redis_now_ms())

      assert {:deny, retry_after} = RateLimitLeakyBucket.hit(key, 1, 10, 5)
      # One unit has to leak, not five.
      assert retry_after in 900..1000
    end

    test "sleeping the advertised wait is always sufficient", %{key: key} do
      for leak_rate <- [1, 3, 7, 55, 100, 333],
          capacity <- [1, 5],
          cost <- Enum.uniq([1, capacity]) do
        key = "#{key}:#{leak_rate}:#{capacity}:#{cost}"

        # At high rates units leak between calls, so hit until denied.
        # Rates are kept low enough that a unit takes longer than a round-trip.
        retry_after = hit_until_denied(key, leak_rate, capacity, cost, 100)
        assert retry_after >= 1

        :timer.sleep(retry_after)

        assert {:allow, _} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, cost),
               "leak_rate=#{leak_rate} capacity=#{capacity} cost=#{cost} " <>
                 "slept #{retry_after}ms and was still denied"
      end
    end

    test "carries the sub-unit remainder across hits", %{key: key} do
      seeded = redis_now_ms() - 1500
      seed(key, 5, seeded)

      assert {:allow, 5} = RateLimitLeakyBucket.hit(key, 1, 10, 1)

      # One unit leaked for 1000ms; the remaining ~500ms is kept.
      assert stored_last_update_ms(key) == seeded + 1000
    end

    test "snaps the clock to now when the leak drains the bucket", %{key: key} do
      seeded = redis_now_ms() - 60_000
      seed(key, 3, seeded)

      assert {:allow, 1} = RateLimitLeakyBucket.hit(key, 1, 10, 1)
      assert stored_last_update_ms(key) >= seeded + 60_000
    end

    test "stores an integer level so get/2 keeps working", %{key: key} do
      seed(key, 5, redis_now_ms() - 1500)

      assert {:allow, _} = RateLimitLeakyBucket.hit(key, 1, 10, 1)
      assert RateLimitLeakyBucket.get(key, 1) == 5
    end

    test "migrates a bucket written with a seconds last_update", %{key: key} do
      now_s = div(redis_now_ms(), 1000)

      Redix.command!(RateLimitLeakyBucket, [
        "HSET",
        full_key(key),
        "level",
        5,
        "last_update",
        now_s - 2
      ])

      # 2 seconds at 1 unit/sec leaks 2 units, not billions.
      assert {:allow, 4} = RateLimitLeakyBucket.hit(key, 1, 10, 1)
      assert stored_last_update_ms(key) == (now_s - 2) * 1000 + 2000

      assert Redix.command!(RateLimitLeakyBucket, ["HEXISTS", full_key(key), "last_update"]) ==
               0
    end
  end

  describe "get" do
    test "get returns the count set for the given key and scale", %{key: key} do
      leak_rate = :timer.seconds(10)
      capacity = 10

      assert RateLimitLeakyBucket.get(key, leak_rate) == 0
      assert {:allow, 3} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 3)
      assert RateLimitLeakyBucket.get(key, leak_rate) == 3
    end
  end

  describe "redis command errors" do
    test "hit raises Redix.Error on a command error reply", %{key: key} do
      full_key = "Hammer.Redis.LeakyBucketTest.RateLimitLeakyBucket:#{key}"
      Redix.command!(RateLimitLeakyBucket, ["SET", full_key, "not-a-hash"])

      assert_raise Redix.Error, fn -> RateLimitLeakyBucket.hit(key, 1, 10) end
    end

    test "get raises Redix.Error instead of returning 0", %{key: key} do
      full_key = "Hammer.Redis.LeakyBucketTest.RateLimitLeakyBucket:#{key}"
      Redix.command!(RateLimitLeakyBucket, ["SET", full_key, "not-a-hash"])

      assert_raise Redix.Error, fn -> RateLimitLeakyBucket.get(key, 1) end
    end
  end

  defp hit_until_denied(_key, _leak_rate, _capacity, _cost, 0) do
    flunk("bucket never denied")
  end

  defp hit_until_denied(key, leak_rate, capacity, cost, attempts) do
    case RateLimitLeakyBucket.hit(key, leak_rate, capacity, cost) do
      {:allow, _} -> hit_until_denied(key, leak_rate, capacity, cost, attempts - 1)
      {:deny, retry_after} -> retry_after
    end
  end

  defp full_key(key), do: "Hammer.Redis.LeakyBucketTest.RateLimitLeakyBucket:#{key}"

  defp redis_now_ms do
    [s, us] = Redix.command!(RateLimitLeakyBucket, ["TIME"])
    String.to_integer(s) * 1000 + div(String.to_integer(us), 1000)
  end

  defp seed(key, level, last_update_ms) do
    Redix.command!(RateLimitLeakyBucket, [
      "HSET",
      full_key(key),
      "level",
      level,
      "last_update_ms",
      last_update_ms
    ])
  end

  defp stored_last_update_ms(key) do
    RateLimitLeakyBucket
    |> Redix.command!(["HGET", full_key(key), "last_update_ms"])
    |> String.to_integer()
  end
end
