❯ MIX_ENV=bench LIMIT=1 SCALE=5000 RANGE=10000 PARALLEL=500 mix run bench/base.exs
parallel: 500
limit: 1
scale: 5000
range: 10000

Operating System: macOS
CPU Information: Apple M1 Max
Number of Available Cores: 10
Available memory: 32 GB
Elixir 1.17.3
Erlang 27.1.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 14 s
time: 6 s
memory time: 0 ns
reduction time: 0 ns
parallel: 500
inputs: none specified
Estimated total run time: 1 min

Benchmarking hammer_redis_fix_window ...
Benchmarking hammer_redis_leaky_bucket ...
Benchmarking hammer_redis_token_bucket ...
Calculating statistics...
Formatting results...

Name                                ips        average  deviation         median         99th %
hammer_redis_fix_window          232.75        4.30 ms    ±21.83%        4.31 ms        6.51 ms
hammer_redis_token_bucket         67.46       14.82 ms    ±13.57%       14.25 ms       19.66 ms
hammer_redis_leaky_bucket         61.71       16.20 ms    ±54.15%       15.67 ms       31.44 ms

Comparison:
hammer_redis_fix_window          232.75
hammer_redis_token_bucket         67.46 - 3.45x slower +10.53 ms
hammer_redis_leaky_bucket         61.71 - 3.77x slower +11.91 ms

Extended statistics:

Name                              minimum        maximum    sample size                     mode
hammer_redis_fix_window           1.09 ms        8.88 ms       698.34 K                  4.33 ms
hammer_redis_token_bucket         1.37 ms       37.16 ms       202.54 K       13.60 ms, 13.19 ms
hammer_redis_leaky_bucket         3.52 ms      197.32 ms       185.33 K15.38 ms, 15.62 ms, 15.30