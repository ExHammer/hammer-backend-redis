defmodule Hammer.Backend.Redis do
  @moduledoc """
  Documentation for Hammer.Backend.Redis

  This backend uses the [Redix](https://hex.pm/packages/redix) library to connect to Redis.

  The backend process is started by calling `start_link`:

      Hammer.Backend.Redis.start_link(
        redix_config: [host: "example.com", port: 5050]
      )

  Options are:

  - `redix_config`: Keyword list of options to the `Redix` redis client,
    also aliased to `redis_config`
  - `redis_url`: String url of redis server to connect to
    (optional, invokes Redix.start_link/2)
  - `pool_size`: `:poolboy`'s `:site` option, defaults to `5`
  - `pool_max_overflow`: `:poolboy`'s `:max_overflow` option, defaults to `2`
  """

  @behaviour Hammer.Backend

  @type bucket_key :: {id :: String.t(), bucket :: integer}
  @type bucket_info :: {count :: integer, created :: integer, updated :: integer}

  @pool Hammer.Backend.Redix.Pool
  @timeout :timer.seconds(60)

  defp pool_args(opts) do
    [
      name: {:local, @pool},
      worker_module: Redix,
      size: opts[:pool_size] || 5,
      max_overflow: opts[:pool_max_overflow] || 2
    ]
  end

  defp worker_args(opts) do
    url = opts[:redis_url]
    config = opts[:redix_config] || opts[:redis_config] || []

    if url do
      url
      |> Redix.URI.to_start_options()
      |> Keyword.merge(config)
    else
      config
    end
  end

  @spec child_spec(Keyword.t()) :: :supervisor.child_spec()
  def child_spec(opts) do
    :poolboy.child_spec(:worker, pool_args(opts), worker_args(opts))
  end

  @spec start_link(Keyword.t()) :: {:ok, pid} | {:error, any}
  def start_link(opts) do
    :poolboy.start_link(pool_args(opts), worker_args(opts))
  end

  @impl Hammer.Backend
  def count_hit(key, increment, expires_at) do
    :poolboy.transaction(
      @pool,
      fn conn -> redix_count_hit(conn, key, increment, expires_at) end,
      @timeout
    )
  end

  @impl Hammer.Backend
  def get_bucket(key) do
    :poolboy.transaction(@pool, fn conn -> redix_get_bucket(conn, key) end, @timeout)
  end

  @impl Hammer.Backend
  def delete_buckets(id) do
    :poolboy.transaction(@pool, fn conn -> redix_delete_buckets(conn, id) end, @timeout)
  end

  defp make_redis_key({id, bucket}), do: "Hammer:#{id}:#{bucket}"
  defp make_redis_key_pattern(id), do: "Hammer:#{id}:*"

  # we are using the first method described (called bucketing)
  # in https://www.youtube.com/watch?v=CRGPbCbRTHA
  # but we add the 'created' and 'updated' meta information fields.
  defp redix_count_hit(conn, key, increment, expires_at) do
    redis_key = make_redis_key(key)
    now = System.system_time(:millisecond)

    cmds = [
      ["MULTI"],
      ["HINCRBY", redis_key, "count", increment],
      ["HSETNX", redis_key, "created", now],
      ["HSET", redis_key, "updated", now],
      ["EXPIRE", redis_key, expires_at],
      ["EXEC"]
    ]

    case Redix.pipeline(conn, cmds) do
      {:ok, ["OK", "QUEUED", "QUEUED", "QUEUED", "QUEUED", [new_count, _, _, 1]]} ->
        {:ok, new_count}

      {:error, _reason} = e ->
        e
    end
  end

  defp redix_get_bucket(conn, key) do
    command = ["HMGET", make_redis_key(key), "count"]

    case Redix.command(conn, command) do
      {:ok, [nil, nil, nil]} -> {:ok, 0}
      {:ok, [count]} -> {:ok, String.to_integer(count)}
      {:error, _reason} = e -> e
    end
  end

  defp redix_delete_buckets(conn, id) do
    do_delete_buckets(conn, make_redis_key_pattern(id), 0, 0)
  end

  defp do_delete_buckets(conn, redis_key_pattern, cursor, count_deleted) do
    case Redix.command(conn, ["SCAN", cursor, "MATCH", redis_key_pattern]) do
      {:ok, ["0", []]} ->
        {:ok, count_deleted}

      {:ok, [next_cursor, []]} ->
        do_delete_buckets(conn, redis_key_pattern, next_cursor, count_deleted)

      {:ok, ["0", keys]} ->
        {:ok, deleted} = Redix.command(conn, ["DEL" | keys])
        {:ok, deleted + count_deleted}

      {:ok, [next_cursor, keys]} ->
        {:ok, deleted} = Redix.command(conn, ["DEL" | keys])
        do_delete_buckets(conn, redis_key_pattern, next_cursor, count_deleted + deleted)

      {:error, _reason} = e ->
        e
    end
  end
end
