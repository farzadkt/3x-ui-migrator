# xui-mover — Code Audit

Audit of `backup.sh`, `restore.sh`, and `lib/common.sh` (the reference copy that is
inlined verbatim into the two entry points). Findings apply to **both** entry-point
scripts unless noted, because the shared-helper block is duplicated by hand.

Line references use the entry-point scripts (`backup.sh` / `restore.sh`); the same
code exists in `lib/common.sh` at the corresponding function.

Severity legend: **[HIGH]** can cause data loss, a broken migration, or a false
"success"; **[MED]** wrong behavior / degraded reliability in realistic cases;
**[LOW]** edge cases, hygiene, cosmetics.

> Remediation status (Unreleased): the original HIGH items in the summary table
> below are closed except remaining product-scope limits (unencrypted archives,
> Debian/Ubuntu-only, no multi-node *migration*). Closed in this pass: §1.1/§1.2
> (already), §1.3/§1.4 `url_decode`, §1.5 users comparison, §1.7 missing flag
> values, §1.8 JSON escape, §2.1 interrupt restart, §2.2 pre-restore snapshot +
> `--single-transaction`, §2.3 multi-node fail-closed, §2.4/§4.5 log flush +
> mode 600, §2.5 `--service-timeout`, §2.6 free-space check, §4.2 openssl key
> detect, §4.3 remote-dir quoting, §9.1 extra cert trees, §9.2 cert replace,
> §10.1 WAL/SHM (already), §11.2 DSN parser, §11.5 backup `pg_test_connection`,
> §13 local checksum (already). Still open by design or residual: §4.1
> unencrypted archive, §4.4 TOFU SSH, §4.6 PGPASSWORD in environ, §5
> portability (Debian/Ubuntu is the support matrix), §11.3 pg_dump version
> coupling, multi-node *migration* (guard only).

---

## 1. Bugs

### 1.1 [HIGH] `die()` invoked inside `$( … )` loses both its exit code and its message
This is the single most consequential defect and it is systemic.

The scripts run under `set -Eeuo pipefail` with an `ERR` trap:
```
trap 'die "$EXIT_GENERIC" "Unexpected error on line $LINENO ..."' ERR   # backup.sh:493, restore.sh:393
```
Many failure paths reach `die` from **inside a command substitution**, e.g.:
```
env_file=$(resolve_xui_env_file)     # backup.sh:576, restore.sh:464
BACKEND=$(detect_backend "$env_file")# backup.sh:578, restore.sh:465
meta_json=$(extract_archive ...)     # restore.sh:496
```
When the inner function calls `die`, it runs `exit <specific code>`, but that only
terminates the **subshell** created by `$( … )`. The parent then sees the assignment
fail, `set -e` triggers, and the **`ERR` trap fires and calls `die "$EXIT_GENERIC"`**.

Confirmed empirically (assignment case): a function that prints a message and
`exit 7` inside `x=$(fn)` produces final exit code **1** (via the ERR trap), and the
message printed to stdout is **swallowed** into the captured output — the user never
sees it; they see the generic "Unexpected error on line NNN" instead.

Consequences:
- The carefully designed distinct exit codes are **unreachable** for these paths.
  A missing env file exits `1`, not `5` (`EXIT_ENV_FILE_MISSING`); an unrecognized
  `XUI_DB_TYPE` exits `1`, not `6`; a corrupt archive exits `1`, not `17`. This
  directly contradicts the README exit-code table and the project's stated
  "one distinct code per failure class" guarantee.
- The helpful, specific error message (and its `hint`) is captured into the variable
  and discarded; the user only sees the generic trap message.

Affected call sites (non-exhaustive): `resolve_xui_env_file`, `detect_backend`,
`resolve_xui_bin` (via `$(...)` in `main`), `extract_archive`, plus every
`read … <<<"$(pg_sanity_counts)"` / `sqlite_sanity_counts` site (see 1.2).

