# AI Access Assistant SessionCore

Rust sidecar for Codex Desktop session listing and provider-label repair.
Every state-access command requires an explicit path. `rollback` uses the
absolute `CODEX_HOME` bound inside its journal. No command discovers or
defaults to the caller's real `~/.codex`.

## Commands

```bash
ai-access-session-core list \
  --codex-home /explicit/path \
  --limit 50 \
  --offset 0 \
  --provider custom

ai-access-session-core pending \
  --codex-home /explicit/path \
  --recovery-root /application/support/recovery

ai-access-session-core clear-prewrite-lock \
  --codex-home /explicit/path \
  --recovery-root /application/support/recovery \
  --transaction-id 01234567-89ab-4def-8123-456789abcdef

ai-access-session-core inspect \
  --codex-home /explicit/path \
  --provider custom

ai-access-session-core repair \
  --codex-home /explicit/path \
  --provider custom \
  --journal-root /application/support/recovery \
  --journal-key-stdin

ai-access-session-core rollback \
  --journal /application/support/recovery/TRANSACTION_ID \
  --journal-key-stdin
```

`list --provider` is optional. When supplied, the result includes
`visibleTotal` for that provider while the page itself still contains all
sessions. Repair and rollback accept the 32-byte recovery key only as
unadorned RFC4648 Base64 on standard input.

`pending` never decrypts a journal. It returns either no pending state, a
validated journal path, or a `prewrite` marker for a dead transaction that
stopped before any session write. `clear-prewrite-lock` is permitted only for
that last case and archives rather than deletes the lock. A live process, any
write-stage lock, or any existing transaction journal fails closed.

`import` returns `code = "not_implemented"` in 0.11.0.

Output is JSON Lines. Each line has `schema_version`, `event`, `command`,
`ok`, and `data` or structured `code` plus `message`.

## Safety contract

- Active database: `<CODEX_HOME>/state_5.sqlite` only.
- Rollouts: recursive regular files named `rollout-*.jsonl` under
  `sessions` and `archived_sessions`.
- Symbolic links are rejected.
- Any malformed, locked, changed, or unsupported input fails the transaction.
- SQLite backup and `PRAGMA integrity_check` run before writes.
- Rollout writes use same-directory temporary files, `sync_all`, rename, and
  permission restoration.
- Journals contain inverse `session_meta` lines, not full rollout files.
- Journal directories use `0700`; files use `0600` on Unix.
- Caller must close Codex and configuration writers before `repair` or
  `rollback`.

## Build

Required toolchain is pinned in `rust-toolchain.toml`.

```bash
cargo build --release --manifest-path SessionCore/Cargo.toml
cargo test --manifest-path SessionCore/Cargo.toml
cargo clippy --manifest-path SessionCore/Cargo.toml --all-targets -- -D warnings
```

If Cargo is unavailable, run `./Tests/Shell/test-session-core.sh`. It performs source and
license gates, reports Rust tests as skipped, and prints the exact bootstrap
command. Do not install Rust silently on an end-user machine; CI or release
builders must provide the pinned toolchain.

## Licensing

Component and combined application are `AGPL-3.0-only`. See `LICENSE` and
`THIRD_PARTY_NOTICES.md`. Public DMG distribution must publish matching,
buildable complete source.
