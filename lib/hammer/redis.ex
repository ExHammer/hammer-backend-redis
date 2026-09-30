defmodule Hammer.Redis do
  @moduledoc """
  This backend uses the [Redix](https://hex.pm/packages/redix) library to connect to Redis.

  > #### Redis version requirement {: .warning}
  >
  > Redis 7.0 or later is required. The `:fix_window` algorithm relies on `PEXPIREAT ... NX`,
  > introduced in Redis 7.0. On older Redis versions the command fails, so counter keys never
  > expire and the keyspace grows until Redis runs out of memory.

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

  ## Checking several limits at once

  The `:fix_window`, `:leaky_bucket` and `:token_bucket` algorithms also provide
  `hit_many/1`, which checks several limits in one atomic round trip and counts
  the hit against all of them only if every one allows it:

      # with algorithm: :fix_window, 1 SMS per minute and 6 per hour
      {:allow, [_minute_count, _hour_count]} =
        MyApp.RateLimit.hit_many([
          {"{user_123}:sms:minute", :timer.minutes(1), 1},
          {"{user_123}:sms:hour", :timer.hours(1), 6}
        ])

  On deny it returns `{:deny, retry_after_ms}` and counts nothing. Each
  algorithm's docs describe its bucket tuple:
  [FixWindow](Hammer.Redis.FixWindow.html#module-hitting-several-windows-at-once),
  [TokenBucket](Hammer.Redis.TokenBucket.html#module-hitting-several-buckets-at-once),
  [LeakyBucket](Hammer.Redis.LeakyBucket.html#module-hitting-several-buckets-at-once).
  On Redis Cluster, all keys in one call must share a hash tag such as `{user_123}`.

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

      if function_exported?(@algorithm, :hit_many, 4) do
        def hit_many(buckets) do
          @algorithm.hit_many(@name, @prefix, buckets, @timeout)
        end
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
  # Validates the buckets given to `hit_many/1` and returns them as
  # `{redis_key, arg1, arg2, cost}`, with `cost` defaulting to 1. `names` are
  # the four tuple elements for error messages, e.g.
  # ~w(key refill_rate capacity cost).
  #
  # The numbers are checked here because the scripts only find out a value is
  # unusable (e.g. INCRBY with 1.5) in their write pass, after other buckets
  # were already written, which would break the all-or-nothing guarantee.
  @spec normalize_buckets!(list(), [String.t()], (tuple() -> String.t())) :: [tuple(), ...]
  def normalize_buckets!(buckets, names, redis_key) do
    buckets = Enum.map(buckets, &normalize_bucket!(&1, names))

    if buckets == [] do
      raise ArgumentError, "hit_many/1 expects at least one bucket"
    end

    buckets =
      Enum.map(buckets, fn {_, arg1, arg2, cost} = b -> {redis_key.(b), arg1, arg2, cost} end)

    # The scripts read every bucket before writing any, so a key listed twice
    # would be charged twice against the same stale state. Compare the Redis
    # keys, since e.g. 1 and "1" interpolate to the same one.
    keys = Enum.map(buckets, &elem(&1, 0))

    if Enum.uniq(keys) != keys do
      raise ArgumentError, "hit_many/1 got the same key more than once: #{inspect(keys)}"
    end

    buckets
  end

  defp normalize_bucket!({key, arg1, arg2}, names),
    do: normalize_bucket!({key, arg1, arg2, 1}, names)

  defp normalize_bucket!({_key, arg1, arg2, cost} = bucket, _names)
       when is_integer(arg1) and arg1 > 0 and is_integer(arg2) and arg2 >= 0 and
              is_integer(cost) and cost >= 0,
       do: bucket

  defp normalize_bucket!(other, names) do
    [_key, arg1, arg2, cost] = names

    raise ArgumentError,
          "expected {#{Enum.join(Enum.take(names, 3), ", ")}} or " <>
            "{#{Enum.join(names, ", ")}} with a positive integer #{arg1} and " <>
            "non-negative integer #{arg2} and #{cost}, got: #{inspect(other)}"
  end

  @doc false
  # Runs a `hit_many`-style script over the normalized buckets. The script
  # replies {1, value_1, ..., value_n} on allow or {0, wait_ms} on deny.
  @spec eval_many!(Redix.connection(), String.t(), [tuple(), ...], (tuple() -> list()), timeout()) ::
          {:allow, [non_neg_integer()]} | {:deny, non_neg_integer()}
  def eval_many!(name, script, buckets, bucket_args, timeout) do
    keys = Enum.map(buckets, &elem(&1, 0))
    args = Enum.flat_map(buckets, bucket_args)
    command = ["EVAL", script, length(keys)] ++ keys ++ args

    case Redix.command(name, command, timeout: timeout) do
      {:ok, [1 | values]} -> {:allow, values}
      {:ok, [0, wait]} -> {:deny, wait}
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec pipeline!(Redix.connection(), [Redix.command()], timeout()) :: [term()]
  def pipeline!(name, commands, timeout) do
    replies = Redix.pipeline!(name, commands, timeout: timeout)

    # Redix.pipeline! only raises on connection errors; Redis error replies to
    # individual commands come back as Redix.Error structs in the reply list
    Enum.each(replies, fn
      %Redix.Error{} = error -> raise error
      _reply -> :ok
    end)

    replies
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
