# 3x-ui-migrator

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg)](https://www.gnu.org/software/bash/)

**Languages:** English | [فارسی](README.fa.md)

Migrate a [3x-ui](https://github.com/MHSanaei/3x-ui) panel — inbounds, clients, users, settings, certs — from one server to another with **one command on the old server and one command on the new server.**

Maintained by [Farzad](https://github.com/farzadkt) at [farzadkt/3x-ui-migrator](https://github.com/farzadkt/3x-ui-migrator).

## Why this exists

The official guidance for moving a 3x-ui panel is "copy `/etc/x-ui/` and `/root/cert/`." That's incomplete and actively misleading if you're on the PostgreSQL backend: your actual panel data (inbounds, clients, users) lives inside PostgreSQL, not in those directories. Copy just the files and your "restored" panel boots up empty. On top of that, `pg_dump` run as the `postgres` system user can't even traverse into `/root` (mode 700), each server generates its own random DB credentials at install time, and starting x-ui on the target even briefly before you restore will bootstrap a conflicting schema that breaks every subsequent restore attempt.

`3x-ui-migrator` handles all of that automatically — for both the PostgreSQL and SQLite backends — so you don't have to know any of it.

## Features

Everything below is detected automatically; there's nothing to configure by hand.

- Detects the backend (PostgreSQL or SQLite), the panel's database path/DSN, and the x-ui binary/service via systemd — no manual config.
- Backs up the database, `/root/cert/`, acme.sh / Let's Encrypt trees when present, extra cert paths referenced by the panel, and a reference copy of the environment file into one timestamped, checksummed tarball. Panel login credentials (admin username/password) live inside the database itself, so they're carried over automatically as part of the DB backup — no separate step needed.
- Restores with an explicit typed `RESTORE` confirmation gate — nothing destructive happens by accident.
- Post-restore sanity check compares row counts against the source backup and warns on mismatch.
- **Inbound listen-address detection, decided by you.** If the source panel pinned an inbound to that server's own IP, the literal travels with the database and cannot be bound on the target: xray-core crash-loops with `bind: cannot assign requested address` and **not one inbound serves traffic**, while the panel itself comes up fine and every row count matches — a completely silent failure. `restore.sh` finds those inbounds, lists them, and **asks** whether to repoint them at the target's own IP. Use `--rebind-listen` to answer yes up front, `--no-rebind-listen` to never touch them, or `--listen-address ADDR` to choose the address yourself.
- Post-restore xray-core health check: an `active` x-ui unit is not proof of success, since xray is a child process that restarts itself, so the service log is checked and a crash-looping core is reported explicitly with a non-zero exit.
- Optional direct SSH push (`--push-to`) straight from the old server to the new one, verified by remote checksum comparison — skips the manual `scp` step entirely.
- Multi-node installs are detected and blocked by default (only single-node migrations are supported — see [Limitations & notes](#limitations--notes)).
- Every run logs to a file and exits with a distinct, documented code per failure class.
- `--dry-run` on both scripts to preview what would happen with no changes made.

## Requirements

- Root SSH access to both the old and new server.
- Debian/Ubuntu with systemd on both ends (matches 3x-ui's own support matrix).
- x-ui already installed on **both** servers, with the target's backend (Postgres or SQLite) already configured. `restore.sh` does not install x-ui and does not provision a Postgres role/database for you — if the target's Postgres role/db doesn't exist yet, run `x-ui`'s own CLI menu on the target to set it up first, then re-run `restore.sh`.
- Single-node 3x-ui only (the newer master/node architecture is not supported yet — see [Limitations & notes](#limitations--notes)).

## Source server usage

Run this **one command** on the old server you're migrating away from:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/backup.sh)
```

**What it does:** detects your x-ui install, database backend, and database path/DSN; takes a consistent backup of the database, `/root/cert/`, and any acme.sh / Let's Encrypt / custom cert paths it can find; and packages everything into one checksummed tarball under `/root/xui-mover/`. It prints the archive path and a ready-to-copy `scp` command for step two.

Want to skip the manual copy step? Push the archive straight to the new server in the same command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/backup.sh) --push-to root@new-server-ip
```

## Destination server usage

Once the archive has landed on the new server (via `scp` or `--push-to`), run this **one command**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/restore.sh) --archive /root/xui-mover-incoming/xui-backup-....tar.gz
```

**What it does:** detects this server's own x-ui install and configured backend, shows exactly what it's about to overwrite, and — after you type `RESTORE` to confirm — stops x-ui, takes a timestamped safety snapshot of the target, restores the database and certs, restarts x-ui, and runs a post-restore sanity check comparing row counts against the source.

## Backup flow

What `backup.sh` actually does, in order:

1. Confirms it's running as root on a supported Debian/Ubuntu + systemd host with x-ui installed.
2. Detects the environment file, backend (Postgres/SQLite), and x-ui version.
3. Checks for a multi-node setup and aborts (unless overridden) if one is found.
4. Dumps the database — `pg_dump -Fc` for Postgres, or a clean file copy after briefly stopping x-ui for SQLite — and records row-count sanity totals.
5. Copies `/root/cert/`, plus `/root/.acme.sh`, `/etc/letsencrypt`, and any extra cert files referenced in panel settings when those exist, and a reference copy of the environment file.
6. Builds a single timestamped, checksummed tarball.
7. Prints the local path, or pushes it to the target over SSH if `--push-to` was given.

**Archive contents:**

```
xui-backup-<hostname>-<UTC timestamp>.tar.gz
├── meta.json                    # tool version, backend, x-ui version, source row counts
├── db/x-ui.dump                 # Postgres: pg_dump -Fc output   (mutually exclusive with db/x-ui.db)
├── db/x-ui.db                   # SQLite: raw database file
├── cert/                        # recursive copy of /root/cert
├── extra-certs/                 # optional: acme.sh, letsencrypt, and other referenced cert files
└── etc-default-x-ui.reference   # reference-only copy of the source's env file — do NOT apply verbatim on the target, XUI_DB_DSN is server-specific
```

**Security note:** the archive is a plain, unencrypted tarball containing database credentials and TLS private keys. Treat it as a secret — delete it after the migration completes, and don't leave it on shared or log-shipped storage.

## Restore flow

What `restore.sh` actually does, in order:

1. Confirms it's running as root on a supported host with x-ui installed, and detects this server's own backend/DSN.
2. Extracts the archive and checks its backend matches this server's configured backend.
3. Prints exactly what will be overwritten and requires you to type `RESTORE` (or pass `--yes --confirm-restore` for scripted use — `--yes` alone is never enough).
4. Stops x-ui.
5. Writes a timestamped pre-restore snapshot of the target database (and `/root/cert`) under `/root/xui-mover/`.
6. Restores the database (`pg_restore --single-transaction --no-owner -c --if-exists` for Postgres, or a file copy + `PRAGMA integrity_check` for SQLite).
7. Finds inbounds pinned to an IP this server does not have, lists them, and asks whether to repoint them at this server's own IP. This happens here on purpose — after the database is in place and before x-ui starts — so xray reads the corrected config on its very first run. Inbounds whose address is bindable here, or already empty, are left alone.
8. Restores certs into `/root/cert/` (replace, not merge) and any extra-certs (acme.sh / Let's Encrypt / custom paths).
9. Starts x-ui, waits for it to become active, then checks the service log to confirm xray-core actually came up rather than crash-looping.
10. Runs the post-restore sanity check and prints a summary.

Every run logs to `/var/log/xui-mover-<timestamp>.log` (ANSI stripped) — attach this file when asking for help. Any failure after x-ui has been stopped automatically prints the last ~20 lines of the x-ui log so you don't have to go hunting for it.

## Flags reference

### `backup.sh`

| Flag | Description |
|---|---|
| `--push-to USER@HOST[:PORT]` | Push the archive to a target server over SSH instead of leaving it local |
| `-i, --identity PATH` | SSH private key to use for `--push-to` |
| `--remote-dir PATH` | Remote directory to push into (default `/root/xui-mover-incoming`) |
| `--i-know-this-is-multi-node` | Required to proceed if this panel has registered nodes |
| `--service-timeout SECS` | Seconds to wait for x-ui to stop/start (default 30, or `XUI_MOVER_SERVICE_TIMEOUT`) |
| `--yes` | Assume yes on informational prompts (does not bypass the multi-node guard) |
| `--dry-run` | Print what would happen; make no changes |
| `--no-color` | Disable colored output |
| `-h, --help` | Show full usage |

### `restore.sh`

| Flag | Description |
|---|---|
| `--archive PATH` | Local path to the backup tarball (prompted interactively if omitted) |
| `--yes` | Non-interactive mode — **requires** `--confirm-restore` too |
| `--confirm-restore` | Explicit non-interactive equivalent of typing `RESTORE` at the safety prompt |
| `--rebind-listen` | Repoint, without asking, any inbound pinned to an IP this server does not have |
| `--no-rebind-listen` | Never repoint; keep every inbound's listen address exactly as it was on the source |
| `--listen-address ADDR` | Address to repoint to (default: this server's own primary IP, auto-detected). An empty value binds all interfaces |
| `--service-timeout SECS` | Seconds to wait for x-ui to stop/start (default 30, or `XUI_MOVER_SERVICE_TIMEOUT`) |
| `--dry-run` | Print what would happen; make no changes |
| `--no-color` | Disable colored output |
| `-h, --help` | Show full usage |

## Exit codes

Every failure exits with a distinct, documented code — never a bare `exit 1` — so you can branch on `$?` in scripted use or quote the number when asking for help.

| Code | Meaning | Code | Meaning |
|---|---|---|---|
| 0 | Success | 14 | Local checksum verification failed |
| 1 | Unexpected/unhandled error | 15 | SSH connectivity test failed |
| 2 | Not running as root | 16 | Push succeeded per `scp` but remote checksum mismatch |
| 3 | Unsupported OS | 17 | Archive missing, corrupt, or missing `meta.json` |
| 4 | x-ui service/binary not found | 18 | Archive backend doesn't match target's backend |
| 5 | x-ui environment file not found | 19 | Postgres role/database unreachable |
| 6 | Unrecognized `XUI_DB_TYPE` value | 20 | Confirmation not received |
| 7 | `XUI_DB_DSN` missing or unparseable | 21 | x-ui didn't stop within the timeout |
| 8 | SQLite database file not found | 22 | Database restore failed |
| 9 | `pg_dump`/`pg_restore`/`psql` not installed | 23 | Post-restore sanity-check query itself errored |
| 10 | `sqlite3` not installed | 24 | x-ui didn't start within the timeout |
| 11 | Multi-node setup detected, no override flag | 25 | Cert restore failed |
| 12 | Database dump failed | 26 | Invalid flag combination |
| 13 | Archive build (`tar`) failed | 27 | Not enough free disk space |

## Limitations & notes

- **Single-node only.** If `backup.sh` detects rows in the `nodes` table, it warns loudly and refuses to proceed without `--i-know-this-is-multi-node` — and even then, only master-node data (inbounds/settings/certs) is backed up; per-node API tokens/config are not migrated.
- **Same-or-compatible x-ui schema version assumed.** Migrating across incompatible x-ui schema versions is out of scope.
- **No archive encryption.** The tarball is plaintext and contains credentials + private keys — handle it accordingly.
- **Debian/Ubuntu + systemd only**, matching 3x-ui's own support matrix.
- **One-shot migration tool**, not a backup/cron solution.
- **Inbound listen addresses:** only inbounds whose address does not exist on the target are candidates, and they are only changed if you say so. On a NAT'd target the detected IP is a private address — correct, since that is what is actually bindable — but `--listen-address` lets you override it. Note this only fixes the `listen` field; the address or domain handed to end users in subscription links is stored elsewhere and must be updated separately.
- **Certs:** `/root/cert` is always captured. `/root/.acme.sh`, `/etc/letsencrypt`, and cert/key paths stored in panel settings are captured when they exist. Renewal crons/systemd timers are not installed for you on the target.

See [`AUDIT.md`](AUDIT.md) for a full, actively-maintained list of known issues and edge cases.

## Roadmap

Prioritized by the project's own [`AUDIT.md`](AUDIT.md), highest-impact first:

- [x] Fix silently-swallowed sanity-check failures on restore (false "success" reporting).
- [x] Capture SQLite WAL/SHM sidecar files during backup and restore.
- [x] Expand certificate migration beyond `/root/cert` (acme.sh, Let's Encrypt/certbot paths).
- [x] Auto-restart x-ui on the source if a backup is interrupted mid-snapshot.
- [x] Pre-restore safety snapshot on the target before the destructive restore step.
- [ ] Multi-node migration support.

No new features are planned ahead of the reliability fixes above — see [`CHANGELOG.md`](CHANGELOG.md) for what's already shipped.

## License

MIT — see [LICENSE](LICENSE). See [CHANGELOG.md](CHANGELOG.md) for release history.

## Maintainer

Maintained by **Farzad** ([@farzadkt](https://github.com/farzadkt)).

- Repository: [farzadkt/3x-ui-migrator](https://github.com/farzadkt/3x-ui-migrator)
- Issues and contributions: open an issue or PR on the repo above.