### 1.2 [HIGH] Sanity-check failures are silently swallowed → false "success"
```
read -r inbounds_count users_count settings_count <<<"$(pg_sanity_counts)"   # backup.sh:607, restore.sh:585
read -r inbounds_count users_count settings_count <<<"$(sqlite_sanity_counts …)" # backup.sh:618, restore.sh:587
```
`pg_sanity_counts` / `sqlite_sanity_counts` are documented to `die` (exit
`EXIT_SANITY_CHECK_FAILED=23`) if a count query errors. But they are always called
inside `<<<"$( … )"`. A command substitution that fails inside a herestring does not
abort the parent (the exit status observed by `set -e` is `read`'s, which is 0), so:
- On a real query error, `die` exits only the subshell; its error text goes to the
  captured stdout and is consumed by `read`; the script **continues**.
- The count variables end up empty. In `restore.sh` the later comparison
  `[[ -n "$SOURCE_INBOUNDS" && "$inbounds_count" != "$SOURCE_INBOUNDS" ]]` then fires
  a mild "differs — verify manually" **warning**, and the script exits **0**.

Net effect: a restore whose post-restore verification query fails is reported as a
successful restore. The `EXIT_SANITY_CHECK_FAILED` code is effectively dead for these
paths.

### 1.3 [MED] `url_decode` wrongly converts `+` to space in the Postgres password
```
url_decode() { local data="${1//+/ }"; printf '%b' "${data//%/\\x}"; }   # backup.sh:231, restore.sh:222
```
`+`-means-space is a rule for the **query string** of a URL, not for the userinfo
(user:password) component. `parse_pg_dsn` runs the password through `url_decode`,
so a DSN password containing a literal `+` (common in randomly generated passwords)
is corrupted into a space, and every `psql`/`pg_dump`/`pg_restore` connection fails
with an authentication error — on both backup and restore.

### 1.4 [MED] `printf '%b'` in `url_decode` can misinterpret backslashes / partial escapes
`printf '%b' "${data//%/\\x}"` turns each `%` into `\x`, relying on the following two
chars being hex. A password containing a literal backslash (decoded from `%5C`), or a
stray `%` not followed by two hex digits, yields undefined/garbled output. `%b` also
interprets any other backslash escape sequences present in the data. This is a
fragile hand-rolled decoder for a security-sensitive value.

### 1.5 [MED] `read_meta_json_number "users"` value is captured but never compared
`restore.sh` reads `SOURCE_USERS` (restore.sh:502) and the CHANGELOG/box advertise a
users sanity check, but the post-restore comparison only warns on `inbounds` and
`settings` mismatches (restore.sh:589–594). A user-count discrepancy after restore is
silently ignored.

### 1.6 [LOW] `--yes` is a no-op in `backup.sh`
`backup.sh` sets `ASSUME_YES=1` but the only consumer, `confirm_yes_no`, is never
called anywhere in `backup.sh`. The flag is documented ("Assume yes on informational
prompts") but has no effect. `confirm_yes_no` is dead code in the backup path.

### 1.7 [LOW] Malformed trailing flags can abort with the wrong (generic) code
```
--push-to) PUSH_TO="${2:-}"; shift 2 ;;   # backup.sh:531
```
If `--push-to` (or `-i`, `--remote-dir`, `--archive`) is the last argument with no
value, `shift 2` runs with only one positional parameter left. Under `set -e` a
failing `shift` triggers the `ERR` trap → exit `1` instead of a clean
`EXIT_BAD_ARGS=26`.

### 1.8 [LOW] `meta.json` is written without JSON-escaping interpolated values
```
write_meta_json … "$(hostname)" "$BACKEND" "$xui_version" …   # backup.sh:635 / 394
```
`hostname` and the `x-ui -v` version string are injected raw between quotes. A value
containing `"`, `\`, or a newline produces invalid JSON. The reader uses `grep`, not a
parser, so it is somewhat tolerant, but a malformed value can silently break field
extraction on restore.

---

## 2. Reliability issues

### 2.1 [HIGH] Interruption during backup leaves x-ui **stopped** on the source (production) server
For the SQLite backend, `backup.sh` stops x-ui to take a consistent snapshot
(backup.sh:612) and restarts it afterward (backup.sh:615). The interrupt traps only
exit:
```
trap 'exit 130' INT ; trap 'exit 143' TERM   # backup.sh:571-572
```
There is no handler that restarts x-ui. A Ctrl-C (or SIGTERM) between stop and restart
leaves the **production** panel down, with no automatic recovery. `cleanup` only
removes the workdir.

### 2.2 [HIGH] Restore is destructive with no pre-restore safety copy and no transaction
`restore.sh` overwrites the live database with no rollback path:
- Postgres: `pg_restore --no-owner --role=… -c --if-exists` (restore.sh:258) runs
  **without** `--single-transaction`. A mid-restore failure leaves the database
  partially dropped/restored and unusable, and nothing was snapshotted first.
- SQLite: `cp -f … "$SQLITE_PATH"` (restore.sh:549) overwrites the existing DB
  in place; the previous file is gone.

The tool warns "This cannot be undone," but taking a timestamped copy of the target DB
before clobbering it would be cheap insurance and is absent.

### 2.3 [MED] Multi-node guard fails **open**
```
count_nodes_rows() { … psql … 'SELECT count(*) FROM nodes;' 2>/dev/null) || n="0" … }  # backup.sh:353
```
Any error from the `nodes` query — connectivity, auth, permissions, not just a
legitimately-absent table — is coerced to `0` and treated as "single node." For the
Postgres backend, `backup.sh` never runs `pg_test_connection` before this, so a bad
DSN silently yields "0 nodes" and the guard is bypassed; the backup proceeds and may
be incomplete for what is actually a multi-node install. A hard "could not determine
node count" failure would be safer than assuming zero.

### 2.4 [MED] Tee'd logging can lose the tail of the log on exit
```
exec > >(tee >(sed -u -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1   # backup.sh:98, restore.sh:96
```
Output is piped to a background process-substitution `tee`/`sed`. The shell does not
wait for that child on exit, so the final lines (often the summary or the failure
reason) may not be flushed to `$LOG_FILE`. Ironic given the log is the artifact users
are told to attach when asking for help.

### 2.5 [MED] `SERVICE_TIMEOUT_SECS=30` start timeout may be too short
`xui_start_and_wait` gives x-ui 30s to reach `active`. On a slow host, or when x-ui
does first-run work against a freshly restored DB, this can spuriously trip
`EXIT_SERVICE_START_FAILED` even though the panel would have come up. There is no way
to override it.

### 2.6 [LOW] No free-space / precondition checks
No check that there is room in `/root` for the dump + archive, or in `$WORKDIR` for
extraction, before starting. A full disk fails mid-dump/mid-extract at an awkward
point.

### 2.7 [LOW] Stale archives and logs accumulate in `/root` and `/var/log`
The final archive lives in `WORK_ROOT=/root/xui-mover` and survives cleanup (by
design), and each run writes a new `/var/log/xui-mover-*.log`. Nothing prunes old
credential-bearing archives or logs across runs.

---

## 3. Bash issues

### 3.1 [HIGH] `set -e` + `ERR` trap + `die`-in-subshell interaction — see 1.1 / 1.2.
The combination of `set -Eeuo pipefail`, an `ERR` trap that calls `die`, and helpers
that `die` from within `$( … )`/`<<<"$( … )"` is the root cause of the exit-code
collapse and the swallowed sanity failures. This is a design-level bash issue, not a
one-off typo.

### 3.2 [MED] `[[ "$n" -gt 0 ]]` on possibly non-numeric input
```
if [[ "$n" -gt 0 ]]; then   # check_multi_node_guard, backup.sh:368
```
`n` comes from a psql/sqlite query with whitespace stripped and defaulted to `0`. If a
non-numeric string ever survives (e.g. a psql notice/warning captured in the value),
the arithmetic `-gt` throws "integer expression expected," trips the `ERR` trap, and
exits `1`.

### 3.3 [LOW] `local -n` nameref requires bash ≥ 4.3
`ssh_opts` uses `local -n _out="$3"` (backup.sh:410). Fine on supported Debian/Ubuntu
(bash 5), but it makes the scripts hard-fail on older/other bashes with a confusing
error. Along with `${var,,}`, `[[ =~ ]]`, `<<<`, and process substitution, these are
firmly bash-only (not POSIX `sh`).

### 3.4 [LOW] Word-splitting reliance in `print_box`
`printf -- '-%.0s' $(seq 1 $((max + 2)))` (backup.sh:114) deliberately relies on
unquoted word-splitting of `seq`. It works, but it is exactly the pattern ShellCheck
flags (SC2046) and is brittle if `IFS` is ever non-default.

---

## 4. Security issues

### 4.1 [MED] Unencrypted archive contains DB credentials and TLS private keys
By design the tarball bundles `db/` (which for Postgres does not contain the password,
but the reference env file does), `cert/` (TLS **private keys**), and
`etc-default-x-ui.reference` (the full `XUI_DB_DSN` **including the plaintext
password**). This is documented as a known limitation, but it remains a real exposure:
the secret-bearing archive sits in `/root/xui-mover` and is transferred over the
network. (Documented; listed here for completeness.)

### 4.2 [MED] Private-key permission hardening is filename-heuristic and can miss keys
```
find "$XUI_CERT_DIR" -type f -iname '*key*' -exec chmod 600 … ;   # restore.sh:569
find … \( -iname '*.pem' -o -iname '*.crt' \) ! -iname '*key*' -exec chmod 644 … ;  # restore.sh:570
```
A private key whose filename does not contain "key" (e.g. `private.pem`, or a `.pem`
that is actually a key) will be caught by the second rule and set to **world-readable
644**. Conversely a non-key file with "key" in the name is forced to 600. Detecting key
material by filename is unreliable for a security-sensitive step.

### 4.3 [MED] Remote command construction is injectable via `--remote-dir`
```
ssh … "mkdir -p '$remote_dir'"                          # backup.sh:450/452
ssh … "sha256sum '${remote_dir}/$(basename "$local_tar")'"  # backup.sh:469/471
```
`$remote_dir` (user-supplied via `--remote-dir`) is interpolated into a single-quoted
remote shell string. A value containing a single quote breaks out and injects into the
remote shell. It targets the user's own server so impact is limited, but it is an
unsafe construction pattern and can also just silently break on paths with quotes.

### 4.4 [LOW] `StrictHostKeyChecking=accept-new` — trust on first use
```
_out=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)   # backup.sh:411
```
The push accepts any new host key automatically. A first-connection MITM would receive
the credential-bearing archive. Reasonable convenience trade-off for the audience, but
worth flagging: there is no host-key pinning/verification.

### 4.5 [LOW] Log file lands in world-readable `/var/log` while archives are kept 700
The project deliberately keeps working files under `/root` (mode 700) "because /tmp is
world-readable," yet `setup_logging` writes to `/var/log/xui-mover-*.log` with the
default umask (typically 644, world-readable). DSNs are masked in the log, but this is
an inconsistency in the stated threat model.

### 4.6 [LOW] `PGPASSWORD` / `SSHPASS` in process environment
Passwords are passed via `PGPASSWORD=…` and `SSHPASS=…` env vars. Readable via
`/proc/<pid>/environ` — only by root here (acceptable), but the plaintext SSH password
is also held in the `SSH_PASSWORD` global for the duration of the run.

### 4.7 [LOW] `tar xzf` extracts an arbitrary user-supplied archive as root
`restore.sh` extracts `--archive` (any path the user points at) into `$WORKDIR` as
root with no member-path vetting (restore.sh:359). GNU tar strips leading `/` and
rejects `..` by default, so risk is low, but there is no explicit confinement/allowlist
of expected members before extraction.

---

## 5. Portability issues

The scripts are documented as Debian/Ubuntu-only, but the specific non-portable
dependencies are worth cataloguing:

### 5.1 [MED] GNU-only utilities and flags
- `tar --transform` (backup.sh:382) — GNU tar only; BSD/macOS/busybox tar lack it →
  archive build fails.
- `sed -u` (backup.sh:98) — `-u` is a GNU extension.
- `stat -c '%a'` / `stat -c '%U:%G'` (restore.sh:546-547) — GNU stat syntax
  (BSD uses `-f`). On failure the code falls back to `root:root`/`644`, silently
  changing ownership semantics.
- `sha256sum`, `du -h`, `seq`, `hostname` — coreutils/util-linux assumptions.

### 5.2 [MED] systemd + Debian assumptions baked in
- OS gate accepts only `ubuntu`/`debian` via `ID`/`ID_LIKE` (backup.sh:172).
- `systemctl show -p ExecStart/EnvironmentFiles` output format parsing
  (resolve_xui_bin/resolve_xui_env_file) is systemd-version-dependent; the `path=…`
  grep (backup.sh:199) assumes a specific ExecStart rendering and breaks if the path
  contains spaces or the format changes.
- `journalctl` assumed as the primary log source (tail_xui_log).

### 5.3 [LOW] UTF-8 box drawing width mismatch
`print_box` measures width with `${#line}` (character count under a UTF-8 locale) but
pads with `printf %-*s` (byte width). Multi-byte content — e.g. anything routed
through the Persian-facing UX — produces misaligned borders. Cosmetic.

---

## 6. Hardcoded paths

All are `readonly` constants near the top of each script:

| Constant | Value | Risk |
|---|---|---|
| `XUI_CERT_DIR` | `/root/cert` | **Only** this dir is backed up/restored. See §9. Not resolved from config. |
| `WORK_ROOT` | `/root/xui-mover` | Working + final-archive location. |
| `REMOTE_INCOMING_DIR_DEFAULT` | `/root/xui-mover-incoming` | Default push target. |
| `XUI_MAIN_FOLDER_DEFAULT` | `/usr/local/x-ui` | Fallback binary dir (resolve_xui_bin falls back here). |
| `XUI_SQLITE_FOLDER_DEFAULT` | `/etc/x-ui` | Fallback SQLite dir (used if `XUI_DB_FOLDER` unset). |
| `XUI_SQLITE_FILENAME` | `x-ui.db` | DB filename assumed fixed. |
| `XUI_ENV_FILE_CANDIDATES` | `/etc/default/x-ui`, `/etc/conf.d/x-ui`, `/etc/sysconfig/x-ui` | Env-file search list. |
| Log dir | `/var/log` (hardcoded in `setup_logging`) | Falls back to `WORK_ROOT` if unwritable. |
| x-ui log fallback | `/var/log/x-ui/*.log` | Only if journalctl absent. |

Most database/binary paths *are* resolved dynamically with these as fallbacks, which is
good. The notable exception is **`XUI_CERT_DIR=/root/cert`**, which is used verbatim and
is never derived from x-ui's actual configured cert location (see §9.1).

---

## 7. Hardcoded service names

- `XUI_SERVICE="x-ui"` (backup.sh:32) is used for every `systemctl` operation, the
  `systemctl list-unit-files … ^x-ui\.service` check, and `journalctl -u x-ui`.
  A panel whose unit is named differently (fork, renamed unit, or a `.service`
  templated name) will be reported as "x-ui not installed" (`EXIT_XUI_NOT_INSTALLED`).
  There is no override flag for the service name.
- The unit-file match `grep -q "^${XUI_SERVICE}\.service"` (backup.sh:209) assumes the
  unit name starts the line in `list-unit-files` output; masked/aliased/indirect units
  may not match.

---

## 8. Migration failure scenarios

Concrete ways a migration can go wrong, drawing on the above:

1. **False "success" restore (§1.2)** — post-restore count query errors (e.g. schema
   differs), but restore exits `0` with only a soft warning. The operator believes the
   migration succeeded.
2. **Wrong/opaque exit code on common failures (§1.1)** — missing env file, unknown
   `XUI_DB_TYPE`, or corrupt archive all surface as generic "Unexpected error … exit 1"
   with the real message swallowed, defeating the documented exit-code contract and
   making support harder.
3. **Postgres password containing `+` (§1.3)** — DSN parse silently corrupts the
   password → connection fails on both ends; the error points at "connectivity/
   credentials" rather than the real cause.
4. **DSN without an explicit port or password (§10.4)** — regex requires
   `user:pass@host:port`; valid DSNs like `postgres://user@host/db` or
   `postgres://user:pass@host/db` fail to parse.
5. **Multi-node install misdetected as single-node (§2.3)** — nodes query errors →
   guard bypassed → incomplete backup produced silently.
6. **Source panel left down (§2.1)** — Ctrl-C during the SQLite snapshot window.
7. **acme.sh / Let's Encrypt certs not migrated (§9.1)** — panel restores but TLS is
   broken because the referenced cert files live outside `/root/cert`.
8. **Stale SQLite WAL/SHM on target (§9.2)** — restored `x-ui.db` is silently reverted
   or corrupted by a leftover write-ahead log.
9. **Partial Postgres restore (§2.2)** — non-transactional `pg_restore` fails midway,
   leaving a half-dropped database and no snapshot to recover from.
10. **x-ui already bootstrapped a newer schema on target** — `-c --if-exists` drops and
    recreates the source schema, but orphaned newer objects/columns may remain; only a
    same-version migration is truly safe (documented as out of scope, but the tool does
    not detect or block it — it only warns).

---

## 9. Certificate migration issues

### 9.1 [HIGH] Only `/root/cert` is captured — acme.sh / Let's Encrypt / custom paths are missed
`XUI_CERT_DIR=/root/cert` is the sole cert source (backup.sh:624) and destination
(restore.sh:565). 3x-ui panels very commonly obtain TLS certs via:
- **acme.sh**, whose material and account config live in `/root/.acme.sh/` and whose
  issued certs may be installed to arbitrary paths;
- **Let's Encrypt / certbot** under `/etc/letsencrypt/`;
- operator-chosen `webCertFile`/`webKeyFile` paths stored inside the panel settings.

None of these are backed up. After restore, the DB's inbound TLS settings and the
panel's own web-TLS settings still reference absolute paths that don't exist on the
target → broken TLS with no error from this tool. Cert **auto-renewal** (acme.sh cron)
is also not migrated.

### 9.2 [MED] Cert restore merges rather than replaces; stale target certs persist
```
cp -a "$BUNDLE_DIR/cert/." "$XUI_CERT_DIR/"   # restore.sh:566
```
Copies bundle certs *into* the existing `/root/cert`, leaving any pre-existing files on
the target in place. A stale cert/key from the target's prior life can linger alongside
the restored set.

### 9.3 [MED] Permission heuristic can expose a private key — see §4.2.

### 9.4 [LOW] Empty-cert case
If the source had no `/root/cert`, backup creates an empty `cert/` dir (backup.sh:628);
restore then warns "Archive contains no certs — skipping." Correct, but a panel that
kept certs elsewhere will hit this path and the operator may wrongly conclude there was
nothing to migrate.

---

## 10. SQLite compatibility

### 10.1 [HIGH] WAL/SHM sidecar files are ignored on both backup and restore
x-ui uses SQLite; SQLite in WAL mode keeps `x-ui.db-wal` and `x-ui.db-shm` next to the
main file.
- **Backup** copies only `x-ui.db` (backup.sh:613). It relies on `systemctl stop`
  cleanly checkpointing the WAL. If x-ui did not shut down cleanly (crash, kill, or a
  checkpoint that didn't run), committed data still in `-wal` is **not** captured.
- **Restore** overwrites `x-ui.db` (restore.sh:549) but does **not** remove any
  existing `x-ui.db-wal` / `x-ui.db-shm` on the target. On next open, SQLite replays
  the stale WAL over the freshly restored file, silently corrupting or reverting it.

Neither side accounts for WAL. This is the most likely silent-data-loss path for the
SQLite backend.

### 10.2 [LOW] Integrity check is good but not paired with a `PRAGMA schema_version`/app check
`sqlite_integrity_check` verifies structural integrity (restore.sh:294) — good. But
"integrity ok" does not imply "schema matches this x-ui version"; a cross-version file
can pass integrity_check and still be wrong for the running binary.

### 10.3 [LOW] `sqlite3` CLI version assumptions
The restore uses the target's `sqlite3` to run `PRAGMA integrity_check`; a very old
`sqlite3` reading a DB written with newer features could misreport. Low risk on
current Debian/Ubuntu.

---

## 11. PostgreSQL compatibility

### 11.1 [MED] No `--single-transaction` on restore — see §2.2. Partial restores possible.

### 11.2 [MED] DSN parser is stricter than real-world DSNs
```
^postgres(ql)?://([^:@/]+):([^@]*)@([^:/]+):([0-9]+)/([^?]+)(\?(.*))?$   # backup.sh:238
```
- Requires an explicit `:port` — DSNs relying on the default 5432 (`…@host/db`) fail.
- Requires `user:password` — passwordless/peer DSNs (`…//user@host…`) fail.
- Password cannot contain `@` (must be percent-encoded); combined with the `+` bug
  (§1.3) and `%b` fragility (§1.4), the credential-parsing path is brittle.
- Host cannot contain `:` — an IPv6 literal host (`[::1]`) won't parse.

### 11.3 [MED] `pg_dump -Fc` version coupling
The custom format dump must be restored by a `pg_restore` whose version is ≥ the
`pg_dump` that produced it. The README addresses the client tooling via `x-ui pgclient`
but the scripts themselves neither record nor check the `pg_dump`/server major version
in `meta.json`, so an older target `pg_restore` fails only at restore time.

### 11.4 [LOW] Restore assumes exact table set (`inbounds`, `users`, `settings`, `nodes`)
Sanity and node-count queries hardcode these table names. A schema variant lacking any
of them turns a successful data restore into a sanity/guard error (or, given §1.2, a
swallowed one).

### 11.5 [LOW] `backup.sh` never tests the Postgres connection before dumping
Unlike `restore.sh` (which calls `pg_test_connection`), `backup.sh` goes straight from
DSN parse to the multi-node query and `pg_dump`. A bad DSN first manifests as a
"0 nodes" misdetection (§2.3) and then a dump failure, rather than a clean upfront
connectivity error.

---

## 12. Restore issues

### §12.1 — inbounds pinned to the source server's IP make the restore a silent no-op (HIGH) — FIXED

3x-ui stores a per-inbound `listen` address. When the source panel pinned its
inbounds to that server's own public IP, the literal travels with the database
and is unbindable on the target, so xray-core exits with
`bind: cannot assign requested address` and crash-loops. xray is a child of the
panel process, so `systemctl is-active x-ui` stays `active`, every sanity row
count matches, and restore.sh printed "Restore complete" while **not one
inbound was serving traffic** — the worst class of failure this tool can have,
and invisible without checking `ss`/journalctl by hand.

Reproduced end-to-end on a live 3x-ui 3.6.0 SQLite migration (three enabled
inbounds, all pinned to the source IP; all three dead after a "successful"
restore).

Fixed by `rebind_stale_inbound_listens` (detect + list + ask, with
`--rebind-listen` / `--no-rebind-listen` / `--listen-address`) and
`verify_xray_running` (post-start log check, exits 22 on a crash-looping core).
Note this closes the second **[LOW]** item below only partially: the sanity
check still runs after x-ui starts, but a crash-looping core is now caught.

- **§1.2** — swallowed sanity failure → false success. (HIGH)
- **§2.2** — destructive, non-transactional, no pre-restore snapshot. (HIGH)
- **§10.1** — stale WAL/SHM corrupts the restored SQLite DB. (HIGH)
- **§9.1/§9.2** — cert coverage gaps and merge-not-replace behavior.
- **§1.5** — user-count mismatch never checked.
- **[LOW]** `--confirm-restore` + `--yes` bypasses the typed gate for automation
  (intended), but there is no second factor (e.g. archive hostname/echo) — a wrong
  `--archive` under automation restores the wrong panel with no interactive catch.
- **[LOW]** Restore starts x-ui (step 8) *before* the sanity check (step 9). If the
  sanity check then flags a problem, the panel is already live serving whatever was
  restored.

---

## 13. Backup issues

- **§2.1** — interruption leaves source x-ui stopped (SQLite path). (HIGH)
- **§2.3** — multi-node guard fails open. (MED)
- **§10.1** — WAL not captured. (HIGH for SQLite)
- **§9.1** — cert capture limited to `/root/cert`. (HIGH)
- **[MED] `EXIT_CHECKSUM_MISMATCH=14` is never used.** The README documents exit 14 as
  "Local checksum verification failed," and `checksum_file` computes a sha256 and writes
  a `.sha256` sidecar (backup.sh:387), but the local archive is **never re-read and
  verified** against that checksum. The advertised local integrity check does not exist;
  only the *remote* checksum comparison (push path) is implemented.
- **[LOW] `--yes` has no effect** (§1.6).
- **[LOW]** Postgres row counts are gathered *after* the dump from the live DB, so they
  can drift from the dump's actual contents if data changes in between; they are
  recorded in `meta.json` as if authoritative.

---

## 14. ShellCheck recommendations

The project already allowlists `shellcheck --version` in `.claude/settings.local.json`
but there is no evidence it is run in CI. Recommended:

1. **Run ShellCheck on all three files in CI** and treat findings as gating. Expected
   categories:
   - **SC2046 / SC2086** — intentional unquoted word-splitting in `print_box`
     (`$(seq …)`); annotate with `# shellcheck disable=SC2046` rather than leaving it
     implicit.
   - **SC2155** — mostly already avoided (declare/assign split), but audit any
     remaining `local x=$(...)` to ensure a failing substitution isn't masked.
   - **SC2015** — `A && B || C` patterns (e.g. `xui_is_active && was_active=0`) can be
     misread; verify intent.
   - **SC2181** — not currently an issue (they check commands directly), keep it that
     way.
2. **Add `shellcheck` directives for the deliberately-duplicated helper block** and,
   ideally, a CI check that the inlined block in `backup.sh` and `restore.sh` is
   byte-identical to `lib/common.sh` (the manual-sync design in the header is a standing
   drift risk — a diff check would enforce it).
3. **Flag dead code** ShellCheck won't catch but a review should: `confirm_yes_no` and
   `pg_test_connection` are inlined into `backup.sh` but never called there;
   `SSH_PASSWORD`/`SSH_USE_PASSWORD` and the SSH helpers are inlined into `restore.sh`
   contexts where unused, etc. Trim per-script or accept as shared-block cost.
4. **`SC2164`** — `cd "$(dirname "$path")" && …` in `checksum_file` (backup.sh:390) is
   guarded by `&&`, but consider `cd … || exit` idiom for clarity.
5. Consider `shellcheck -o all` to also surface optional checks (e.g. SC2250 quoting,
   SC2312 masked-return-in-`$(...)`), which is directly relevant to the §1.1/§1.2
   "`die` inside `$( … )`" family — **SC2311/SC2312** ("command substitution masks the
   return value") is exactly the class of bug that caused the exit-code collapse, and
   enabling it would have flagged it.

---

## Summary of highest-impact items

| # | Item | Category | Severity |
|---|---|---|---|
| 1.1 | `die` inside `$( … )` collapses exit codes to 1 and swallows the message | Bug / Bash | HIGH |
| 1.2 | Sanity-check failures swallowed → false "success" restore | Bug / Restore | HIGH |
| 10.1 | SQLite WAL/SHM ignored → silent corruption/reversion | SQLite / Restore | HIGH |
| 9.1 | Only `/root/cert` migrated; acme.sh/LE/custom certs lost | Certs | HIGH |
| 2.1 | Interrupt leaves source x-ui stopped | Reliability / Backup | HIGH |
| 2.2 | Destructive restore, non-transactional, no pre-restore snapshot | Reliability / Restore | HIGH |
| 1.3 | `+` in Postgres password corrupted by `url_decode` | Bug / Postgres | MED |
| 2.3 | Multi-node guard fails open | Reliability / Backup | MED |
| 13 | `EXIT_CHECKSUM_MISMATCH` / local checksum verification never implemented | Backup | MED |

*End of audit. No code was modified.*
