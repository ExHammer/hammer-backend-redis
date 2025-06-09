❯ MIX_ENV=bench LIMIT=1 SCALE=5000 RANGE=10000 PARALLEL=500 mix run bench/base.exs
parallel: 500
limit: 1
scale: 5000
range: 10000

Operating System: macOS
CPU Information: Apple M1 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.18.2
Erlang 27.1.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 14 s
time: 6 s
memory time: 0 ns
reduction time: 0 ns
parallel: 500
inputs: none specified
Estimated total run time: 1 min 20 s

Benchmarking hammer_redis_fix_window ...
Benchmarking hammer_redis_leaky_bucket ...
Benchmarking hammer_redis_sliding_window ...
Benchmarking hammer_redis_token_bucket ...
Calculating statistics...
Formatting results...

Name                                  ips        average  deviation         median         99th %
hammer_redis_sliding_window        266.27        3.76 ms     ±8.11%        3.75 ms        4.74 ms
hammer_redis_leaky_bucket          259.11        3.86 ms     ±7.28%        3.84 ms        4.70 ms
hammer_redis_token_bucket          254.97        3.92 ms    ±13.76%        3.78 ms        6.06 ms
hammer_redis_fix_window            157.78        6.34 ms    ±10.49%        6.32 ms        7.88 ms

Comparison:
hammer_redis_sliding_window        266.27
hammer_redis_leaky_bucket          259.11 - 1.03x slower +0.104 ms
hammer_redis_token_bucket          254.97 - 1.04x slower +0.167 ms
hammer_redis_fix_window            157.78 - 1.69x slower +2.58 ms

Extended statistics:

Name                                minimum        maximum    sample size                     mode
hammer_redis_sliding_window         1.26 ms        6.11 ms       798.95 K                  3.75 ms
hammer_redis_leaky_bucket           1.99 ms        5.98 ms       777.49 K                  3.76 ms
hammer_redis_token_bucket           1.97 ms        7.37 ms       765.05 K                  3.69 ms
hammer_redis_fix_window             1.10 ms       14.11 ms       473.50 K                  6.39 ms
