# 3x-ui-migrator

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg)](https://www.gnu.org/software/bash/)

**Languages:** English | [فارسی](README.fa.md)

Migrate a [3x-ui](https://github.com/MHSanaei/3x-ui) panel — inbounds, clients, settings, certs — from one server to another with one guided command on each end.

Maintained by [Farzad](https://github.com/farzadkt) at [farzadkt/3x-ui-migrator](https://github.com/farzadkt/3x-ui-migrator).

## Why this exists

The official guidance for moving a 3x-ui panel is "copy `/etc/x-ui/` and `/root/cert/`." That's incomplete and actively misleading if you're on the PostgreSQL backend: your actual panel data (inbounds, clients, users) lives inside PostgreSQL, not in those directories. Copy just the files and your "restored" panel boots up empty. On top of that, `pg_dump` run as the `postgres` system user can't even traverse into `/root` (mode 700), each server generates its own random DB credentials at install time, and starting x-ui on the target even briefly before you restore will bootstrap a conflicting schema that breaks every subsequent restore attempt.

`3x-ui-migrator` handles all of that automatically — for both the PostgreSQL and SQLite backends — so you don't have to know any of it.

## Features

- Detects the backend (PostgreSQL or SQLite), panel paths, and x-ui binary automatically — no manual config.
- Backs up the database, `/root/cert/`, and a reference copy of the environment file into one timestamped, checksummed tarball.
- Restores with an explicit typed `RESTORE` confirmation gate — nothing destructive happens by accident.
- Post-restore sanity check compares row counts against the source backup and warns on mismatch.
- Optional direct SSH push (`--push-to`) from source to target, verified by remote checksum comparison.
- Multi-node installs are detected and blocked by default (only single-node migrations are supported — see [Notes & limitations](#notes--limitations)).
- Every run logs to a file and exits with a distinct, documented code per failure class.
- `--dry-run` on both scripts to preview what would happen with no changes made.

## Requirements

- Root SSH access to both the old and new server.
- Debian/Ubuntu with systemd on both ends (matches 3x-ui's own support matrix).
- x-ui already installed on **both** servers, with the target's backend (Postgres or SQLite) already configured. `restore.sh` does not install x-ui and does not provision a Postgres role/database for you — if the target's Postgres role/db doesn't exist yet, run `x-ui`'s own CLI menu on the target to set it up first, then re-run `restore.sh`.
- Single-node 3x-ui only (the newer master/node architecture is not supported yet — see [Notes & limitations](#notes--limitations)).

## Installation

Nothing to install ahead of time — both scripts are self-contained and run directly from the repo via `curl`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/backup.sh)
```

If you'd rather review before running, clone the repo instead:

```bash
git clone https://github.com/farzadkt/3x-ui-migrator.git
cd 3x-ui-migrator
sudo bash backup.sh
```

## Usage

Run `backup.sh` on the source server, then `restore.sh` on the target server, pointing it at the archive `backup.sh` produced. Both scripts support `-h`/`--help` for the full flag list, and `--dry-run` to preview without changing anything.

## Backup workflow

On the **old** server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/backup.sh)
```

This produces a tarball and prints its path, checksum, and a ready-to-copy `scp` command. Alternatively, push it straight to the new server in one step:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/backup.sh) --push-to root@new-server-ip
```

**Key flags:**

| Flag | Description |
|---|---|
| `--push-to USER@HOST[:PORT]` | Push the archive to a target server over SSH instead of leaving it local |
| `-i, --identity PATH` | SSH private key to use for `--push-to` |
| `--remote-dir PATH` | Remote directory to push into (default `/root/xui-mover-incoming`) |
| `--i-know-this-is-multi-node` | Required to proceed if this panel has registered nodes |
| `--dry-run` | Print what would happen; make no changes |
| `-h, --help` | Show full usage |

**What's in the archive:**

```
xui-backup-<hostname>-<UTC timestamp>.tar.gz
├── meta.json                    # tool version, backend, x-ui version, source row counts
├── db/x-ui.dump                 # Postgres: pg_dump -Fc output   (mutually exclusive with db/x-ui.db)
├── db/x-ui.db                   # SQLite: raw database file
├── cert/                        # recursive copy of /root/cert
└── etc-default-x-ui.reference   # reference-only copy of the source's env file — do NOT apply verbatim on the target, XUI_DB_DSN is server-specific
```

**Security note:** the archive is a plain, unencrypted tarball containing database credentials and TLS private keys. Treat it as a secret — delete it after the migration completes, and don't leave it on shared or log-shipped storage.

## Restore workflow

On the **new** server, once the archive has landed there:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/restore.sh) --archive /root/xui-mover-incoming/xui-backup-....tar.gz
```

`restore.sh` shows exactly what it's about to overwrite and requires you to type `RESTORE` before touching anything. Type anything else and it aborts with zero changes made.

**Key flags:**

| Flag | Description |
|---|---|
| `--archive PATH` | Local path to the backup tarball (prompted interactively if omitted) |
| `--yes` | Non-interactive mode — **requires** `--confirm-restore` too |
| `--confirm-restore` | Explicit non-interactive equivalent of typing `RESTORE` at the safety prompt |
| `--dry-run` | Print what would happen; make no changes |
| `-h, --help` | Show full usage |

`--yes` alone never skips the destructive-action confirmation — it must be paired with `--confirm-restore`, so scripted/CI use can never silently bypass the safety gate.

Every run logs to `/var/log/xui-mover-<timestamp>.log` (ANSI stripped) — attach this file when asking for help. Any failure after `restore.sh` has stopped x-ui automatically prints the last ~20 lines of the x-ui log so you don't have to go hunting for it.

## Exit codes

Every failure exits with a distinct, documented code — never a bare `exit 1` — so you can branch on `$?` in scripted use or quote the number when asking for help.

| Code | Meaning | Code | Meaning |
|---|---|---|---|
| 0 | Success | 14 | Local checksum verification failed |
| 1 | Unexpected/unhandled error | 15 | SSH connectivity test failed |
| 2 | Not running as root | 16 | Push succeeded per `scp` but remote checksum mismatch |
| 3 | Unsupported OS | 17 | Archive missing, corrupt, or missing `meta.json` |
| 4 | x-ui service/binary not found | 18 | Archive backend doesn't match target's backend |
| 5 | x-ui environment file not found | 19 | Target's configured Postgres role/database unreachable |
| 6 | Unrecognized `XUI_DB_TYPE` value | 20 | Confirmation not received |
| 7 | `XUI_DB_DSN` missing or unparseable | 21 | x-ui didn't stop within the timeout |
| 8 | SQLite database file not found | 22 | Database restore failed |
| 9 | `pg_dump`/`pg_restore`/`psql` not installed | 23 | Post-restore sanity-check query itself errored |
| 10 | `sqlite3` not installed | 24 | x-ui didn't start within the timeout |
| 11 | Multi-node setup detected, no override flag | 25 | Cert restore failed |
| 12 | Database dump failed | 26 | Invalid flag combination |
| 13 | Archive build (`tar`) failed | | |

## Notes & limitations

- **Single-node only.** If `backup.sh` detects rows in the `nodes` table, it warns loudly and refuses to proceed without `--i-know-this-is-multi-node` — and even then, only master-node data (inbounds/settings/certs) is backed up; per-node API tokens/config are not migrated.
- **Same-or-compatible x-ui schema version assumed.** Migrating across incompatible x-ui schema versions is out of scope.
- **No archive encryption.** The tarball is plaintext and contains credentials + private keys — handle it accordingly.
- **Debian/Ubuntu + systemd only**, matching 3x-ui's own support matrix.
- **One-shot migration tool**, not a backup/cron solution.
- **Certs:** only `/root/cert` is captured. If your panel uses acme.sh, Let's Encrypt/certbot, or a custom cert path, migrate those separately.

See [`AUDIT.md`](AUDIT.md) for a full, actively-maintained list of known issues and edge cases.

## Roadmap

Prioritized by the project's own [`AUDIT.md`](AUDIT.md), highest-impact first:

- [x] Fix silently-swallowed sanity-check failures on restore (false "success" reporting).
- [ ] Capture SQLite WAL/SHM sidecar files during backup and restore.
- [ ] Expand certificate migration beyond `/root/cert` (acme.sh, Let's Encrypt/certbot paths).
- [ ] Auto-restart x-ui on the source if a backup is interrupted mid-snapshot.
- [ ] Pre-restore safety snapshot on the target before the destructive restore step.
- [ ] Multi-node migration support.

No new features are planned ahead of the reliability fixes above — see [`CHANGELOG.md`](CHANGELOG.md) for what's already shipped.

## License

MIT — see [LICENSE](LICENSE). See [CHANGELOG.md](CHANGELOG.md) for release history.

## Maintainer

Maintained by **Farzad** ([@farzadkt](https://github.com/farzadkt)).

- Repository: [farzadkt/3x-ui-migrator](https://github.com/farzadkt/3x-ui-migrator)
- Issues and contributions: open an issue or PR on the repo above.
