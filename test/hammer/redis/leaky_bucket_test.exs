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

  describe "get" do
    test "get returns the count set for the given key and scale", %{key: key} do
      leak_rate = :timer.seconds(10)
      capacity = 10

      assert RateLimitLeakyBucket.get(key, leak_rate) == 0
      assert {:allow, 3} = RateLimitLeakyBucket.hit(key, leak_rate, capacity, 3)
      assert RateLimitLeakyBucket.get(key, leak_rate) == 3
    end
  end
end
