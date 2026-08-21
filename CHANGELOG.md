# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed

- `url_decode` no longer treats `+` as space in the Postgres password (URI userinfo, not a query string) and only decodes valid `%HH` sequences, so a literal `+` or backslash in the DSN password is no longer corrupted (AUDIT.md §1.3/§1.4).
- `parse_pg_dsn` accepts optional password, optional port (defaults to 5432), and IPv6 hosts in brackets instead of requiring `user:pass@host:port` (AUDIT.md §11.2).
- `backup.sh` no longer dies with a generic exit 1 when the environment file is missing: writing `etc-default-x-ui.reference` skipped `cat` of an empty path under `set -e`. SQLite-only installs now write a placeholder reference file.
- Trailing flags without a value (`--push-to`, `--archive`, `--remote-dir`, `-i`) now exit `EXIT_BAD_ARGS` (26) instead of tripping the ERR trap via `shift 2` (AUDIT.md §1.7).
- `write_meta_json` JSON-escapes hostname/backend/version so a `"` in `hostname` or `x-ui -v` can no longer produce invalid `meta.json` (AUDIT.md §1.8).
- `restore.sh` now warns on a post-restore **users** count mismatch, not only inbounds/settings (AUDIT.md §1.5).
- Multi-node guard no longer treats a failed `nodes` query as "0 nodes" / single-node; only a genuinely missing table is zero, any other error aborts (AUDIT.md §2.3). `backup.sh` also tests the Postgres connection before dumping.
- `--remote-dir` is passed to the remote shell via `printf %q` so a quote in the path cannot break out of the SSH command (AUDIT.md §4.3).
- `setup_logging` `chmod 600`s the log file and restores stdio on exit so tee/sed flush the last lines (AUDIT.md §2.4/§4.5).
- Interrupt (Ctrl-C / SIGTERM) during the SQLite backup snapshot window restarts x-ui instead of leaving the source panel down (AUDIT.md §2.1).
- `backup.sh`/`restore.sh`/`lib/common.sh`: `resolve_xui_env_file` no longer dies when no environment file is found. x-ui's own systemd unit declares `EnvironmentFile=/etc/default/x-ui` with `ignore_errors=yes` — confirmed against a real install — because that file is only ever created when Postgres is configured through x-ui's own setup menu; a plain SQLite install may never have one at all. Its absence now leaves the env-file variable empty and continues straight to backend auto-detection (`detect_backend`/`resolve_sqlite_path` already default to SQLite when it's missing/unreadable), instead of exiting with `EXIT_ENV_FILE_MISSING`. Reported and reproduced against a live SQLite-only 3x-ui 3.6.0 install.

### Added

- `restore.sh`: detection and optional correction of inbounds pinned to the **source** server's IP. 3x-ui stores a per-inbound `listen` address; when the source panel pinned inbounds to its own public IP, that literal travels with the database and is unbindable on the target, so xray-core dies with `bind: cannot assign requested address` and crash-loops. Because the panel itself starts fine and every sanity count matches, the migration reported success while **no inbound served traffic** — verified against a live 3x-ui 3.6.0 SQLite migration. `rebind_stale_inbound_listens` now scans restored inbounds against the addresses actually assigned to this host, lists the unbindable ones, and asks whether to repoint them at this server's own primary IP (`primary_local_ip`, taken from the routing table so tunnel/docker interfaces cannot win). The rewrite runs after the database is placed and before x-ui starts, so xray reads the corrected config on its first run. Inbounds that are already bindable here, or already empty, are never touched. `--rebind-listen` / `--no-rebind-listen` answer the prompt up front; `--listen-address ADDR` overrides the detected IP (empty means bind all interfaces, which is also the fallback when the primary IP cannot be determined). A non-interactive run given neither flag changes nothing and says so, rather than deciding for the user or aborting with x-ui stopped.
- `restore.sh`: `verify_xray_running` checks the service log after startup for xray-core's own start/failure lines, since an `active` x-ui unit says nothing about the child xray process. A crash-looping core is now reported with the actual bind error, surfaced in the summary box, and exits `EXIT_RESTORE_FAILED` (22) instead of printing "Restore complete".
- Certificate capture now includes `/root/.acme.sh`, `/etc/letsencrypt`, and cert/key paths referenced in panel settings (`webCertFile`/`webKeyFile` and inbound settings), not only `/root/cert` (AUDIT.md §9.1). Restore **replaces** `/root/cert` instead of merging stale target files (AUDIT.md §9.2) and hardens key vs cert permissions via openssl when available (AUDIT.md §4.2).
- `restore.sh` writes a timestamped pre-restore snapshot of the target DB (and `/root/cert`) under `/root/xui-mover/` before the destructive restore, and `pg_restore` runs with `--single-transaction` (AUDIT.md §2.2/§11.1).
- `--service-timeout SECS` (or `XUI_MOVER_SERVICE_TIMEOUT`) overrides the 30s x-ui stop/start wait (AUDIT.md §2.5). Free-space preflight (`EXIT_DISK_FULL=27`) before dump/extract (AUDIT.md §2.6).
- `backup.sh`/`restore.sh`/`lib/common.sh`: SQLite backup and restore now correctly handle the `-wal`/`-shm` WAL-mode sidecar files, not just the main `.db` file. Backup copies all three as one matched set (`sqlite_copy_with_sidecars`) while x-ui is stopped (no concurrent writer), so a snapshot can no longer silently miss rows that were committed to the WAL but not yet checkpointed into the main file. Restore removes any stale `-wal`/`-shm` left by the target's previous database (`sqlite_remove_sidecars`) before placing the new set, so SQLite can no longer replay an old WAL over a freshly restored `.db`. Closes `AUDIT.md` §10.1 (HIGH).
- `backup.sh`: after building the archive, `verify_local_checksum` re-reads it from disk and checks it against its own just-written `.sha256` sidecar, putting the previously-unused `EXIT_CHECKSUM_MISMATCH` (14) to actual use. Closes the "local checksum verification never implemented" gap noted in `AUDIT.md` §13.
- `restore.sh`: `extract_archive` now runs `tar tzf` (structural-only check, no extraction) before extracting, so a truncated/corrupted archive fails clearly with `EXIT_ARCHIVE_INVALID` instead of a partial extraction or a confusing downstream error. If a `.sha256` sidecar is present next to the archive (always true after `--push-to`; true for a manual `scp` only if it was copied too), `verify_archive_checksum_if_present` verifies the archive against it before extracting; if absent, this is a silent no-op and only the structural check applies.

### Changed

- `backup.sh`/`restore.sh`/`lib/common.sh`: `make_workdir` now explicitly `chmod 700`s `WORK_ROOT`/`WORKDIR` instead of relying on `mkdir -p -m 700`, which only applies the requested mode to directories it actually creates — a pre-existing `WORK_ROOT` (e.g. left over from an older version) previously kept whatever permissions it already had, silently defeating the "credential-bearing files stay under a 700 directory" guarantee.
- `backup.sh`/`restore.sh`/`lib/common.sh`: replaced the hardcoded `XUI_SERVICE="x-ui"` assumption and its `/usr/local/x-ui` fallback path with `discover_xui_installation`, which scans every systemd service unit for one that plausibly refers to x-ui/3x-ui and verifies each candidate's `ExecStart` actually resolves to an existing, executable binary before trusting it. Auto-selects when exactly one valid installation is found; prompts interactively to choose when more than one is found; dies with `EXIT_XUI_NOT_INSTALLED` when none are found. `XUI_MAIN_FOLDER_DEFAULT` is removed as it's no longer needed.

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
