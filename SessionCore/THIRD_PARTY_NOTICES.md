# Third-party notices

## CodexPlusPlus

SessionCore adapts provider visibility synchronization, Codex `threads`
pagination, rollout discovery, and SQLite metadata-repair behavior from:

- Project: BigPizzaV3/CodexPlusPlus
- Version: `v1.2.41`
- Commit: `3dafffcafb2566a1e8bce4b35671656d6adb3eda`
- Upstream files:
  - `crates/codex-plus-data/src/provider_sync.rs`
  - `crates/codex-plus-data/src/storage.rs`
  - `crates/codex-plus-core/src/codex_sqlite.rs`
- License: `AGPL-3.0-only`
- Source: <https://github.com/BigPizzaV3/CodexPlusPlus>

Copyright remains with BigPizzaV3 and CodexPlusPlus contributors.

AI Access Assistant changes:

- fixed active database contract to root `state_5.sqlite`;
- replaced skipped-file success with fail-closed transactions;
- added SQLite Backup API snapshots and integrity gates;
- replaced full rollout copies with inverse metadata patches;
- added same-volume atomic rollout replacement;
- added JSON Lines sidecar protocol and paginated SQLite-only listing;
- added explicit rollback and crash-recovery journals.

Binary distribution must provide complete corresponding source for both this
adaptation and the combined AGPL-covered application.
