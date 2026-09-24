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

    test "returns the retry time computed by Redis", %{key: key} do
      refill_rate = 1
      capacity = 10

      assert {:allow, 0} = RateLimitTokenBucket.hit(key, refill_rate, capacity, capacity)

      assert {:deny, retry_after} =
               RateLimitTokenBucket.hit(key, refill_rate, capacity, capacity)

      assert retry_after > 1000
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

  describe "millisecond refill" do
    test "returns a sub-second wait when refill_rate exceeds 1 token/sec", %{key: key} do
      assert {:allow, 0} = RateLimitTokenBucket.hit(key, 55, 1, 1)
      assert {:deny, retry_after} = RateLimitTokenBucket.hit(key, 55, 1, 1)

      # ceil(1000 / 55)
      assert retry_after in 1..19
    end

    test "sleeping the advertised wait is always sufficient", %{key: key} do
      for refill_rate <- [1, 3, 7, 55, 100, 333],
          capacity <- [1, 5],
          cost <- Enum.uniq([1, capacity]) do
        key = "#{key}:#{refill_rate}:#{capacity}:#{cost}"

        # At high rates tokens refill between calls, so hit until denied.
        # Rates are kept low enough that a token takes longer than a round-trip.
        retry_after = hit_until_denied(key, refill_rate, capacity, cost, 100)
        assert retry_after >= 1

        :timer.sleep(retry_after)

        assert {:allow, _} = RateLimitTokenBucket.hit(key, refill_rate, capacity, cost),
               "refill_rate=#{refill_rate} capacity=#{capacity} cost=#{cost} " <>
                 "slept #{retry_after}ms and was still denied"
      end
    end

    test "sustains refill_rate when it exceeds capacity", %{key: key} do
      refill_rate = 100
      capacity = 2
      deadline = System.monotonic_time(:millisecond) + 500

      allowed = drain(key, refill_rate, capacity, deadline, 0)

      # 2 from the initial burst + ~50 refilled in 500ms. Whole-second refill
      # allowed only the initial burst.
      assert allowed >= 30
    end

    test "carries the sub-token remainder across hits", %{key: key} do
      now = redis_now_ms()
      seeded = now - 1500
      seed(key, 0, seeded)

      assert {:allow, 0} = RateLimitTokenBucket.hit(key, 1, 10, 1)

      # One token credited for 1000ms; the remaining ~500ms is kept.
      assert stored_last_update_ms(key) == seeded + 1000
    end

    test "snaps the clock to now when the refill overflows the bucket", %{key: key} do
      seeded = redis_now_ms() - 60_000
      seed(key, 0, seeded)

      assert {:allow, 4} = RateLimitTokenBucket.hit(key, 1, 5, 1)
      assert stored_last_update_ms(key) >= seeded + 60_000
    end

    test "migrates a bucket written with a seconds last_update", %{key: key} do
      now_s = div(redis_now_ms(), 1000)

      Redix.command!(RateLimitTokenBucket, [
        "HSET",
        full_key(key),
        "level",
        0,
        "last_update",
        now_s - 2
      ])

      # 2 seconds at 1 token/sec credits 2 tokens, not billions.
      assert {:allow, 1} = RateLimitTokenBucket.hit(key, 1, 10, 1)
      assert stored_last_update_ms(key) == (now_s - 2) * 1000 + 2000

      assert Redix.command!(RateLimitTokenBucket, ["HEXISTS", full_key(key), "last_update"]) ==
               0
    end
  end

  describe "hit_many" do
    test "consumes from every bucket and returns levels in order", %{key: key} do
      assert {:allow, [4, 8]} =
               RateLimitTokenBucket.hit_many([{"#{key}:a", 1, 5}, {"#{key}:b", 1, 10, 2}])

      assert RateLimitTokenBucket.get("#{key}:a", 1) == 4
      assert RateLimitTokenBucket.get("#{key}:b", 1) == 8
    end

    test "consumes nothing when any bucket denies", %{key: key} do
      assert {:allow, 0} = RateLimitTokenBucket.hit("#{key}:tight", 1, 1, 1)

      assert {:deny, retry_after} =
               RateLimitTokenBucket.hit_many([{"#{key}:loose", 1, 10}, {"#{key}:tight", 1, 1}])

      assert retry_after in 1..1000
      # The allowing bucket was never touched
      assert RateLimitTokenBucket.get("#{key}:loose", 1) == 0
      assert {:allow, 9} = RateLimitTokenBucket.hit("#{key}:loose", 1, 10, 1)
    end

    test "returns the longest wait among the denying buckets", %{key: key} do
      assert {:allow, [0, 0]} =
               RateLimitTokenBucket.hit_many([{"#{key}:fast", 10, 1}, {"#{key}:slow", 1, 3, 3}])

      assert {:deny, retry_after} =
               RateLimitTokenBucket.hit_many([{"#{key}:fast", 10, 1}, {"#{key}:slow", 1, 3, 3}])

      # slow needs 3 tokens at 1/sec; fast needs 1 at 10/sec (100ms)
      assert retry_after > 2000
    end

    test "sleeping the advertised wait lets every bucket allow", %{key: key} do
      buckets = [{"#{key}:burst", 55, 1}, {"#{key}:sustained", 7, 3}]

      assert {:allow, [0, 2]} = RateLimitTokenBucket.hit_many(buckets)
      assert {:allow, _} = RateLimitTokenBucket.hit_many([{"#{key}:sustained", 7, 3, 2}])
      assert {:deny, retry_after} = RateLimitTokenBucket.hit_many(buckets)

      :timer.sleep(retry_after)

      assert {:allow, _} = RateLimitTokenBucket.hit_many(buckets)
    end

    test "a single bucket behaves like hit/4", %{key: key} do
      assert {:allow, [1]} = RateLimitTokenBucket.hit_many([{key, 1, 2}])
      assert {:allow, [0]} = RateLimitTokenBucket.hit_many([{key, 1, 2}])
      assert {:deny, 1000} = RateLimitTokenBucket.hit_many([{key, 1, 2}])
    end

    test "raises on an empty list" do
      assert_raise ArgumentError, ~r/at least one bucket/, fn ->
        RateLimitTokenBucket.hit_many([])
      end
    end

    test "raises when a key is listed twice", %{key: key} do
      assert_raise ArgumentError, ~r/same key more than once/, fn ->
        RateLimitTokenBucket.hit_many([{key, 1, 5}, {key, 1, 10}])
      end
    end

    test "raises on a malformed bucket", %{key: key} do
      assert_raise ArgumentError, ~r/expected \{key, refill_rate, capacity\}/, fn ->
        RateLimitTokenBucket.hit_many([{key, 1}])
      end
    end

    test "is only generated for algorithms that support it" do
      assert function_exported?(RateLimitTokenBucket, :hit_many, 1)

      leaky = Code.ensure_loaded!(Hammer.Redis.LeakyBucketTest.RateLimitLeakyBucket)
      refute function_exported?(leaky, :hit_many, 1)
    end
  end

  describe "get" do
    test "get returns the count set for the given key and scale", %{key: key} do
      refill_rate = 1
      capacity = 10

      assert RateLimitTokenBucket.get(key, refill_rate) == 0

      assert {:allow, _} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 4)
      assert RateLimitTokenBucket.get(key, refill_rate) == 6

      assert {:allow, _} = RateLimitTokenBucket.hit(key, refill_rate, capacity, 3)
      assert RateLimitTokenBucket.get(key, refill_rate) == 3
    end
  end

  describe "redis command errors" do
    test "hit raises Redix.Error on a command error reply", %{key: key} do
      full_key = "Hammer.Redis.TokenBucketTest.RateLimitTokenBucket:#{key}"
      Redix.command!(RateLimitTokenBucket, ["SET", full_key, "not-a-hash"])

      assert_raise Redix.Error, fn -> RateLimitTokenBucket.hit(key, 1, 10) end
    end

    test "get raises Redix.Error instead of returning 0", %{key: key} do
      full_key = "Hammer.Redis.TokenBucketTest.RateLimitTokenBucket:#{key}"
      Redix.command!(RateLimitTokenBucket, ["SET", full_key, "not-a-hash"])

      assert_raise Redix.Error, fn -> RateLimitTokenBucket.get(key, 1) end
    end
  end

  defp drain(key, refill_rate, capacity, deadline, allowed) do
    if System.monotonic_time(:millisecond) >= deadline do
      allowed
    else
      case RateLimitTokenBucket.hit(key, refill_rate, capacity, 1) do
        {:allow, _} ->
          drain(key, refill_rate, capacity, deadline, allowed + 1)

        {:deny, retry_after} ->
          :timer.sleep(retry_after)
          drain(key, refill_rate, capacity, deadline, allowed)
      end
    end
  end

  defp hit_until_denied(_key, _refill_rate, _capacity, _cost, 0) do
    flunk("bucket never denied")
  end

  defp hit_until_denied(key, refill_rate, capacity, cost, attempts) do
    case RateLimitTokenBucket.hit(key, refill_rate, capacity, cost) do
      {:allow, _} -> hit_until_denied(key, refill_rate, capacity, cost, attempts - 1)
      {:deny, retry_after} -> retry_after
    end
  end

  defp full_key(key), do: "Hammer.Redis.TokenBucketTest.RateLimitTokenBucket:#{key}"

  defp redis_now_ms do
    [s, us] = Redix.command!(RateLimitTokenBucket, ["TIME"])
    String.to_integer(s) * 1000 + div(String.to_integer(us), 1000)
  end

  defp seed(key, level, last_update_ms) do
    Redix.command!(RateLimitTokenBucket, [
      "HSET",
      full_key(key),
      "level",
      level,
      "last_update_ms",
      last_update_ms
    ])
  end

  defp stored_last_update_ms(key) do
    RateLimitTokenBucket
    |> Redix.command!(["HGET", full_key(key), "last_update_ms"])
    |> String.to_integer()
  end
end
