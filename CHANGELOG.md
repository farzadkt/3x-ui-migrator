# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed

- `backup.sh`/`restore.sh`/`lib/common.sh`: the post-dump and post-restore sanity-check row counts (`pg_sanity_counts`/`sqlite_sanity_counts`) are no longer read via `read ... <<<"$(...)"`. That pattern ran the whole function inside a command substitution, so a query failure's `die` only killed the subshell — `read` then "succeeded" against empty output, the count variables ended up empty, and the script continued as if nothing had gone wrong (a restore whose sanity check itself errored was reported as a successful restore, exit 0, instead of `EXIT_SANITY_CHECK_FAILED`). `resolve_xui_env_file`, `resolve_xui_bin`, `detect_backend`, and `extract_archive` (restore.sh) are changed the same way for consistency and to remove the underlying subshell-capture pattern entirely, even though their exit codes already survived via the `ERR` trap's passthrough. All five functions now write their result into a caller-supplied variable via `local -n` (the same pattern already used by `ssh_opts`) instead of printing for `$(...)` capture, so a `die()` inside them always terminates the real script process with its intended exit code and message. See `AUDIT.md` §1.1/§1.2.

### Added

- `backup.sh`/`restore.sh`: row-count sanity check now also covers the `settings` table (alongside `inbounds`/`users`), recorded in `meta.json`'s `source_counts` and compared post-restore with a warning on mismatch. The `settings` table holds the panel's global settings *and* the Xray Configuration template (outbounds/routing/DNS), so this gives an immediate signal that the table came across intact, distinguishing a genuine restore gap from x-ui itself failing to render already-migrated data.

## [1.0.0] - 2026-07-15

### Added

- `backup.sh`: backend detection (`XUI_DB_TYPE`/`XUI_DB_DSN`/`XUI_DB_FOLDER`), Postgres dump via `pg_dump -Fc` over TCP with `PGPASSWORD` (no `sudo -u postgres`, avoiding the classic `/root`-permission failure entirely), SQLite stop/copy/restart snapshot, cert + reference-env-file bundling, `meta.json` with source row counts, timestamped tarball with SHA256 checksum, optional direct `--push-to` SSH delivery (key or password auth, verified by remote checksum comparison — not just `scp` exit status), multi-node detection with a loud warning and required `--i-know-this-is-multi-node` override.
- `restore.sh`: target backend/DSN detection, upfront Postgres connectivity check with guidance to provision the role/db via `x-ui`'s own menu, archive backend-mismatch detection, boxed confirmation summary requiring a typed `RESTORE` (never `y/n`), unconditional stop-x-ui-first ordering before any database operation, `pg_restore --no-owner --role=<target-role> -c --if-exists` restore, SQLite file replace with `PRAGMA integrity_check` verification, cert restore with sane key/cert permissions, health-polled service start, post-restore sanity-check row counts compared against the recorded source counts.
- Cross-cutting: numbered step-banner UI, color-coded log levels, all output tee'd to `/var/log/xui-mover-<timestamp>.log`, distinct non-zero exit code per failure class, automatic last-20-lines x-ui log tail on any failure once the service has been stopped, `--dry-run` on both scripts, `--yes`/`--confirm-restore` non-interactive mode that still requires the explicit confirmation flag (never silently skips the safety gate), guarded temp-workdir cleanup on both success and failure.
- `lib/common.sh`: documented reference copy of every shared helper function (not sourced at runtime — both entry-point scripts remain independently runnable via `bash <(curl -fsSL ...)`).

### Fixed

- `cleanup()`'s `rm -rf` no longer risks overriding the script's real exit code if it ever fails while running as the `EXIT` trap under `set -e`.
- `restore.sh`'s cert-permission `find` commands now require `-type f`, so a cert directory whose name happens to contain "key" can no longer have its execute bit stripped.
- `restore.sh`'s SQLite restore now preserves the pre-existing `x-ui.db` file's owner/mode (set by the target's own install) instead of hardcoding `644`, falling back to `root:root`/`644` only when there's no pre-existing file to inherit from.
- `setup_logging` now runs before the root/OS/x-ui-installed preflight checks in both scripts, so those failures are captured in the log file too, not just printed to the terminal.
