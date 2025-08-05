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

  The Redis backend supports the following algorithms:
    - `:fix_window` - Fixed window rate limiting (default)
      Simple counting within fixed time windows. See [Hammer.Redis.FixWindow](Hammer.Redis.FixWindow.html) for more details.

    - `:sliding_window` - Sliding window rate limiting
      Simple counting within sliding time windows. See [Hammer.Redis.SlidingWindow](Hammer.Redis.SlidingWindow.html) for more details.

    - `:leaky_bucket` - Leaky bucket rate limiting
      Smooth rate limiting with a fixed rate of tokens. See [Hammer.Redis.LeakyBucket](Hammer.Redis.LeakyBucket.html) for more details.

    - `:token_bucket` - Token bucket rate limiting
      Flexible rate limiting with bursting capability. See [Hammer.Redis.TokenBucket](Hammer.Redis.TokenBucket.html) for more details.

  """
  # Redix does not define a type for its start options, so we define our
  # own so hopefully redix will be updated to provide a type
  @type redis_option :: {:url, String.t()} | {:name, String.t()}
  @type redis_options :: [redis_option()]

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(%{module: module}) do
    hammer_opts = Module.get_attribute(module, :hammer_opts)

    prefix = String.trim_leading(Atom.to_string(module), "Elixir.")
    prefix = Keyword.get(hammer_opts, :prefix, prefix)
    timeout = Keyword.get(hammer_opts, :timeout, :infinity)

    name = module

    algorithm =
      case Keyword.get(hammer_opts, :algorithm) do
        nil ->
          Hammer.Redis.FixWindow

        :fix_window ->
          Hammer.Redis.FixWindow

        :sliding_window ->
          Hammer.Redis.SlidingWindow

        :leaky_bucket ->
          Hammer.Redis.LeakyBucket

        :token_bucket ->
          Hammer.Redis.TokenBucket

        _module ->
          raise ArgumentError, """
          Hammer requires a valid backend to be specified. Must be one of: :fix_window, :sliding_window, :leaky_bucket, :token_bucket.
          If none is specified, :fix_window is used.

          Example:

            use Hammer, backend: Hammer.Redis, algorithm: Hammer.Redis.FixWindow
          """
      end

    Code.ensure_loaded!(algorithm)

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
      @algorithm unquote(algorithm)

      @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }
      end

      @spec start_link(Hammer.Redis.redis_options()) ::
              {:ok, pid()} | :ignore | {:error, term()}
      def start_link(opts) do
        opts = Keyword.put(opts, :name, @name)

        Hammer.Redis.start_link(opts)
      end

      def hit(key, scale, limit, increment \\ 1) do
        @algorithm.hit(@name, @prefix, key, scale, limit, increment, @timeout)
      end

      if function_exported?(@algorithm, :inc, 6) do
        def inc(key, scale, increment \\ 1) do
          @algorithm.inc(@name, @prefix, key, scale, increment, @timeout)
        end
      end

      if function_exported?(@algorithm, :set, 6) do
        def set(key, scale, count) do
          @algorithm.set(@name, @prefix, key, scale, count, @timeout)
        end
      end

      if function_exported?(@algorithm, :get, 4) do
        def get(key, scale) do
          @algorithm.get(@name, @prefix, key, @timeout)
        end
      end

      if function_exported?(@algorithm, :get, 5) do
        def get(key, scale) do
          @algorithm.get(@name, @prefix, key, scale, @timeout)
        end
      end
    end
  end

  @doc false
  @spec start_link(Hammer.Redis.redis_options()) ::
          {:ok, pid()} | :ignore | {:error, term()}
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
end
