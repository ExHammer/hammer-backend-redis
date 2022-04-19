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
    used to set TTL on Redis keys. This configuration is mandatory.
  - `redix_config`: Keyword list of options to the `Redix` redis client,
    also aliased to `redis_config`
  - `redis_url`: String url of redis server to connect to
    (optional, invokes Redix.start_link/2)
  """

  @type bucket_key :: {bucket :: integer, id :: String.t()}
  @type bucket_info ::
          {key :: bucket_key, count :: integer, created :: integer, updated :: integer}

  use GenServer
  @behaviour Hammer.Backend

  ## Public API

  def start do
    start([])
  end

  def start(args) do
    GenServer.start(__MODULE__, args)
  end

  def start_link do
    start_link([])
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @doc """
  Record a hit in the bucket identified by `key`
  """
  @spec count_hit(
          pid :: pid(),
          key :: bucket_key,
          now :: integer
        ) ::
          {:ok, count :: integer}
          | {:error, reason :: any}
  def count_hit(pid, key, now) do
    GenServer.call(pid, {:count_hit, key, now, 1})
  end

  @doc """
  Record a hit in the bucket identified by `key`, with a custom increment
  """
  @spec count_hit(
          pid :: pid(),
          key :: bucket_key,
          now :: integer,
          increment :: integer
        ) ::
          {:ok, count :: integer}
          | {:error, reason :: any}
  def count_hit(pid, key, now, increment) do
    GenServer.call(pid, {:count_hit, key, now, increment})
  end

  @doc """
  Retrieve information about the bucket identified by `key`
  """
  @spec get_bucket(
          pid :: pid(),
          key :: bucket_key
        ) ::
          {:ok, info :: bucket_info}
          | {:ok, nil}
          | {:error, reason :: any}
  def get_bucket(pid, key) do
    GenServer.call(pid, {:get_bucket, key})
  end

  @doc """
  Delete all buckets associated with `id`.
  """
  @spec delete_buckets(
          pid :: pid(),
          id :: String.t()
        ) ::
          {:ok, count_deleted :: integer}
          | {:error, reason :: any}
  def delete_buckets(_pid, _id) do
    raise "Delete operation is not supported"
  end

  ## GenServer Callbacks

  def init(args) do
    expiry_ms = Keyword.get(args, :expiry_ms)

    if !expiry_ms do
      raise RuntimeError, "Missing required config: expiry_ms"
    end

    redix_config =
      Keyword.get(
        args,
        :redix_config,
        Keyword.get(args, :redis_config, [])
      )

    redis_url = System.get_env("HAMMER_REDIS_URI") || Keyword.get(args, :redis_url, nil)

    {:ok, redix} =
      if is_binary(redis_url) && byte_size(redis_url) > 0 do
        Redix.start_link(redis_url, redix_config)
      else
        Redix.start_link(redix_config)
      end

    {:ok, %{redix: redix, expiry_ms: expiry_ms}}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:count_hit, key, now, increment}, _from, %{redix: r} = state) do
    expiry = get_expiry(state)

    result = do_count_hit(r, key, now, increment, expiry)
    {:reply, result, state}
  end

  def handle_call({:get_bucket, key}, _from, %{redix: r} = state) do
    redis_key = make_redis_key(key)
    command = ["HMGET", redis_key, "count", "created", "updated"]

    result =
      case Redix.command(r, command) do
        {:ok, [nil, nil, nil]} ->
          {:ok, nil}

        {:ok, [count, created, updated]} ->
          count = String.to_integer(count)
          created = String.to_integer(created)
          updated = String.to_integer(updated)
          {:ok, {key, count, created, updated}}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, result, state}
  end

  # we are using the first method described (called bucketing)
  # in https://www.youtube.com/watch?v=CRGPbCbRTHA
  # but we add the 'created' and 'updated' meta information fields.
  defp do_count_hit(r, key, now, increment, expiry) do
    redis_key = make_redis_key(key)

    Redix.pipeline(r, [
      ["MULTI"],
      [
        "HINCRBY",
        redis_key,
        "count",
        increment
      ],
      [
        "HSETNX",
        redis_key,
        "created",
        now
      ],
      [
        "HSET",
        redis_key,
        "updated",
        now
      ],
      [
        "EXPIRE",
        redis_key,
        expiry
      ],
      ["EXEC"]
    ])
    |> case do
      {:ok, ["OK", "QUEUED", "QUEUED", "QUEUED", "QUEUED", [new_count, _, _, 1]]} ->
        {:ok, new_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp make_redis_key({bucket, id}) do
    "Hammer:Redis:#{id}:#{bucket}"
  end

  defp get_expiry(state) do
    %{expiry_ms: expiry_ms} = state
    round(expiry_ms / 1000 + 1)
  end
end
