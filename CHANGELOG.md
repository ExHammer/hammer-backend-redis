# Changelog

## 7.1.0 - 2025-08-05

### Added

- Implement sliding window algorithm with support for increment > 1
- Add inc/6 and set/6 functions for sliding window algorithm

## 7.0.2 - 2025-02-10

### Fixed

- Fix incorrect timeout typespec

## 7.0.1 - 2025-02-07

- Fix leaky bucket algorithm to use the correct formula on deny

## 7.0.0 - 2025-02-06

- Release candidate for 7.0.0. See [upgrade to v7](https://hexdocs.pm/hammer/upgrade-v7.html) for upgrade instructions.

## 7.0.0-rc.1 (2024-12-18)

### Changed

- Added `:algorithm` option to the backend with support for:
  - `:fix_window` (default) - Fixed time window rate limiting
  - `:leaky_bucket` - Constant rate limiting with burst capacity
  - `:token_bucket` - Token-based rate limiting with burst capacity
- Add benchmarks file and run them with `bench`

## 7.0.0-rc.0 (2024-12-06)

### Changed

- Conform to new Hammer API
- Remove Poolboy as it introduces unnecessary blocking.

## 6.2.0 (2024-12-04)

### Changed

- Package updates
- Add config to customize the redis prefix
- Deprecate Elixir 1.12 as this are no longer supported

## 6.1.2 (2022-11-11)

### Changed

- Applied credo suggestions
- Update dependencies

## 6.1.1 (2022-11-11)

### Changed

- package update and ownership transferred

## 6.1.0 (2019-09-03)

### Changed

- Return actual count upon bucket creation (thanks to @davelively14, https://github.com/ExHammer/hammer-backend-redis/pull/16)


## 6.0.1 (2019-07-13)

### Added

- Accept an optional `redis_url` option

### Changed

- Updated dependencies in test environment (thanks to @ono, https://github.com/ExHammer/hammer-backend-redis/pull/14)

### Fixed

- Fixed a crash in `delete_buckets` (thanks to @ono, https://github.com/ExHammer/hammer-backend-redis/pull/15)


## 6.0.0 (2018-10-13)

### Changed

- Raise an error if `expiry_ms` is not configured explicitly
- Update the `redix` dependency to `~> 0.8`


### Fixed

- Actually honor `:redis_config`, as is claimed in the documentation

## 5.0.0 (2018-10-13)

### Changed

- Update to the new custom-increment api

## 4.0.3 (2018-05-08)

### Fixed

- Fix a rare crash, again related to race-conditions
  (https://github.com/ExHammer/hammer-backend-redis/issues/11#issuecomment-387202359)

## 4.0.2 (2018-04-27)

### Fixed

- Fixed race-condition, really this time
  (https://github.com/ExHammer/hammer-backend-redis/issues/11)


## 4.0.1 (2018-04-24)

### Fixed

- Fixed a race-condition that could cause crashes
  (https://github.com/ExHammer/hammer-backend-redis/issues/11)


## 4.0.0 (2018-04-23)

### Changed

- Update to `Hammer 4.0`


## 3.0.0 (2018-02-20)

### Changed

- Require elixir >= 1.6


## 2.0.0 (2017-09-24)

### Changed

- Updated to new Hammer API


## 1.0.0 (2017-08-27)

### Changed

- `hammer_backend_redis` now explicitly depends on `hammer`
- Implement the `Hammer.Backend` behaviour
- Alias `redix_config` to `redis_config` in the config list, for convenience


## 0.1.0 (2017-07-31)

Initial release.
