defmodule Hammer.Redis.SlidingWindowTest do
  use ExUnit.Case, async: true

  @moduletag :redis

  defmodule RateLimit do
    @moduledoc false
    use Hammer, backend: Hammer.Redis, algorithm: :sliding_window
  end

  setup do
    start_supervised!({RateLimit, url: "redis://localhost:6379"})
    key = "key#{:rand.uniform(1_000_000)}"

    {:ok, %{key: key}}
  end

  defp redis_all(key, conn \\ RateLimit) do
    keys = Redix.command!(conn, ["KEYS", "Hammer.Redis.SlidingWindowTest.RateLimit:#{key}*"])

    Enum.map(keys, fn key ->
      {key, Redix.command!(conn, ["ZCARD", key])}
    end)
  end

  defp clean_keys(conn \\ RateLimit) do
    keys = Redix.command!(conn, ["KEYS", "Hammer.Redis.SlidingWindowTest.RateLimit*"])

    to_delete =
      Enum.map(keys, fn key ->
        ["DEL", key]
      end)

    Redix.pipeline!(RateLimit, to_delete)
  end

  test "key prefix is set to the module name by default", %{key: key} do
    scale = :timer.seconds(10)
    limit = 5

    RateLimit.hit(key, scale, limit)

    assert [{"Hammer.Redis.SlidingWindowTest.RateLimit:" <> _, 1}] = redis_all(key)
    clean_keys()
  end

  test "key has expirytime set", %{key: key} do
    scale = :timer.seconds(10)
    limit = 5

    RateLimit.hit(key, scale, limit)
    [{redis_key, 1}] = redis_all(key)

    expected_expiretime = div(System.system_time(:second), 10) * 10 + 10
    expiretime = Redix.command!(RateLimit, ["EXPIRETIME", redis_key])
    assert expiretime - expected_expiretime <= 10

    clean_keys()
  end

  describe "hit when increment == 1" do
    test "returns {:allow, 1} tuple on first access", %{key: key} do
      scale = :timer.seconds(10)
      limit = 10

      assert {:allow, 1} = RateLimit.hit(key, scale, limit)
    end

    test "returns {:allow, 4} tuple on in-limit checks", %{key: key} do
      scale = :timer.minutes(10)
      limit = 10

      assert {:allow, 1} = RateLimit.hit(key, scale, limit)
      assert {:allow, 2} = RateLimit.hit(key, scale, limit)
      assert {:allow, 3} = RateLimit.hit(key, scale, limit)
      assert {:allow, 4} = RateLimit.hit(key, scale, limit)

      clean_keys()
    end

    test "returns expected tuples on mix of in-limit and out-of-limit checks", %{key: key} do
      scale = :timer.minutes(10)
      limit = 2

      assert {:allow, 1} = RateLimit.hit(key, scale, limit)
      assert {:allow, 2} = RateLimit.hit(key, scale, limit)
      assert {:deny, _wait} = RateLimit.hit(key, scale, limit)
      assert {:deny, _wait} = RateLimit.hit(key, scale, limit)
      clean_keys()
    end

    @tag :slow
    test "returns expected tuples after waiting for the next window", %{key: key} do
      scale = :timer.seconds(1)
      limit = 2

      assert {:allow, 1} = RateLimit.hit(key, scale, limit)
      assert {:allow, 2} = RateLimit.hit(key, scale, limit)
      assert {:deny, wait} = RateLimit.hit(key, scale, limit)

      :timer.sleep(wait)

      assert {:allow, 1} = RateLimit.hit(key, scale, limit)
      assert {:allow, 2} = RateLimit.hit(key, scale, limit)
      assert {:deny, _wait} = RateLimit.hit(key, scale, limit)
      clean_keys()
    end
  end

  describe "hit when increment > 1" do
    test "returns {:allow, increment} tuple on first access", %{key: key} do
      scale = :timer.seconds(10)
      limit = 10
      increment = 5

      assert {:allow, increment} == RateLimit.hit(key, scale, limit, increment)
    end

    test "returns {:allow, tries * increment} tuple on in-limit checks", %{key: key} do
      scale = :timer.minutes(10)
      limit = 10
      increment = 2

      assert {:allow, 2} == RateLimit.hit(key, scale, limit, increment)
      assert {:allow, 4} == RateLimit.hit(key, scale, limit, increment)
      assert {:allow, 6} == RateLimit.hit(key, scale, limit, increment)
      assert {:allow, 8} == RateLimit.hit(key, scale, limit, increment)
      assert {:allow, 10} == RateLimit.hit(key, scale, limit, increment)
      assert {:deny, _} = RateLimit.hit(key, scale, limit, increment)

      clean_keys()
    end

    test "returns expected tuples on mix of in-limit and out-of-limit checks", %{key: key} do
      scale = :timer.minutes(10)
      limit = 6

      assert {:allow, 3} == RateLimit.hit(key, scale, limit, 3)
      assert {:allow, 5} == RateLimit.hit(key, scale, limit, 2)
      assert {:deny, _wait} = RateLimit.hit(key, scale, limit, 2)
      assert {:deny, _wait} = RateLimit.hit(key, scale, limit, 10)
      assert {:allow, 6} == RateLimit.hit(key, scale, limit, 1)
      assert {:deny, _wait} = RateLimit.hit(key, scale, limit, 3)
      clean_keys()
    end

    @tag :slow
    test "returns expected tuples after waiting for the next window", %{key: key} do
      scale = :timer.seconds(1)
      limit = 4
      increment = 2

      assert {:allow, 2} == RateLimit.hit(key, scale, limit, increment)
      assert {:allow, 4} == RateLimit.hit(key, scale, limit, increment)
      assert {:deny, wait} = RateLimit.hit(key, scale, limit, increment)

      :timer.sleep(wait)

      assert {:allow, 2} == RateLimit.hit(key, scale, limit, increment)
      assert {:allow, 4} == RateLimit.hit(key, scale, limit, increment)
      assert {:deny, _wait} = RateLimit.hit(key, scale, limit, increment)
      clean_keys()
    end
  end

  describe "inc" do
    test "increments the count for the given key and scale", %{key: key} do
      scale = :timer.seconds(10)

      assert RateLimit.get(key, scale) == 0

      assert RateLimit.inc(key, scale) == 1
      assert RateLimit.get(key, scale) == 1

      assert RateLimit.inc(key, scale) == 2
      assert RateLimit.get(key, scale) == 2

      assert RateLimit.inc(key, scale) == 3
      assert RateLimit.get(key, scale) == 3

      assert RateLimit.inc(key, scale) == 4
      assert RateLimit.get(key, scale) == 4
      clean_keys()
    end
  end

  describe "get/set" do
    test "get returns the count set for the given key and scale", %{key: key} do
      scale = :timer.seconds(10)
      count = 10
      new_count = 2

      assert RateLimit.get(key, scale) == 0

      assert RateLimit.set(key, scale, count) == count
      assert RateLimit.get(key, scale) == count

      assert RateLimit.set(key, scale, new_count) == new_count
      assert RateLimit.get(key, scale) == new_count

      clean_keys()
    end
  end

  describe "one set shared by hit, inc, set and get" do
    test "get/2 sees hits", %{key: key} do
      scale = :timer.hours(1)

      assert {:allow, 1} = RateLimit.hit(key, scale, 5)
      assert {:allow, 2} = RateLimit.hit(key, scale, 5)
      assert RateLimit.get(key, scale) == 2
      clean_keys()
    end

    test "hit/4 counts inc/3 and set/3", %{key: key} do
      scale = :timer.hours(1)

      assert RateLimit.inc(key, scale, 2) == 2
      assert {:allow, 3} = RateLimit.hit(key, scale, 5)

      assert RateLimit.set(key, scale, 5) == 5
      assert {:deny, _} = RateLimit.hit(key, scale, 5)
      assert RateLimit.get(key, scale) == 5
      clean_keys()
    end

    test "set/3 to 0 clears the window", %{key: key} do
      scale = :timer.hours(1)

      assert RateLimit.inc(key, scale, 3) == 3
      assert RateLimit.set(key, scale, 0) == 0
      assert RateLimit.get(key, scale) == 0
      assert {:allow, 1} = RateLimit.hit(key, scale, 1)
      clean_keys()
    end

    test "inc/3 and set/3 expire the set after one window", %{key: key} do
      scale = :timer.seconds(10)

      RateLimit.inc(key, scale)
      [{full_key, 1}] = redis_all(key)
      assert Redix.command!(RateLimit, ["PTTL", full_key]) in 9_000..10_000

      RateLimit.set(key, scale, 3)
      assert Redix.command!(RateLimit, ["PTTL", full_key]) in 9_000..10_000
      clean_keys()
    end

    test "get/2 and inc/3 ignore requests that left the window", %{key: key} do
      scale = 200

      assert RateLimit.inc(key, scale, 3) == 3
      :timer.sleep(250)

      assert RateLimit.get(key, scale) == 0
      assert RateLimit.inc(key, scale) == 1
      clean_keys()
    end
  end

  describe "millisecond precision" do
    test "a sub-second window is enforced and slides", %{key: key} do
      scale = 500

      assert {:allow, 1} = RateLimit.hit(key, scale, 2)
      assert {:allow, 2} = RateLimit.hit(key, scale, 2)
      assert {:deny, retry_after} = RateLimit.hit(key, scale, 2)
      assert retry_after in 1..500

      :timer.sleep(retry_after)
      assert {:allow, _} = RateLimit.hit(key, scale, 2)
      clean_keys()
    end

    test "the deny wait is until the oldest request leaves the window", %{key: key} do
      scale = 1000

      assert {:allow, 1} = RateLimit.hit(key, scale, 2)
      :timer.sleep(400)
      assert {:allow, 2} = RateLimit.hit(key, scale, 2)
      assert {:deny, retry_after} = RateLimit.hit(key, scale, 2)

      # The first request leaves the window ~600ms from now, not the second's 1000ms
      assert retry_after in 500..610

      :timer.sleep(retry_after)
      assert {:allow, 2} = RateLimit.hit(key, scale, 2)
      clean_keys()
    end

    test "a larger increment waits for as many requests to leave", %{key: key} do
      scale = 1000

      assert {:allow, 1} = RateLimit.hit(key, scale, 3)
      :timer.sleep(400)
      assert {:allow, 3} = RateLimit.hit(key, scale, 3, 2)
      assert {:deny, retry_after} = RateLimit.hit(key, scale, 3, 2)

      # Two slots are needed, so the second-oldest request (1000ms) must leave
      assert retry_after in 900..1000
      clean_keys()
    end

    test "an increment larger than the limit is denied for a full window", %{key: key} do
      assert {:deny, 1000} = RateLimit.hit(key, 1000, 2, 3)
    end

    test "sleeping the advertised wait is always sufficient", %{key: key} do
      for scale <- [100, 250, 700], limit <- [1, 3] do
        key = "#{key}:#{scale}:#{limit}"

        for _ <- 1..limit, do: assert({:allow, _} = RateLimit.hit(key, scale, limit))
        assert {:deny, retry_after} = RateLimit.hit(key, scale, limit)

        :timer.sleep(retry_after)
        assert {:allow, _} = RateLimit.hit(key, scale, limit)
      end

      clean_keys()
    end

    test "rapid hits are each counted", %{key: key} do
      scale = :timer.hours(1)

      for n <- 1..50, do: assert({:allow, ^n} = RateLimit.hit(key, scale, 100))
      assert RateLimit.get(key, scale) == 50
      clean_keys()
    end

    test "entries written with whole-second scores are still counted", %{key: key} do
      scale = :timer.hours(1)
      [now_s, _] = Redix.command!(RateLimit, ["TIME"])

      Redix.command!(RateLimit, [
        "ZADD",
        "Hammer.Redis.SlidingWindowTest.RateLimit:#{key}:#{scale}",
        now_s,
        "legacy"
      ])

      assert {:allow, 2} = RateLimit.hit(key, scale, 2)
      assert {:deny, _} = RateLimit.hit(key, scale, 2)
      clean_keys()
    end
  end

  defp poison_keys(key) do
    keys =
      Redix.command!(RateLimit, ["KEYS", "Hammer.Redis.SlidingWindowTest.RateLimit:#{key}*"])

    Enum.each(keys, &Redix.command!(RateLimit, ["SET", &1, "not-a-zset"]))
  end

  describe "redis command errors" do
    test "hit raises Redix.Error instead of misreporting a deny", %{key: key} do
      scale = :timer.hours(1)

      assert {:allow, 1} = RateLimit.hit(key, scale, 10)
      poison_keys(key)

      assert_raise Redix.Error, fn -> RateLimit.hit(key, scale, 10) end
      clean_keys()
    end

    test "inc raises Redix.Error instead of returning the error as a count", %{key: key} do
      scale = :timer.hours(1)

      assert RateLimit.inc(key, scale) == 1
      poison_keys(key)

      assert_raise Redix.Error, fn -> RateLimit.inc(key, scale) end
      clean_keys()
    end

    test "set raises Redix.Error instead of returning the error as a count", %{key: key} do
      scale = :timer.hours(1)

      assert RateLimit.set(key, scale, 3) == 3
      poison_keys(key)

      assert_raise Redix.Error, fn -> RateLimit.set(key, scale, 3) end
      clean_keys()
    end
  end
end
