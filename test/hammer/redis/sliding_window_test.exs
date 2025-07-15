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
end
