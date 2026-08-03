# xui-mover

**Languages:** English | [فارسی](README.fa.md)

Migrate a [3x-ui](https://github.com/MHSanaei/3x-ui) panel — inbounds, clients, settings, certs — from one server to another with one guided command on each end.

The official guidance for moving a 3x-ui panel is "copy `/etc/x-ui/` and `/root/cert/`." That's incomplete and actively misleading if you're on the PostgreSQL backend: your actual panel data (inbounds, clients, users) lives inside PostgreSQL, not in those directories. Copy just the files and your "restored" panel boots up empty. On top of that, `pg_dump` run as the `postgres` system user can't even traverse into `/root` (mode 700), each server generates its own random DB credentials at install time, and starting x-ui on the target even briefly before you restore will bootstrap a conflicting schema that breaks every subsequent restore attempt.

`xui-mover` handles all of that automatically — for both the PostgreSQL and SQLite backends — so you don't have to know any of it.

## Requirements

- Root SSH access to both the old and new server.
- Debian/Ubuntu with systemd on both ends (matches 3x-ui's own support matrix).
- x-ui already installed on **both** servers, with the target's backend (Postgres or SQLite) already configured. `restore.sh` does not install x-ui and does not provision a Postgres role/database for you — if the target's Postgres role/db doesn't exist yet, run `x-ui`'s own CLI menu on the target to set up PostgreSQL first, then re-run `restore.sh`.
- Single-node 3x-ui only (the newer master/node architecture is not supported in v1 — see [Limitations](#limitations)).

## Quick start

On the **old** server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alionthecode/xui-mover/main/backup.sh)
```

This produces a tarball and prints its path, checksum, and a ready-to-copy `scp` command. Alternatively, push it straight to the new server in one step:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alionthecode/xui-mover/main/backup.sh) --push-to root@new-server-ip
```

On the **new** server, once the archive has landed there:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alionthecode/xui-mover/main/restore.sh) --archive /root/xui-mover-incoming/xui-backup-....tar.gz
```

`restore.sh` shows you exactly what it's about to overwrite and requires you to type `RESTORE` before touching anything. Type anything else and it aborts with zero changes made.

## What's in the archive

```
xui-backup-<hostname>-<UTC timestamp>.tar.gz
├── meta.json                    # tool version, backend, x-ui version, source row counts
├── db/x-ui.dump                 # Postgres: pg_dump -Fc output   (mutually exclusive with db/x-ui.db)
├── db/x-ui.db                   # SQLite: raw database file
├── cert/                        # recursive copy of /root/cert
└── etc-default-x-ui.reference   # reference-only copy of the source's env file — do NOT apply verbatim on the target, XUI_DB_DSN is server-specific
```

**Security caveat:** the archive is a plain, unencrypted tarball. It contains your database credentials and TLS private keys. Treat it as a secret — delete it after the migration completes, don't leave it sitting on shared or log-shipped storage, and don't commit it anywhere. Encrypting the archive at rest is not implemented in v1 (see Limitations).

## Flags

### `backup.sh`

| Flag | Description |
|---|---|
| `--push-to USER@HOST[:PORT]` | Push the archive to a target server over SSH instead of leaving it local |
| `-i, --identity PATH` | SSH private key to use for `--push-to` |
| `--remote-dir PATH` | Remote directory to push into (default `/root/xui-mover-incoming`) |
| `--i-know-this-is-multi-node` | Required to proceed if this panel has registered nodes (only master-node data is backed up — see Limitations) |
| `--yes` | Assume yes on informational prompts. Does **not** bypass the multi-node guard |
| `--dry-run` | Print what would happen; make no changes |
| `--no-color` | Disable colored output |
| `-h, --help` | Show usage |

If `--push-to` is given, key-based SSH auth (agent/identity file) is tried first; if that fails and `sshpass` is installed, you'll be prompted for a password as a fallback. A push is only reported successful once the remote file's SHA256 checksum has been verified to match the local one — not merely on `scp` exiting 0.

### `restore.sh`

| Flag | Description |
|---|---|
| `--archive PATH` | Local path to the backup tarball (prompted interactively if omitted) |
| `--yes` | Non-interactive mode for informational prompts — **requires** `--confirm-restore` too |
| `--confirm-restore` | Explicit non-interactive equivalent of typing `RESTORE` at the safety prompt |
| `--dry-run` | Print what would happen; make no changes |
| `--no-color` | Disable colored output |
| `-h, --help` | Show usage |

`--yes` alone never skips the destructive-action confirmation — it must be paired with `--confirm-restore`, so scripted/CI use can never silently skip the safety gate.

## Exit codes

Every failure exits with a distinct, documented code — never a bare `exit 1` — so you can branch on `$?` in scripted use or quote the number when asking for help.

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected/unhandled error |
| 2 | Not running as root |
| 3 | Unsupported OS (non-systemd or non-Debian/Ubuntu) |
| 4 | x-ui service/binary not found |
| 5 | x-ui environment file not found |
| 6 | Unrecognized `XUI_DB_TYPE` value |
| 7 | `XUI_DB_DSN` missing or unparseable |
| 8 | SQLite database file not found (backup side) |
| 9 | `pg_dump`/`pg_restore`/`psql` not installed |
| 10 | `sqlite3` not installed |
| 11 | Multi-node setup detected, no override flag given |
| 12 | Database dump failed |
| 13 | Archive build (`tar`) failed |
| 14 | Local checksum verification failed |
| 15 | SSH connectivity test failed |
| 16 | Push succeeded per `scp` but remote file is missing or its checksum doesn't match |
| 17 | Archive missing, corrupt, or missing `meta.json` |
| 18 | Archive's backend doesn't match the target's configured backend |
| 19 | Target's configured Postgres role/database is unreachable |
| 20 | Confirmation not received (typed anything other than `RESTORE`) |
| 21 | x-ui didn't stop within the timeout |
| 22 | Database restore failed |
| 23 | Post-restore sanity-check query itself errored |
| 24 | x-ui didn't start within the timeout |
| 25 | Cert restore failed |
| 26 | Invalid flag combination |

## Troubleshooting

- **"pg_dump/pg_restore not found"** — install with `apt-get install -y postgresql-client`, or run `x-ui pgclient <server-major-version>` (3x-ui ships its own installer for this — use it if your source and target run different Postgres major versions, e.g. 14 → 16; that version difference is *not* itself a dump/restore compatibility problem, only the client tooling needs to match or exceed the server).
- **"Cannot connect to this server's configured Postgres role/database"** (restore.sh) — the target's `/etc/default/x-ui` points at a role/db that doesn't exist yet. Run `x-ui` on the target and use its PostgreSQL setup menu option to provision it, then re-run `restore.sh`.
- **SSH push fails with "Authentication failed"** — check your key/agent, or install `sshpass` to enable the interactive password-auth fallback.
- **"x-ui version mismatch" warning** — informational only; this tool assumes the same or a schema-compatible x-ui version on both ends per its non-goals. If in doubt, upgrade both to the same x-ui release before migrating.
- Every run logs to `/var/log/xui-mover-<timestamp>.log` (ANSI codes stripped) — attach this file when asking for help.
- Any failure after `restore.sh` has stopped x-ui automatically prints the last ~20 lines of the x-ui log (`journalctl -u x-ui`) so you don't have to go hunting for it.

## Limitations

- **Single-node only.** If `backup.sh` detects rows in the `nodes` table, it warns loudly and refuses to proceed without `--i-know-this-is-multi-node` — and even then, only master-node data (inbounds/settings/certs) is backed up; per-node API tokens/config are not migrated.
- **Same-or-compatible x-ui schema version assumed.** Migrating across incompatible x-ui schema versions is out of scope.
- **No archive encryption.** The tarball is plaintext and contains credentials + private keys — handle it accordingly (see [What's in the archive](#whats-in-the-archive)).
- **Debian/Ubuntu + systemd only**, matching 3x-ui's own support matrix.
- This is a one-shot migration tool, not a backup/cron solution.

## License

MIT — see [LICENSE](LICENSE). See [CHANGELOG.md](CHANGELOG.md) for release history.
