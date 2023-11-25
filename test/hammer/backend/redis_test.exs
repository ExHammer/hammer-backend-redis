defmodule Hammer.Backend.RedisTest do
  use ExUnit.Case

  @pool Hammer.Backend.Redix.Pool

  setup do
    start_supervised!({Hammer.Backend.Redis, redis_url: "redis://localhost:6379"})
    {:ok, "OK"} = :poolboy.transaction(@pool, &Redix.command(&1, ["FLUSHALL"]))
    :ok
  end

  defp bucket, do: "bucket:#{System.unique_integer([:positive])}"

  defp make_redis_key(id, scale) do
    bucket = div(System.system_time(:millisecond), scale)
    "Hammer:#{id}:#{bucket}"
  end

  test "count_hit, insert" do
    bucket = bucket()
    scale = :timer.hours(10)

    assert {:allow, 1} = Hammer.check_rate(bucket, scale, _limit = 5)
    assert {:allow, 2} = Hammer.check_rate(bucket, scale, _limit = 5)

    assert {:ok, ["count", "2", "created", _, "updated", _]} =
             :poolboy.transaction(
               @pool,
               &Redix.command(&1, ["HGETALL", make_redis_key(bucket, scale)])
             )
  end

  test "count_hit, insert, with custom increment" do
    bucket = bucket()
    scale = :timer.hours(10)
    inc = :rand.uniform(100)
    inc_str = Integer.to_string(inc)

    assert {:allow, ^inc} = Hammer.check_rate_inc(bucket, scale, _limit = 100, inc)

    assert {:ok, ["count", ^inc_str, "created", _, "updated", _]} =
             :poolboy.transaction(
               @pool,
               &Redix.command(&1, ["HGETALL", make_redis_key(bucket, scale)])
             )
  end

  test "count_hit, update" do
    bucket = bucket()
    scale = :timer.hours(10)

    {:allow, 1} = Hammer.check_rate(bucket, scale, _limit = 5)
    :timer.sleep(100)
    {:allow, 2} = Hammer.check_rate(bucket, scale, _limit = 5)

    assert {:ok, ["count", "2", "created", created, "updated", updated]} =
             :poolboy.transaction(
               @pool,
               &Redix.command(&1, ["HGETALL", make_redis_key(bucket, scale)])
             )

    refute updated == created
    assert_in_delta String.to_integer(updated), String.to_integer(created), 200
  end

  test "get_bucket" do
    bucket = bucket()
    scale = :timer.hours(10)
    limit = 300

    inc_before = :rand.uniform(100)
    inc_after = :rand.uniform(100)
    inc_total = inc_before + inc_after

    {:allow, ^inc_before} = Hammer.check_rate_inc(bucket, scale, limit, inc_before)
    :timer.sleep(100)
    {:allow, ^inc_total} = Hammer.check_rate_inc(bucket, scale, limit, inc_after)

    assert {:ok, {^inc_total, left, _, _, _}} = Hammer.inspect_bucket(bucket, scale, limit)
    assert left == 300 - inc_total
  end

  test "delete buckets" do
    bucket = bucket()
    scale = :timer.hours(10)

    {:allow, 1} = Hammer.check_rate(bucket, scale, _limit = 10)
    assert {:ok, 1} = Hammer.delete_buckets(bucket)
    assert {:ok, []} = :poolboy.transaction(@pool, &Redix.command(&1, ["KEYS", "*"]))
  end

  test "delete buckets with no keys matching" do
    scale = :timer.hours(10)

    {:allow, 1} = Hammer.check_rate(bucket(), scale, _limit = 10)
    {:allow, 1} = Hammer.check_rate(bucket(), scale, _limit = 10)

    assert {:ok, 0} = Hammer.delete_buckets("foobar")

    # Previous keys remain untouched
    assert {:ok, ["Hammer:bucket:" <> _, "Hammer:bucket:" <> _]} =
             :poolboy.transaction(@pool, &Redix.command(&1, ["KEYS", "*"]))
  end

  test "delete buckets when many buckets exist" do
    scale = :timer.hours(10)

    for _ <- 1..1000 do
      {:allow, 1} = Hammer.check_rate(bucket(), scale, _limit = 10)
    end

    assert {:ok, 1_000} = Hammer.delete_buckets("bucket")
    assert {:ok, []} = :poolboy.transaction(@pool, &Redix.command(&1, ["KEYS", "*"]))
  end

  test "delete buckets when scan returns empty list but valid cursor" do
    # By writing only one key to the keyspace, most iterations of the SCAN call
    # will return a valid cursor but an empty list. The valid cursor should
    # make the delete_buckets call iterate until the intended key is found
    scale = :timer.hours(10)
    limit = 10

    bucket = bucket()
    {:allow, 1} = Hammer.check_rate(bucket, scale, limit)

    for _ <- 1..1000 do
      {:allow, 1} = Hammer.check_rate(bucket(), scale, limit)
    end

    assert {:ok, 1} = Hammer.delete_buckets(bucket)
    assert {:ok, keys} = :poolboy.transaction(@pool, &Redix.command(&1, ["KEYS", "*"]))
    assert length(keys) == 1000
  end
end
