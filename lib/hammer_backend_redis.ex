defmodule Hammer.Backend.Redis do
  use GenServer
  @moduledoc """
  Documentation for Hammer.Backend.Redis
  """

  ## Public API

  def start_link() do
    start_link([])
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def stop() do
    GenServer.call(__MODULE__, :stop)
  end

  @doc """
  Setup function, called once when the Hammer server is initialised
  """
  @spec setup(config::map)
        :: :ok
          | {:error, reason::String.t}
  def setup(config) do
    GenServer.call(__MODULE__, {:setup, config})
  end

  @doc """
  Record a hit in the bucket identified by `key`
  """
  @spec count_hit(key::{bucket::integer, id::String.t}, now::integer)
        :: {:ok, count::integer}
         | {:error, reason::String.t}
  def count_hit(key, now) do
    GenServer.call(__MODULE__, {:count_hit, key, now})
  end

  @doc """
  Retrieve information about the bucket identified by `key`
  """
  @spec get_bucket(key::{bucket::integer, id::String.t})
        :: nil
         | {key::{bucket::integer, id::String.t}, count::integer, created::integer, updated::integer}
  def get_bucket(key) do
    GenServer.call(__MODULE__, {:get_bucket, key})
  end

  @doc """
  Delete all buckets associated with `id`.
  """
  @spec delete_buckets(id::String.t)
        :: {:ok, count_deleted::integer}
         | {:error, reason::String.t}
  def delete_buckets(id) do
    GenServer.call(__MODULE__, {:delete_buckets, id})
  end

  @doc """
  Delete 'old' buckets which were last updated before `expire_now`.
  """
  @spec prune_expired_buckets(now::integer, expire_before::integer)
        :: :ok
         | {:error, reason::String.t}
  def prune_expired_buckets(now, expire_before) do
    GenServer.call(__MODULE__, {:prune_expired_buckets, now, expire_before})
  end


  ## GenServer Callbacks

  def init(args) do
    {:ok, redix} = Redix.start_link(args)
    {:ok, %{redix: redix}}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:setup, config}, _from, state) do
    %{expiry: expiry} = config
    {:reply, :ok, Map.merge(state, %{expiry: expiry})}
  end

  def handle_call({:count_hit, key, now}, _from, %{redix: r}=state) do
    {bucket, id} = key
    expiry = get_expiry(state)
    redis_key = make_redis_key(key)
    bucket_set_key = make_bucket_set_key(id)
    case Redix.command(r, ["EXISTS", redis_key]) do
      {:ok, 0} ->
        {bucket, id} = key
        {:ok, ["OK" | _t]} = Redix.pipeline(r, [
          [
            "HMSET", redis_key,
            "bucket", bucket,
            "id", id,
            "count", 0,
            "created", now,
            "updated", now
          ],
          [
            "SADD", bucket_set_key, redis_key
          ],
          [
            "EXPIRE", redis_key, expiry
          ],
          [
            "EXPIRE", bucket_set_key, expiry
          ]
         ])
        {:reply, {:ok, 1}, state}
      {:ok, 1} ->
        # update
        {:ok, [count, 0]} = Redix.pipeline(r, [
          ["HINCRBY", redis_key, "count",   1],
          ["HSET"   , redis_key, "updated", now]
        ])
        {:reply, {:ok, count}, state}
    end
  end

  def handle_call({:get_bucket, key}, _from, %{redix: r}=state) do
    redis_key = make_redis_key(key)
    command = ["HMGET", redis_key, "bucket", "id", "count", "created", "updated"]
    result = case Redix.command(r, command) do
      [nil, nil, nil, nil, nil] ->
        nil
      [_bucket, _id, count, created, updated] ->
        count = String.to_integer(count)
        created = String.to_integer(created)
        updated = String.to_integer(updated)
        {key, count, created, updated}
    end
    {:reply, result, state}
  end

  def handle_call({:delete_buckets, id}, _from, %{redix: r}=state) do
    bucket_set_key = make_bucket_set_key(id)
    count_deleted = case Redix.command(r, ["SMEMBERS", bucket_set_key]) do
      {:ok, []} ->
        0
      {:ok, keys} ->
        {:ok, [count_deleted, _]} = Redix.pipeline(r, [["DEL" | keys], ["DEL", bucket_set_key]])
        count_deleted
    end
    {:reply, {:ok, count_deleted}, state}
  end

  def handle_call({:prune_expired_buckets, _now, _expire_before}, _from, state) do
    # A no-op in this case
    {:reply, :ok, state}
  end

  defp make_redis_key({bucket, id}) do
    "Hammer:Redis:#{id}:#{bucket}"
  end

  defp make_bucket_set_key(id) do
    "Hammer:Redis:Buckets:#{id}"
  end

  defp get_expiry(state) do
    %{expiry: expiry} = state
    expiry + (1000 * 60)
  end

end
