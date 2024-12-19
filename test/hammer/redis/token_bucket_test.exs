defmodule Hammer.Redis.TokenBucketTest do
  use ExUnit.Case, async: true

  @moduletag :redis

  defmodule RateLimitTokenBucket do
    use Hammer, backend: Hammer.Redis, algorithm: :token_bucket
  end

  setup do
    start_supervised!({RateLimitTokenBucket, url: "redis://localhost:6379"})
    key = "key#{:rand.uniform(1_000_000)}"

    {:ok, %{key: key}}
  end

  test "key prefix is set to the module name by default", %{key: key} do
    scale = :timer.seconds(10)
    limit = 5

    RateLimitTokenBucket.hit(key, scale, limit)

    assert Redix.command!(RateLimitTokenBucket, [
             "HGET",
             "Hammer.Redis.TokenBucketTest.RateLimitTokenBucket:#{key}",
             "level"
           ]) == "4"
  end

  describe "hit" do
    test "returns {:allow, 9} tuple on first access", %{key: key} do
      refill_rate = 10
      capacity = 10

      assert {:allow, 9} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
    end

    test "returns {:allow, 6} tuple on in-limit checks", %{key: key} do
      refill_rate = 2
      capacity = 10

      assert {:allow, 9} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
      assert {:allow, 8} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
      assert {:allow, 7} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
      assert {:allow, 6} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
    end

    test "returns expected tuples on mix of in-limit and out-of-limit checks", %{key: key} do
      refill_rate = 1
      capacity = 2

      assert {:allow, 1} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
      assert {:allow, 0} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)

      assert {:deny, 1000} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)

      assert {:deny, _retry_after} =
               RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
    end

    test "returns expected tuples after waiting for the next window", %{key: key} do
      refill_rate = 1
      capacity = 2

      assert {:allow, 1} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
      assert {:allow, 0} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)

      assert {:deny, retry_after} =
               RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)

      :timer.sleep(retry_after)

      assert {:allow, 0} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)

      assert {:deny, _retry_after} =
               RateLimitTokenBucket.hit(key, refill_rate, capacity, 1)
    end
  end

  describe "get" do
    test "get returns the count set for the given key and scale", %{key: key} do
      refill_rate = :timer.seconds(10)
      capacity = 10

      assert RateLimitTokenBucket.get(key, refill_rate) == 0

      assert {:allow, _} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 4)
      assert RateLimitTokenBucket.get(key, refill_rate) == 6

      assert {:allow, _} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 3)
      assert RateLimitTokenBucket.get(key, refill_rate) == 3
    end
  end
end
