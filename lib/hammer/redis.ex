defmodule Hammer.Redis do
  @moduledoc """
  This backend uses the [Redix](https://hex.pm/packages/redix) library to connect to Redis.

      defmodule MyApp.RateLimit do
        # the default prefix is "MyApp.RateLimit:"
        # the default timeout is :infinity
        use Hammer, backend: Hammer.Redis, prefix: "MyApp.RateLimit:", timeout: :infinity
      end

      MyApp.RateLimit.start_link(url: "redis://localhost:6379")

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

    # TODO
    name = module

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
      @name unquote(name)
      @prefix unquote(prefix)
      @timeout unquote(timeout)

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }
      end

      def start_link(opts) do
        opts = Keyword.put(opts, :name, @name)
        Hammer.Redis.start_link(opts)
      end

      def hit(key, scale, limit, increment \\ 1, timeout \\ @timeout) do
        Hammer.Redis.hit(@name, @prefix, key, scale, limit, increment, timeout)
      end

      def inc(key, scale, increment \\ 1, timeout \\ @timeout) do
        Hammer.Redis.inc(@name, @prefix, key, scale, increment, timeout)
      end

      def set(key, scale, count, timeout \\ @timeout) do
        Hammer.Redis.set(@name, @prefix, key, scale, count, timeout)
      end

      def get(key, scale, timeout \\ @timeout) do
        Hammer.Redis.get(@name, @prefix, key, scale, timeout)
      end
    end
  end

  @doc false
  def start_link(opts) do
    {url, opts} = Keyword.pop(opts, :url)

    opts =
      if url do
        url_opts = Redix.URI.to_start_options(url)
        Keyword.merge(url_opts, opts)
      else
        opts
      end

    Redix.start_link(opts)
  end

  @doc false
  def hit(name, prefix, key, scale, limit, increment, timeout) do
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
      Redix.pipeline!(name, commands, timeout: timeout)

    if count <= limit do
      {:allow, count}
    else
      {:deny, expires_at - now}
    end
  end

  @doc false
  def inc(name, prefix, key, scale, increment, timeout) do
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
      Redix.pipeline!(name, commands, timeout: timeout)

    count
  end

  @doc false
  def set(name, prefix, key, scale, count, timeout) do
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
      Redix.pipeline!(name, commands, timeout: timeout)

    count
  end

  @doc false
  def get(name, prefix, key, scale, timeout) do
    now = now()
    window = div(now, scale)
    full_key = redis_key(prefix, key, window)
    count = Redix.command!(name, ["GET", full_key], timeout: timeout)

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
