defmodule Hammer.Redis do
  @moduledoc """
  This backend uses the [Redix](https://hex.pm/packages/redix) library to connect to Redis.
  And [poolboy](https://hex.pm/packages/poolboy) to manage the connections.

      defmodule MyApp.RateLimit do
        # the default prefix is "MyApp.RateLimit:"
        # the default timeout is :infinity
        use Hammer, backend: Hammer.Redis, prefix: "MyApp.RateLimit:", timeout: :infinity
      end

      redix_opts = [url: "redis://localhost:6379"]
      poolboy_opts = [size: 10, max_overflow: 2]
      MyApp.RateLimit.start_link(redix_opts ++ poolboy_opts)

      # increment and timeout arguments are optional
      # by default increment is 1 and timeout is as defined in the module
      {:allow, _count} = MyApp.RateLimit.hit(key, scale, limit)
      {:allow, _count} = MyApp.RateLimit.hit(key, scale, limit, _increment = 1, _timeout = :infinity)

  """

  defmacro __before_compile__(%{module: module}) do
    hammer_opts = Module.get_attribute(module, :hammer_opts)

    prefix = String.trim_leading(Atom.to_string(module), "Elixir.")
    prefix = Keyword.get(hammer_opts, :prefix, prefix)
    timeout = Keyword.get(hammer_opts, :timeout, :infinity)

    unless is_binary(prefix) do
      raise ArgumentError, """
      Expected `:prefix` value to be a string, got: #{inspect(prefix)}
      """
    end

    case timeout do
      :infinity ->
        :ok

      _ when is_integer(timeout) and timeout > 0 ->
        :ok

      _ ->
        raise ArgumentError, """
        Expected `:timeout` value to be a positive integer or `:infinity`, got: #{inspect(timeout)}
        """
    end

    quote do
      @pool unquote(module)
      @prefix unquote(prefix)
      @timeout unquote(timeout)

      def child_spec(opts) do
        %{
          id: @pool,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }
      end

      def start_link(opts) do
        opts = Keyword.put(opts, :name, @pool)
        Hammer.Redis.start_link(opts)
      end

      def hit(key, scale, limit, increment \\ 1, timeout \\ @timeout) do
        Hammer.Redis.hit(@pool, @prefix, key, scale, limit, increment, timeout)
      end

      def inc(key, scale, increment \\ 1, timeout \\ @timeout) do
        Hammer.Redis.inc(@pool, @prefix, key, scale, increment, timeout)
      end

      def set(key, scale, count, timeout \\ @timeout) do
        Hammer.Redis.set(@pool, @prefix, key, scale, count, timeout)
      end

      def get(key, scale, timeout \\ @timeout) do
        Hammer.Redis.get(@pool, @prefix, key, scale, timeout)
      end
    end
  end

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    {pool_opts, redix_opts} = Keyword.split(opts, [:size, :max_overflow])

    pool_args = [
      name: {:local, name},
      worker_module: Redix,
      size: Keyword.get(pool_opts, :size, 5),
      max_overflow: Keyword.get(opts, :max_overflow, 2)
    ]

    {url, redix_opts} = Keyword.pop(redix_opts, :url)

    redix_opts =
      if url do
        url_opts = Redix.URI.to_start_options(url)
        Keyword.merge(url_opts, redix_opts)
      else
        redix_opts
      end

    :poolboy.start_link(pool_args, redix_opts)
  end

  @doc false
  def hit(pool, prefix, key, scale, limit, increment, timeout) do
    now = now()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    expires_at = (window + 1) * scale

    commands = [
      ["MULTI"],
      ["INCRBY", full_key, increment],
      # TODO document time issues
      ["EXPIREAT", full_key, div(expires_at, 1000), "NX"],
      ["EXEC"]
    ]

    ["OK", "QUEUED", "QUEUED", [count, _]] =
      :poolboy.transaction(pool, fn conn -> Redix.pipeline!(conn, commands) end, timeout)

    if count <= limit do
      {:allow, count}
    else
      {:deny, expires_at - now}
    end
  end

  @doc false
  def inc(pool, prefix, key, scale, increment, timeout) do
    now = now()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    expires_at = (window + 1) * scale

    commands = [
      ["MULTI"],
      ["INCRBY", full_key, increment],
      ["EXPIREAT", full_key, div(expires_at, 1000), "NX"],
      ["EXEC"]
    ]

    ["OK", "QUEUED", "QUEUED", [count, _]] =
      :poolboy.transaction(pool, fn conn -> Redix.pipeline!(conn, commands) end, timeout)

    count
  end

  @doc false
  def set(pool, prefix, key, scale, count, timeout) do
    now = now()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    expires_at = (window + 1) * scale

    commands = [
      ["MULTI"],
      ["SET", full_key, count],
      ["EXPIREAT", full_key, div(expires_at, 1000), "NX"],
      ["EXEC"]
    ]

    ["OK", "QUEUED", "QUEUED", [_, _]] =
      :poolboy.transaction(
        pool,
        fn conn -> Redix.pipeline!(conn, commands) end,
        timeout
      )

    count
  end

  @doc false
  def get(pool, prefix, key, scale, timeout) do
    now = now()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)

    count =
      :poolboy.transaction(
        pool,
        fn conn -> Redix.command!(conn, ["GET", full_key]) end,
        timeout
      )

    case count do
      nil -> 0
      count -> String.to_integer(count)
    end
  end

  @compile inline: [redis_key: 3]
  defp redis_key(prefix, key, window) do
    "#{prefix}:#{key}:#{window}"
  end

  @compile inline: [now: 0]
  defp now do
    System.system_time(:millisecond)
  end
end
