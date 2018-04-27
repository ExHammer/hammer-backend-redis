# Changelog

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

- `hammer_backend_redis` now explicitely depends on `hammer`
- Implement the `Hammer.Backend` behaviour
- Alias `redix_config` to `redis_config` in the config list, for convenience


## 0.1.0

Initial release.
