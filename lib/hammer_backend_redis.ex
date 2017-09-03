defmodule Hammer.Backend.Redis do

  @moduledoc """
  Documentation for Hammer.Backend.Redis

  This backend uses the [Redix](https://hex.pm/packages/redix) library to connect to Redis.

  The backend process is started by calling `start_link`:

      Hammer.Backend.Redis.start_link(
        expiry_ms: 60_000 * 10,
        redix_config: [host: "example.com", port: 5050]
      )

  Options are:

  - `expiry_ms`: Expiry time of buckets in milliseconds,
    used to set TTL on Redis keys
  - `redix_config`: Keyword list of options to the `Redix` redis client,
    also aliased to `redis_config`
  """

  use GenServer
  @behaviour Hammer.Backend

  ## Public API

  def start do
    start([])
  end

  def start(args) do
    GenServer.start(__MODULE__, args, name: __MODULE__)
  end

  def start_link do
    start_link([])
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def stop do
    GenServer.call(__MODULE__, :stop)
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
        :: {:ok, {key::{bucket::integer, id::String.t},
                  count::integer,
                  created::integer,
                  updated::integer}}
        | {:ok, nil}
        | {:error, reason::any}
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

  ## GenServer Callbacks

  def init(args) do
    expiry_ms = Keyword.get(args, :expiry_ms, 60_000 * 60 * 2)
    redix = Keyword.get(args, :redix_process_name, :hammer_backend_redis_redix)
    {:ok, %{redix: redix, expiry_ms: expiry_ms}}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:count_hit, key, now}, _from, %{redix: r} = state) do
    {bucket, id} = key
    expiry = get_expiry(state)
    redis_key = make_redis_key(key)
    bucket_set_key = make_bucket_set_key(id)
    result = case Redix.command(r, ["EXISTS", redis_key]) do
      {:ok, 0} ->
        {bucket, id} = key
        {
          :ok,
          ["OK", "QUEUED", "QUEUED", "QUEUED", "QUEUED", ["OK", 1, 1, 1]]
        } = Redix.pipeline(
          r,
          [
            ["MULTI"],
            [
              "HMSET", redis_key,
              "bucket", bucket,
              "id", id,
              "count", 1,
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
            ],
            ["EXEC"]
          ]
        )
        {:ok, 1}
      {:ok, 1} ->
        # update
        {:ok, ["OK", "QUEUED", "QUEUED", [count, 0]]} = Redix.pipeline(
          r,
          [
            ["MULTI"],
            ["HINCRBY", redis_key, "count",   1],
            ["HSET"   , redis_key, "updated", now],
            ["EXEC"]
          ]
        )
        {:ok, count}
      {:error, reason} ->
        {:error, reason}
    end
    {:reply, result, state}
  end

  def handle_call({:get_bucket, key}, _from, %{redix: r} = state) do
    redis_key = make_redis_key(key)
    command = ["HMGET", redis_key, "bucket", "id", "count", "created", "updated"]
    result = case Redix.command(r, command) do
      {:ok, [nil, nil, nil, nil, nil]} ->
        {:ok, nil}
      {:ok, [_bucket, _id, count, created, updated]} ->
        count = String.to_integer(count)
        created = String.to_integer(created)
        updated = String.to_integer(updated)
        {:ok, {key, count, created, updated}}
      {:error, reason} ->
        {:error, reason}
    end
    {:reply, result, state}
  end

  def handle_call({:delete_buckets, id}, _from, %{redix: r} = state) do
    bucket_set_key = make_bucket_set_key(id)
    result = case Redix.command(r, ["SMEMBERS", bucket_set_key]) do
      {:ok, []} ->
        {:ok, 0}
      {:ok, keys} ->
        {:ok, [count_deleted, _]} = Redix.pipeline(
          r,
          [["DEL" | keys], ["DEL", bucket_set_key]]
        )
        {:ok, count_deleted}
      {:error, reason} ->
        {:error, reason}
    end
    {:reply, result, state}
  end

  defp make_redis_key({bucket, id}) do
    "Hammer:Redis:#{id}:#{bucket}"
  end

  defp make_bucket_set_key(id) do
    "Hammer:Redis:Buckets:#{id}"
  end

  defp get_expiry(state) do
    %{expiry_ms: expiry_ms} = state
    round((expiry_ms / 1000) + 1)
  end

end
