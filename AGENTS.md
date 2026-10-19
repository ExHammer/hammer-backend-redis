# AGENTS.md

`hammer_backend_redis` is a Redis backend for the [Hammer](https://hex.pm/packages/hammer) rate-limiting library. It is a Hex library (no application of its own, no supervision tree, no database schema) used by other Elixir apps via `use Hammer, backend: Hammer.Redis`. Each rate limiter is a single named `Redix` connection; all limiting logic runs atomically inside Redis (Lua `EVAL` scripts or pipelined commands). Maintainers: Emmanuel Pinault, June Kelly. Released to Hex by pushing a git tag.

The `origin` remote is `git@github.com:ExHammer/hammer-backend-redis.git`, i.e. this checkout is **upstream (ExHammer)** with default branch `master`.

## Project Overview

| Item | Value |
|---|---|
| Package / app | `:hammer_backend_redis` (version `@version` in `mix.exs`, currently 7.3.0) |
| Root module | `Hammer.Redis` (mix project: `Hammer.Redis.MixProject`) |
| Elixir (mix.exs) | `~> 1.14`; dev toolchain in `.tool-versions` / `mise.toml`: Elixir 1.20.4-otp-29, Erlang 29.0.5 |
| CI matrix | Elixir 1.17-1.20 on OTP 26-29 |
| Runtime deps | `hammer ~> 7.0` (lock: 7.5.0), `redix ~> 1.5` (lock: 1.9.2) |
| Dev/test deps | `credo`, `dialyxir` (dev only), `ex_doc` (dev only), `benchee` (`:bench` env only) |
| Redis | **7.0+ required** (`PEXPIREAT ... NX` in fixed window); tests use `redis:latest` |
| CI | GitHub Actions (`.github/workflows/ci.yml`, `publish.yml`), Dependabot |
| Phoenix / Ecto | None. No DB, no config/ directory, no assets |

## Essential Commands

### Setup
```bash
mise install                 # optional, installs Erlang/Elixir from mise.toml
mix deps.get
docker compose up -d redis   # compose.yml: redis:latest on localhost:6379
```

### Test
Tests need a live Redis at the hard-coded URL `redis://localhost:6379` (no env var, no config). Without Redis, `test/test_helper.exs` prints a hint and excludes the `:redis` tag, so tests silently skip rather than fail.
```bash
mix test                                      # all non-excluded tests
mix test test/hammer/redis/token_bucket_test.exs          # single file
mix test test/hammer/redis/token_bucket_test.exs:35       # single test by line
mix test --include slow                       # also run @tag :slow tests
mix test --warnings-as-errors --cover --include redis --include slow   # exactly what CI runs
```
Coverage threshold is 85% (`test_coverage: [summary: [threshold: 85]]`).

### Quality (the gate, mirror of CI)
```bash
mix compile --warnings-as-errors
mix credo --strict --format=oneline
mix format --check-formatted
mix deps.unlock --check-unused
mix dialyzer                  # dev only; not in CI
```
There is no `precommit` alias. Run the four commands above plus the CI test command before committing.

### Docs / Bench / Release
```bash
mix docs                                       # ex_doc; main page is README, extras README + CHANGELOG
MIX_ENV=bench LIMIT=1 SCALE=5000 RANGE=10000 PARALLEL=500 mix run bench/base.exs   # needs Redis; see BENCHMARKS.md
```
Release: see "Workflow" below.

## Architecture

```
lib/hammer/
  redis.ex                 # Hammer.Redis: __before_compile__ macro (the backend entry point), start_link/1,
                           #   shared helpers normalize_buckets!/3, eval_many!/5, pipeline!/3
  redis/
    fix_window.ex          # Hammer.Redis.FixWindow   (default algorithm)
    sliding_window.ex      # Hammer.Redis.SlidingWindow  (sorted set, Lua)
    token_bucket.ex        # Hammer.Redis.TokenBucket    (hash, Lua)
    leaky_bucket.ex        # Hammer.Redis.LeakyBucket    (hash, Lua)
test/
  test_helper.exs          # pings Redis, FLUSHALL, excludes :redis tag if unreachable
  hammer/redis_test.exs    # fix window via the public macro, hit_many, sub-second windows, error replies
  hammer/redis/{token_bucket,leaky_bucket,sliding_window}_test.exs
bench/base.exs             # Benchee script (MIX_ENV=bench)
```

### The Hammer backend contract (read-only reference: `/Users/manu/Projects/hammer/lib/hammer.ex`)
- `use Hammer, backend: Hammer.Redis, ...` defines `@behaviour Hammer`, stores `@hammer_opts`, and sets `@before_compile Hammer.Redis`. Therefore **`Hammer.Redis.__before_compile__/1` generates the user's public API**; there is no `Hammer.Redis` behaviour implementation as such.
- `Hammer` callbacks: `hit/3`, `hit/4` `-> {:allow, count} | {:deny, timeout}`, `inc/2,3`, `set/3`, `get/2`, `expires_at/2`; all except `hit/3` are `@optional_callbacks`. This backend does not define `expires_at/2`.
- `__before_compile__` resolves options (`:algorithm` atom -> module, default `:fix_window`; `:prefix`, default = module name; `:timeout`, default `:infinity`), validates them with `ArgumentError`, and conditionally defines functions using `function_exported?/3` on the algorithm module, keyed by **arity**:
  - `hit_many/4` -> `hit_many/1`; `inc/6` -> `inc/3`; `set/6` -> `set/3`; `get/4` -> `get/2` (key only); `get/5` -> `get/2` (key + scale). Adding a function to an algorithm module with a new arity needs a matching clause here.
- Algorithm modules are plain modules with `hit(name, prefix, key, scale_or_rate, limit_or_capacity, increment_or_cost, timeout)`. The first argument is the registered Redix connection name (= the user's module). `scale` is ms.
- Which optional functions each algorithm exports: FixWindow has `hit/inc/set/get/hit_many`; SlidingWindow has `hit/inc/set/get`; TokenBucket and LeakyBucket have `hit/get/hit_many` only (their `scale` arg means `refill_rate`/`leak_rate`, and `limit` means `capacity`).
- Process model: `start_link/1` (generated) forces `name: <module>`, then `Hammer.Redis.start_link/1` turns `url:` into Redix options via `Redix.URI.to_start_options/1` (explicit opts win) and calls `Redix.start_link/1`. One connection per limiter; no pooling by design (README explains why).

### Redis access patterns
- Fix window: pipelined `INCRBY` + `PEXPIREAT ... NX` (key includes the window start); `hit_many` is a Lua script.
- Sliding window, token bucket, leaky bucket: Lua scripts run with `EVAL` through `Redix.command/3`, using `redis.call("TIME")` as the clock so app-node clock skew does not matter.
- `hit_many/1` is all-or-nothing: scripts read every bucket first, write only if all allow, reply `{1, v1..vn}` or `{0, wait_ms}`. `Hammer.Redis.eval_many!/5` decodes that. On Redis Cluster all keys in one call must share a hash tag (`{user_123}`).
- Redis error replies are raised as `Redix.Error` (`pipeline!/3` explicitly checks reply lists, since `Redix.pipeline!` only raises on connection errors).

## Conventions

- Formatter: default `mix format` config (`.formatter.exs` only lists inputs); default 98-column line length. Credo runs `--strict` with the near-default `.credo.exs`; use `# credo:disable-for-next-line ...` sparingly (one exists in `redis.ex`).
- Every public module has a `@moduledoc` with a runnable example; public algorithm functions have `@doc` and `@spec`. Internal helpers in `Hammer.Redis` are `@doc false`.
- Lua scripts live as heredoc strings inside the algorithm module (e.g. `redis_script/0` in `token_bucket.ex`). Keys are built by a private `redis_key/2` from `prefix` and the user key; never build keys elsewhere.
- Time is integer milliseconds everywhere. Token/leaky bucket state lives in a hash with `level` and `last_update_ms` (legacy `last_update` seconds is migrated on next hit and `HDEL`ed). Preserve backwards compatibility of stored Redis data across releases; the CHANGELOG records each such case.
- Validate user input in Elixir before the script runs (see `normalize_buckets!/3`): a script that fails mid-write breaks atomicity.
- Errors: raise (`ArgumentError` for bad options/arguments, `Redix.Error` for Redis replies). Return values are only `{:allow, n}` / `{:deny, ms}` tuples or counts.
- Commit style: conventional-ish (`feat(token_bucket): ...`, `fix(sliding_window): ...`, `chore: release 7.3.0 (#167)`, `build(deps): ...`), with the PR number appended by GitHub squash merge.

## Testing

- ExUnit, no Mox, no factories. Every test module sets `use ExUnit.Case, async: true` and `@moduletag :redis`.
- Each test module defines inline limiter modules with `use Hammer, backend: Hammer.Redis, algorithm: ...`, starts them in `setup` via `start_supervised!({Limiter, url: "redis://localhost:6379"})`, and uses a random key (`"key#{:rand.uniform(1_000_000)}"`) so async tests do not collide. Keep that pattern; do not use fixed keys.
- Tests can inspect raw state with `Redix.command!(Limiter, ["HGET", "<Module>:<key>", "level"])` (the connection is registered under the limiter module name).
- Slow tests (real window expiry waits) are `@tag :slow`; CI includes them. Use short scales but they are inherently timing-based, so assert ranges for `retry_after` (see comments in `token_bucket_test.exs`) rather than exact values. Do not add `Process.sleep` where a small `scale` and one wait suffice.
- `test_helper.exs` runs `FLUSHALL` on the local Redis. Never point the tests at a Redis that holds data you care about.

Example (from `token_bucket_test.exs`):
```elixir
test "returns {:allow, 9} tuple on first access", %{key: key} do
  assert {:allow, 9} = RateLimitTokenBucket.hit(key, 10, 10, 1)
end
```

## Elixir Guidelines

- Pattern matching and `with` over nested `case`; tagged tuples; `@impl true` where a behaviour callback is implemented.
- Never `String.to_atom/1` on user input. Keys are user input: they are interpolated into the Redis key string only, and passed to scripts as `KEYS`/`ARGV`, never concatenated into Lua source.
- Pass everything dynamic to Lua through `KEYS` and `ARGV`; Lua scripts must use only keys declared in `KEYS` (Redis Cluster and Redis 7 function/script rules).
- Redis hands back integers as integers, but hash fields as strings (`"4"`); convert explicitly in Lua (`tonumber`) and in tests.
- Redix ships `Redix.URI` and `Redix.command/3`; use the `timeout:` option from the limiter's `:timeout`, don't add your own timeouts.
- `Req`/HTTP not relevant here. No GenServers are defined; do not add processes; the user's supervision tree owns the Redix connection.
- Keep library code dependency-light. Adding a runtime dependency is a breaking decision for every consumer.

## Workflow for Agents

1. Read the algorithm module and its test file; read `lib/hammer/redis.ex` if the public API or options change; check `/Users/manu/Projects/hammer/lib/hammer.ex` (read-only) for the behaviour.
2. Start Redis (`docker compose up -d redis`) and confirm tests are not being skipped (`mix test` should report a non-trivial test count, not "excluded").
3. Write or adjust tests first, implement, then run the CI commands listed under Quality and Test.
4. For any user-visible change add an entry to `CHANGELOG.md` under a new or unreleased heading in the existing format (`## X.Y.Z - YYYY-MM-DD`, subsections Added/Fixed/Changed, PR number in parentheses). Update `README.md` and module docs if behaviour or Redis requirements change.
5. Commit with a conventional message; open PRs against `master` (`gh pr create --base master`).

### Releasing (maintainers)
Per `RELEASE.md` and recent `chore: release X.Y.Z` commits: bump `@version` in `mix.exs`, finalize the CHANGELOG heading with the date, check README version snippets, run tests + credo, merge to `master`, then push a git tag. The tag triggers `.github/workflows/publish.yml`, which publishes to Hex with the `HEX_API_KEY` secret (docs are built from `source_ref: "v#{@version}"`). Never publish or tag without the maintainer asking.

## Constraints - Never Do

- Never run read-modify-write logic across several Redis round trips (`GET` then `SET` from Elixir). Use a Lua script or a single atomic command.
- Never use the Elixir clock for bucket/window math inside scripts; use Redis `TIME`. (Fixed window computes the window in Elixir from `System.system_time(:millisecond)`; do not copy that into new algorithms.)
- Never change Redis key names, hash field names, or score units without a read-compat path for existing data and a CHANGELOG note.
- Never raise the Redis requirement silently; Redis 7.0+ is documented in README, `Hammer.Redis` moduledoc and `FixWindow` docs, update all three together.
- Never edit `mix.lock` by hand, never skip `credo --strict` / format / `--warnings-as-errors`, no `IO.inspect` or `--no-verify`, never commit secrets.
- Never run tests against a production Redis (`FLUSHALL` runs at start of the suite).
- Never bump `@version` or create tags outside an explicit release task.
- Do not edit anything under `deps/`, `_build/`, or `doc/` (generated).

## Gotchas

- Tests skip silently (only a stderr hint) when Redis is not on `localhost:6379`; a green run with no Redis proves nothing.
- The port and URL are hard-coded in tests, `test_helper.exs`, and `bench/base.exs`; there is no env override.
- `publish.yml` exists both at the repo root and in `.github/workflows/`; only the `.github/workflows/` copy runs. The root copy is stale (older `actions/checkout@v4`).
- `RELEASE.md` is terse and has a typo (`hammer-bakend-redis`); trust the git history of release commits for the real steps.
- Fixed window `hit/4` increments even when denied; `hit_many/1` does not increment on deny. Documented in the CHANGELOG, keep it that way.
- `redis_option` type only lists `:url` and `:name`, but `start_link/1` forwards all keys to `Redix.start_link/1`.
- CI deletes nothing from Redis between modules; async test modules share one database, so key isolation relies on random keys.
- `.claude/settings.local.json` holds local permission allowances; do not treat it as project config.

## Code Search

`sgrep` is a semantic code search tool (ripgrep candidates re-ranked by local embeddings). It may not be installed on every machine: check with `command -v sgrep`; if it is missing, use `rg`/`grep` as usual and do not try to install it.

- Prefer `sgrep "natural-language question" lib/` when you are looking for a concept or behaviour and do not know the exact identifier, when the codebase is unfamiliar, or when `rg` returned too many hits or none because the naming did not match your guess.
- Keep `rg`/`grep` when you know the exact symbol, string, module name or regex, when you need every occurrence (renames, call-site audits), or when matching structured patterns (config keys, log formats, file paths).
- Always pass a directory as the second argument (`lib/`, `test/`, `assets/js/`) so `deps/`, `_build/`, `node_modules/` are skipped. The first run on a corpus builds an embedding index (slow); later runs reuse the cache. Use `--refresh-cache` after large refactors if results look stale.

## Key Files

- `lib/hammer/redis.ex`: macro that generates the user-facing API, option validation, shared helpers.
- `lib/hammer/redis/fix_window.ex`: default algorithm; shows pipelined (non-Lua) pattern plus Lua `hit_many`.
- `lib/hammer/redis/sliding_window.ex`: sorted-set Lua script, ms precision, legacy member compatibility.
- `lib/hammer/redis/token_bucket.ex`: reference Lua script and `hit_many` implementation (leaky bucket mirrors it).
- `lib/hammer/redis/leaky_bucket.ex`: leaky bucket Lua script.
- `test/test_helper.exs`: Redis availability check and `FLUSHALL`.
- `test/hammer/redis_test.exs`: tests through the public macro, including `hit_many` and error replies.
- `/Users/manu/Projects/hammer/lib/hammer.ex`: the `Hammer` behaviour and `__using__` (read-only reference).
- `CHANGELOG.md`: release history and the compatibility decisions behind current behaviour.
- `.github/workflows/ci.yml`: authoritative list of checks and the Elixir/OTP matrix.
- `compose.yml`: local Redis for tests.
- `README.md`: user docs, Redis version requirement, Cluster notes, pooling rationale.
