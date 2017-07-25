defmodule HammerBackendRedisTest do
  use ExUnit.Case
  import Mock

  @fake_redix :fake_redix

  setup _context do
    with_mock Redix, [start_link: fn(_c) -> {:ok, @fake_redix} end] do
      {:ok, _pid} = Hammer.Backend.Redis.start_link(expiry_ms: 60_000)
    end
    {:ok, []}
  end

  test "count_hit, first" do
    with_mock Redix, [
      command: fn(_r, _c) -> {:ok, 0} end,
      pipeline: fn(_r, _c) -> {:ok,["OK","QUEUED","QUEUED","QUEUED","QUEUED",["OK",1,1,1]]} end
    ] do
      assert {:ok, 1} = Hammer.Backend.Redis.count_hit({1, "one"}, 123)
      assert called Redix.command(@fake_redix, ["EXISTS", "Hammer:Redis:one:1"])
      assert called Redix.pipeline(
        @fake_redix, [
          ["MULTI"],
          [
            "HMSET", "Hammer:Redis:one:1",
            "bucket", 1,
            "id", "one",
            "count", 1,
            "created", 123,
            "updated", 123
          ],
          [
            "SADD", "Hammer:Redis:Buckets:one", "Hammer:Redis:one:1"
          ],
          [
            "EXPIRE", "Hammer:Redis:one:1", 61
          ],
          [
            "EXPIRE", "Hammer:Redis:Buckets:one", 61
          ],
          ["EXEC"]
        ]
      )
    end
  end

  test "count_hit, after" do
    with_mock Redix, [
      command: fn(_r, _c) -> {:ok, 1} end,
      pipeline: fn(_r, _c) -> {:ok,[42,0]} end
    ] do
      assert {:ok, 42} = Hammer.Backend.Redis.count_hit({1, "one"}, 123)
      assert called Redix.command(@fake_redix, ["EXISTS", "Hammer:Redis:one:1"])
    end
  end


  # test "get_bucket" do

  # end

  # test "delete buckets" do

  # end

end
