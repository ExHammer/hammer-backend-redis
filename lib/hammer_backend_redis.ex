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

  @behaviour Hammer.Backend

  use GenServer

  @type bucket_key :: {bucket :: integer, id :: String.t()}
  @type bucket_info ::
          {key :: bucket_key, count :: integer, created :: integer, updated :: integer}
  ## Public API

  @spec start :: :ignore | {:error, any} | {:ok, pid}
  def start do
    start([])
  end

  @spec start(keyword()) :: :ignore | {:error, any} | {:ok, pid}
  def start(args) do
    GenServer.start(__MODULE__, args)
  end

  @spec start_link :: :ignore | {:error, any} | {:ok, pid}
  def start_link do
    start_link([])
  end

  @spec start_link(keyword()) :: :ignore | {:error, any} | {:ok, pid}
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec stop :: any
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @doc """
  Record a hit in the bucket identified by `key`
  """
  @impl Hammer.Backend
  def count_hit(pid, key, now) do
    GenServer.call(pid, {:count_hit, key, now, 1})
  end

  @doc """
  Record a hit in the bucket identified by `key`, with a custom increment
  """
  @impl Hammer.Backend
  def count_hit(pid, key, now, increment) do
    GenServer.call(pid, {:count_hit, key, now, increment})
  end

  @doc """
  Retrieve information about the bucket identified by `key`
  """
  @impl Hammer.Backend
  def get_bucket(pid, key) do
    GenServer.call(pid, {:get_bucket, key})
  end

  @doc """
  Delete all buckets associated with `id`.
  """
  @impl Hammer.Backend
  def delete_buckets(pid, id) do
    delete_buckets_timeout = GenServer.call(pid, {:get_delete_buckets_timeout})
    GenServer.call(pid, {:delete_buckets, id}, delete_buckets_timeout)
  end

  ## GenServer Callbacks

  @impl GenServer
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

    redis_url = Keyword.get(args, :redis_url, nil)

    {:ok, redix} =
      if is_binary(redis_url) && byte_size(redis_url) > 0 do
        Redix.start_link(redis_url, redix_config)
      else
        Redix.start_link(redix_config)
      end

    delete_buckets_timeout = Keyword.get(args, :delete_buckets_timeout, 5000)

    cluster_nodes = MapSet.new([redix])

    {:ok,
     %{
       redix: redix,
       expiry_ms: expiry_ms,
       delete_buckets_timeout: delete_buckets_timeout,
       cluster_nodes: cluster_nodes
     }}
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:count_hit, key, now, increment}, _from, %{redix: r} = state) do
    expiry = get_expiry(state)
    {result, node_conn} = do_count_hit(r, key, now, increment, expiry)
    state_with_cluster_nodes = append_cluster_node(state, node_conn)
    {:reply, result, state_with_cluster_nodes}
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

  def handle_call({:delete_buckets, id}, _from, %{redix: r} = state) do
    redis_key_pattern = make_redis_key_pattern(id)

    cluster_nodes_conn = MapSet.to_list(state.cluster_nodes)
    result = do_delete_buckets(r, redis_key_pattern, 0, 0, cluster_nodes_conn)

    {:reply, result, state}
  end

  def handle_call(
        {:get_delete_buckets_timeout},
        _from,
        %{delete_buckets_timeout: delete_buckets_timeout} = state
      ) do
    {:reply, delete_buckets_timeout, state}
  end

  defp append_cluster_node(state, node_conn) do
    if not is_nil(node_conn) do
      cluster_nodes = MapSet.put(state.cluster_nodes, node_conn)
      %{state | cluster_nodes: cluster_nodes}
    else
      state
    end
  end

  defp do_delete_buckets(r, redis_key_pattern, cursor, count_deleted, [_single_node_conn]) do
    delete_buckets_in_single_node(r, redis_key_pattern, cursor, count_deleted)
  end

  defp do_delete_buckets(_r, _redis_key_pattern, _cursor, _count_deleted, cluster_nodes) do
    keys_in_cluster =
      for conn <- cluster_nodes, reduce: [] do
        acc ->
          {:ok, keys} = Redix.command(conn, ["KEYS", "*"])
          Enum.concat(acc, keys)
      end

    delete_buckets_in_cluster(keys_in_cluster, cluster_nodes)
  end

  def delete_buckets_in_single_node(r, redis_key_pattern, cursor, count_deleted) do
    case Redix.command(r, ["SCAN", cursor, "MATCH", redis_key_pattern]) do
      {:ok, ["0", []]} ->
        {:ok, count_deleted}

      {:ok, [next_cursor, []]} ->
        delete_buckets_in_single_node(r, redis_key_pattern, next_cursor, count_deleted)

      {:ok, ["0", keys]} ->
        {:ok, deleted} = Redix.command(r, ["DEL" | keys])
        {:ok, deleted + count_deleted}

      {:ok, [next_cursor, keys]} ->
        {:ok, deleted} = Redix.command(r, ["DEL" | keys])
        delete_buckets_in_single_node(r, redis_key_pattern, next_cursor, count_deleted + deleted)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_buckets_in_cluster(keys, cluster_nodes) do
    [main_node | _] = cluster_nodes

    deleted =
      for key <- keys do
        case Redix.command(main_node, ["DEL", key]) do
          {:ok, _count} = res ->
            res

          {:error, %Redix.Error{message: error_message}} ->
            ["MOVED", _, node_address] = String.split(error_message, " ")
            node_conn = Process.whereis(:"cluster-node-#{node_address}")
            {:ok, _} = Redix.command(node_conn, ["DEL", key])
        end
      end

    {:ok, length(deleted)}
  end

  # we are using the first method described (called bucketing)
  # in https://www.youtube.com/watch?v=CRGPbCbRTHA
  # but we add the 'created' and 'updated' meta information fields.
  defp do_count_hit(r, key, now, increment, expiry) do
    redis_key = make_redis_key(key)

    cmds = [
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
    ]

    execute_pipeline(r, cmds, nil)
  end

  defp execute_pipeline(conn, cmds, node_conn) do
    case Redix.pipeline(conn, cmds) do
      {:ok, ["OK", "QUEUED", "QUEUED", "QUEUED", "QUEUED", [new_count, _, _, 1]]} ->
        {{:ok, new_count}, node_conn}

      {:ok, ["OK" | [error_message | _]]} ->
        execute_pipeline_in_cluster(cmds, error_message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_pipeline_in_cluster(pipeline_cmds, %{message: error_message}) do
    ["MOVED", _, node_address] = String.split(error_message, " ")

    conn =
      case Redix.start_link("redis://#{node_address}", name: :"cluster-node-#{node_address}") do
        {:ok, node_conn} ->
          node_conn

        {:error, {:already_started, node_conn}} ->
          node_conn
      end

    execute_pipeline(conn, pipeline_cmds, conn)
  end

  defp make_redis_key({bucket, id}) do
    "Hammer:Redis:#{id}:#{bucket}"
  end

  defp make_redis_key_pattern(id) do
    "Hammer:Redis:#{id}:*"
  end

  defp get_expiry(state) do
    %{expiry_ms: expiry_ms} = state
    round(expiry_ms / 1000 + 1)
  end
end
