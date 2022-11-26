# Changelog
## 6.1.2 (2022-11-11)

### Changed

- Applied credo suggestions
- Update dependencies
## 6.1.1 (2022-11-11)

### Changed

- package update and ownership transferred

## 6.1.0

### Changed

- Return actual count upon bucket creation (thanks to @davelively14, https://github.com/ExHammer/hammer-backend-redis/pull/16)


## 6.0.1

### Added

- Accept an optional `redis_url` option

### Changed

- Updated dependencies in test environment (thanks to @ono, https://github.com/ExHammer/hammer-backend-redis/pull/14)

### Fixed

- Fixed a crash in `delete_buckets` (thanks to @ono, https://github.com/ExHammer/hammer-backend-redis/pull/15)


## 6.0.0

### Changed

- Raise an error if `expiry_ms` is not configured explicitly
- Update the `redix` dependency to `~> 0.8`


### Fixed

- Actually honor `:redis_config`, as is claimed in the documentation


## 4.0.3

### Fixed

- Fix a rare crash, again related to race-conditions
  (https://github.com/ExHammer/hammer-backend-redis/issues/11#issuecomment-387202359)

## 4.0.2

### Fixed

- Fixed race-condition, really this time
  (https://github.com/ExHammer/hammer-backend-redis/issues/11)


## 4.0.1

### Fixed

- Fixed a race-condition that could cause crashes
  (https://github.com/ExHammer/hammer-backend-redis/issues/11)


## 4.0.0

### Changed

- Update to `Hammer 4.0`


## 3.0.0

### Changed

- Require elixir >= 1.6


## 2.0.0

### Changed

- Updated to new Hammer API


## 1.0.0

### Changed

- `hammer_backend_redis` now explicitly depends on `hammer`
- Implement the `Hammer.Backend` behaviour
- Alias `redix_config` to `redis_config` in the config list, for convenience


## 0.1.0

Initial release.
