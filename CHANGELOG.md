# Changelog

## 7.0.0-rc.0 (2024-12-06)

### Changed

- Conform to new Hammer API

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
