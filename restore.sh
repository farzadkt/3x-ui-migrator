#!/usr/bin/env bash
# restore.sh — run on the NEW/target 3x-ui server.
#
# Restores a panel from a tarball produced by backup.sh: stops x-ui first
# (unconditionally, before touching any database), restores the Postgres
# dump or SQLite file, restores certs, starts x-ui, and prints sanity-check
# row counts. Requires a typed "RESTORE" confirmation before anything
# destructive happens.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/restore.sh)
#   restore.sh --archive /root/xui-mover-incoming/xui-backup-old-20260715T180400Z.tar.gz
#
# Run `restore.sh --help` for the full flag list. Must be run as root on a
# Debian/Ubuntu host with x-ui already installed and its backend already
# configured — this tool does not install x-ui or provision Postgres.
set -Eeuo pipefail

# ============================================================================
# BEGIN shared helpers — kept in sync manually with lib/common.sh.
# Do not fetch lib/common.sh at runtime; this block must be self-contained so
# `bash <(curl -fsSL .../restore.sh)` works with no other files present.
# See lib/common.sh in the repo for the canonical, commented reference copy.
#
# Design note: pg_dump/pg_restore always run as root, over TCP, using the
# credentials parsed out of XUI_DB_DSN (via PGPASSWORD) — never via
# `sudo -u postgres`. x-ui's Postgres role is password/TCP-authenticated,
# not OS-peer-authenticated, so this sidesteps the classic "postgres system
# user can't traverse into /root (mode 700)" failure by construction.
# ============================================================================

readonly XUI_ENV_FILE_CANDIDATES=(/etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui)
readonly XUI_SQLITE_FOLDER_DEFAULT="/etc/x-ui"
readonly XUI_SQLITE_FILENAME="x-ui.db"
readonly XUI_CERT_DIR="/root/cert"
readonly WORK_ROOT="/root/xui-mover"
SERVICE_TIMEOUT_SECS="${XUI_MOVER_SERVICE_TIMEOUT:-30}"

readonly EXIT_GENERIC=1
readonly EXIT_NOT_ROOT=2
readonly EXIT_UNSUPPORTED_OS=3
readonly EXIT_XUI_NOT_INSTALLED=4
readonly EXIT_ENV_FILE_MISSING=5
readonly EXIT_BACKEND_UNKNOWN=6
readonly EXIT_DSN_PARSE_FAILED=7
readonly EXIT_DB_FILE_MISSING=8
readonly EXIT_PG_CLIENT_MISSING=9
readonly EXIT_SQLITE_CLIENT_MISSING=10
readonly EXIT_MULTI_NODE_BLOCKED=11
readonly EXIT_DUMP_FAILED=12
readonly EXIT_ARCHIVE_BUILD_FAILED=13
readonly EXIT_CHECKSUM_MISMATCH=14
readonly EXIT_SSH_FAILED=15
readonly EXIT_PUSH_VERIFY_FAILED=16
readonly EXIT_ARCHIVE_INVALID=17
readonly EXIT_BACKEND_MISMATCH=18
readonly EXIT_PG_TARGET_NOT_PROVISIONED=19
readonly EXIT_USER_ABORTED=20
readonly EXIT_SERVICE_STOP_FAILED=21
readonly EXIT_RESTORE_FAILED=22
readonly EXIT_SANITY_CHECK_FAILED=23
readonly EXIT_SERVICE_START_FAILED=24
readonly EXIT_CERT_RESTORE_FAILED=25
readonly EXIT_BAD_ARGS=26
readonly EXIT_DISK_FULL=27

DRY_RUN=0
NO_COLOR_FLAG=0
ASSUME_YES=0
# auto = ask interactively when stale inbounds are found; yes/no = decided by flag
REBIND_LISTEN="auto"
LISTEN_ADDRESS_OVERRIDE=""
XRAY_UNHEALTHY=0
WORKDIR=""
LOG_FILE=""
SERVICE_STOPPED=0
XUI_SERVICE=""     # discovered at runtime by discover_xui_installation — never hardcoded
PG_USER=""; PG_PASS=""; PG_HOST=""; PG_PORT=""; PG_DB=""; PG_CONN_NOAUTH=""
STDIO_REDIRECTED=0
INTERRUPT_RESTART_XUI=0
PRE_RESTORE_SNAPSHOT=""
C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""

ui_supports_color() {
  [[ -t 1 && "$NO_COLOR_FLAG" -eq 0 && -z "${NO_COLOR:-}" ]]
}

setup_colors() {
  if ui_supports_color; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
  fi
}

setup_logging() {
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  LOG_FILE="/var/log/xui-mover-${ts}.log"
  if ! ( : >>"$LOG_FILE" ) 2>/dev/null; then
    mkdir -p "$WORK_ROOT" 2>/dev/null || true
    LOG_FILE="$WORK_ROOT/xui-mover-${ts}.log"
  fi
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  exec 3>&1 4>&2
  exec > >(tee >(sed -u -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
  STDIO_REDIRECTED=1
  log_info "Logging to $LOG_FILE"
}

flush_logs() {
  if [[ "${STDIO_REDIRECTED:-0}" -eq 1 ]]; then
    exec 1>&3 2>&4
    exec 3>&- 4>&-
    STDIO_REDIRECTED=0
  fi
}


log_info()    { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
log_warn()    { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
log_error()   { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1"; }
log_success() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }

step_banner() {
  printf '\n%s%s[%s/%s] %s%s\n' "$C_BLUE" "$C_BOLD" "$1" "$2" "$3" "$C_RESET"
}

print_box() {
  local line max=0
  for line in "$@"; do (( ${#line} > max )) && max=${#line}; done
  local border
  # shellcheck disable=SC2046
  border=$(printf -- '-%.0s' $(seq 1 $((max + 2))))
  printf '%s+%s+%s\n' "$C_BOLD" "$border" "$C_RESET"
  for line in "$@"; do
    printf '%s|%s %-*s %s|%s\n' "$C_BOLD" "$C_RESET" "$max" "$line" "$C_BOLD" "$C_RESET"
  done
  printf '%s+%s+%s\n' "$C_BOLD" "$border" "$C_RESET"
}

print_summary() {
  local title="$1"; shift
  printf '\n'
  print_box "$title" "" "$@"
}

die() {
  local code="$1" msg="$2" hint="${3:-}"
  {
    log_error "$msg"
    [[ -n "$hint" ]] && printf '%s-> %s%s\n' "$C_YELLOW" "$hint" "$C_RESET"
    if [[ "${SERVICE_STOPPED:-0}" -eq 1 ]]; then
      tail_xui_log 20
    fi
  } >&2
  flush_logs
  exit "$code"
}

confirm_typed() {
  local expected="$1" reply
  read -r -p "Type '${expected}' to proceed: " reply || reply=""
  [[ "$reply" == "$expected" ]]
}

make_workdir() {
  # `mkdir -p -m` only applies the mode to directories it actually creates —
  # a pre-existing WORK_ROOT (e.g. left over from an older version, or
  # created some other way) would silently keep whatever permissions it
  # already had. chmod explicitly so a credential-bearing directory is never
  # left more permissive than 700 regardless of prior state.
  mkdir -p "$WORK_ROOT"
  chmod 700 "$WORK_ROOT"
  WORKDIR="${WORK_ROOT}/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR"
}

cleanup() {
  flush_logs
  if [[ -n "${WORKDIR:-}" && "$WORKDIR" == "$WORK_ROOT"/run-* && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR" || true
  fi
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "$EXIT_NOT_ROOT" "This script must be run as root." "Re-run with: sudo bash $0"
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "$EXIT_UNSUPPORTED_OS" "Cannot determine OS (missing /etc/os-release)." "This tool supports Debian/Ubuntu with systemd only."
  local id="" id_like=""
  id=$(. /etc/os-release; echo "$ID") || true
  id_like=$(. /etc/os-release; echo "${ID_LIKE:-}") || true
  case " $id $id_like " in
    *" ubuntu "*|*" debian "*) return 0 ;;
    *) die "$EXIT_UNSUPPORTED_OS" "Unsupported OS: ${id:-unknown}." "This tool supports Debian/Ubuntu with systemd only." ;;
  esac
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "$EXIT_UNSUPPORTED_OS" "systemd (systemctl) not found." "This tool requires a systemd-based host."
}

require_free_space() {
  local dir="$1" min_kb="${2:-262144}"
  mkdir -p "$dir" 2>/dev/null || true
  local avail=""
  avail=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}') || avail=""
  [[ "$avail" =~ ^[0-9]+$ ]] || return 0
  if (( avail < min_kb )); then
    die "$EXIT_DISK_FULL" "Not enough free space in $dir (${avail} KB available, need at least ${min_kb} KB)." "Free some disk space and re-run."
  fi
}

handle_interrupt() {
  local code="$1"
  if [[ "${INTERRUPT_RESTART_XUI:-0}" -eq 1 && -n "${XUI_SERVICE:-}" ]]; then
    log_warn "Interrupted — restarting x-ui so the panel is not left down."
    systemctl start "$XUI_SERVICE" >/dev/null 2>&1 || log_error "Could not restart x-ui after interrupt. Start it manually: systemctl start ${XUI_SERVICE}"
  elif [[ -n "${PRE_RESTORE_SNAPSHOT:-}" ]]; then
    log_warn "Interrupted during restore. Pre-restore snapshot kept at $PRE_RESTORE_SNAPSHOT. x-ui left stopped."
  fi
  flush_logs
  exit "$code"
}

# resolve_xui_env_file OUT_VAR — the env file is genuinely optional: x-ui's
# own systemd unit declares it with `ignore_errors=yes` (verified against a
# real install), because it only ever gets created when Postgres is
# configured through x-ui's own setup menu. A plain SQLite install may never
# have one at all. So its absence is NOT treated as fatal here — OUT_VAR is
# simply left empty, and detect_backend/resolve_sqlite_path (which already
# tolerate a missing/unreadable file, defaulting to SQLite) take it from
# there. Only an actually undetectable backend should ever be fatal, not
# this file's mere absence.
resolve_xui_env_file() {
  local -n _out="$1"
  local f
  for f in "${XUI_ENV_FILE_CANDIDATES[@]}"; do
    if [[ -r "$f" ]]; then _out="$f"; return 0; fi
  done
  local shown=""
  shown=$(systemctl show -p EnvironmentFiles "$XUI_SERVICE" 2>/dev/null | sed -E 's/^EnvironmentFiles=//; s/ \(.*\)$//') || true
  if [[ -n "$shown" && -r "$shown" ]]; then
    _out="$shown"
    return 0
  fi
  _out=""
}

# discover_xui_installation OUT_SERVICE OUT_BIN — finds x-ui's systemd unit
# and executable without assuming any fixed unit name or install path.
# Scans every systemd service unit for one whose name plausibly refers to
# x-ui/3x-ui, then keeps only the candidates whose ExecStart actually
# resolves to an existing, executable binary (filters out unrelated units
# that merely contain "xui" in their name). Dies if no candidate survives;
# auto-selects if exactly one does; prompts interactively to choose if more
# than one does. Writes the chosen unit name (without ".service") and the
# absolute binary path into the two namerefs.
discover_xui_installation() {
  local -n _svc_out="$1" _bin_out="$2"
  local unit_names="" u svc path execstart install_dir version
  local -a cand_svc=() cand_bin=()

  unit_names=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -iE 'x-?ui') || true

  for u in $unit_names; do
    svc="${u%.service}"
    execstart=$(systemctl show -p ExecStart "$svc" 2>/dev/null) || true
    path=$(printf '%s' "$execstart" | grep -oE 'path=[^ ;]+' | head -1 | cut -d= -f2-) || true
    [[ -n "$path" && -x "$path" ]] || continue
    cand_svc+=("$svc")
    cand_bin+=("$path")
  done

  if [[ ${#cand_svc[@]} -eq 0 ]]; then
    die "$EXIT_XUI_NOT_INSTALLED" "No x-ui systemd service with a valid, executable binary was found." "This tool does not install x-ui — install it first, then re-run. Searched every systemd service unit for a name containing 'x-ui'/'xui'."
  fi

  if [[ ${#cand_svc[@]} -eq 1 ]]; then
    _svc_out="${cand_svc[0]}"
    _bin_out="${cand_bin[0]}"
    install_dir="$(dirname "$_bin_out")"
    version="$(get_xui_version "$_bin_out")"
    log_success "Discovered x-ui installation: service '${_svc_out}.service', path $install_dir, binary $_bin_out, version $version"
    return 0
  fi

  print_box "MULTIPLE X-UI-LIKE INSTALLATIONS FOUND" "Select which one this migration should use:"
  local i
  for i in "${!cand_svc[@]}"; do
    version="$(get_xui_version "${cand_bin[$i]}")"
    printf '  %s%d)%s %s.service  —  %s  (version: %s)\n' "$C_BOLD" "$((i + 1))" "$C_RESET" "${cand_svc[$i]}" "${cand_bin[$i]}" "$version"
  done

  if [[ ! -t 0 ]]; then
    die "$EXIT_BAD_ARGS" "Multiple x-ui-like installations found and this session is not interactive." "Re-run interactively (a real terminal, not piped/redirected input) to choose one."
  fi

  local choice=""
  while true; do
    read -r -p "Enter a number (1-${#cand_svc[@]}): " choice || choice=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#cand_svc[@]} )); then
      break
    fi
    log_warn "Invalid selection: '$choice'"
  done
  _svc_out="${cand_svc[$((choice - 1))]}"
  _bin_out="${cand_bin[$((choice - 1))]}"
  log_success "Selected: service '${_svc_out}.service', binary $_bin_out"
}

detect_backend() {
  local env_file="$1"
  local -n _out="$2"
  local val=""
  val=$(grep -E '^XUI_DB_TYPE=' "$env_file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r') || true
  case "${val,,}" in
    ""|sqlite) _out="sqlite" ;;
    postgres|postgresql|pg) _out="postgres" ;;
    *) die "$EXIT_BACKEND_UNKNOWN" "Unrecognized XUI_DB_TYPE value: '$val' in $env_file" ;;
  esac
}

get_xui_version() {
  local bin="$1" v=""
  v=$("$bin" -v 2>/dev/null | head -1) || v=""
  [[ -z "$v" ]] && v="unknown"
  printf '%s' "$v"
}

url_decode() {
  local data="$1" out="" i=0 c hex
  local len=${#data}
  while (( i < len )); do
    c="${data:i:1}"
    if [[ "$c" == "%" ]]; then
      hex="${data:i+1:2}"
      if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
        printf -v c '%b' "\\x${hex}"
        out+="$c"
        i=$((i + 3))
        continue
      fi
    fi
    out+="$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

parse_pg_dsn() {
  local dsn="$1"
  if [[ "$dsn" =~ ^postgres(ql)?://([^:/@]+)(:([^@]*))?@(\[[^]]+\]|[^:/]+)(:([0-9]+))?/([^?]+)(\?(.*))?$ ]]; then
    PG_USER="${BASH_REMATCH[2]}"
    if [[ -n "${BASH_REMATCH[3]}" ]]; then
      PG_PASS="$(url_decode "${BASH_REMATCH[4]}")"
    else
      PG_PASS=""
    fi
    PG_HOST="${BASH_REMATCH[5]}"
    PG_HOST="${PG_HOST#[}"
    PG_HOST="${PG_HOST%]}"
    PG_PORT="${BASH_REMATCH[7]:-5432}"
    PG_DB="${BASH_REMATCH[8]}"
    local query="${BASH_REMATCH[10]}"
    PG_CONN_NOAUTH="postgres://${PG_HOST}:${PG_PORT}/${PG_DB}${query:+?$query}"
  else
    die "$EXIT_DSN_PARSE_FAILED" "Could not parse XUI_DB_DSN." "Expected format: postgres://user[:pass]@host[:port]/dbname[?sslmode=disable] — password and port are optional (port defaults to 5432)."
  fi
}

mask_dsn() {
  printf '%s' "$1" | sed -E 's|(://[^:/@]+:)[^@]+@|\1****@|'
}

pg_client_precheck() {
  command -v pg_dump >/dev/null 2>&1 && command -v pg_restore >/dev/null 2>&1 \
    || die "$EXIT_PG_CLIENT_MISSING" "pg_dump/pg_restore not found." "Install with: apt-get install -y postgresql-client, or run: x-ui pgclient <server-major-version>"
}

pg_test_connection() {
  command -v psql >/dev/null 2>&1 || die "$EXIT_PG_CLIENT_MISSING" "psql not found." "Install with: apt-get install -y postgresql-client"
  PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT 1;' >/dev/null 2>"$WORKDIR/pg_test.stderr"
}

pg_restore_from_file() {
  local dump_file="$1" rc=0
  PGPASSWORD="$PG_PASS" pg_restore --no-owner --role="$PG_USER" -c --if-exists --single-transaction \
    -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" "$dump_file" \
    >"$WORKDIR/pg_restore.out" 2>&1 || rc=$?
  if grep -qE '^pg_restore: error:' "$WORKDIR/pg_restore.out" 2>/dev/null; then
    log_error "pg_restore reported errors:"
    grep -E '^pg_restore: error:' "$WORKDIR/pg_restore.out" | tail -n 20 >&2
    die "$EXIT_RESTORE_FAILED" "Database restore failed." "See the error lines above."
  fi
  if [[ $rc -ne 0 ]]; then
    tail -n 20 "$WORKDIR/pg_restore.out" >&2
    die "$EXIT_RESTORE_FAILED" "pg_restore exited with status $rc."
  fi
}

pg_sanity_counts() {
  local -n _inbounds="$1" _users="$2" _settings="$3"
  local inbounds="" users="" settings=""
  inbounds=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM inbounds;' 2>"$WORKDIR/pg_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'inbounds' failed." "$(cat "$WORKDIR/pg_sanity.stderr" 2>/dev/null)"
  users=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM users;' 2>"$WORKDIR/pg_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'users' failed." "$(cat "$WORKDIR/pg_sanity.stderr" 2>/dev/null)"
  settings=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM settings;' 2>"$WORKDIR/pg_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'settings' failed." "$(cat "$WORKDIR/pg_sanity.stderr" 2>/dev/null)"
  _inbounds="${inbounds//[[:space:]]/}"
  _users="${users//[[:space:]]/}"
  _settings="${settings//[[:space:]]/}"
}

sqlite_client_precheck() {
  command -v sqlite3 >/dev/null 2>&1 || die "$EXIT_SQLITE_CLIENT_MISSING" "sqlite3 not found." "Install with: apt-get install -y sqlite3"
}

resolve_sqlite_path() {
  local env_file="$1" folder=""
  folder=$(grep -E '^XUI_DB_FOLDER=' "$env_file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r') || true
  [[ -z "$folder" ]] && folder="$XUI_SQLITE_FOLDER_DEFAULT"
  printf '%s/%s' "$folder" "$XUI_SQLITE_FILENAME"
}

# sqlite_copy_with_sidecars SRC DEST — copies SRC to DEST, and also copies
# SRC-wal/SRC-shm to DEST-wal/DEST-shm if they exist. In WAL mode, recently
# committed rows can still live only in the -wal file, not yet checkpointed
# into the main .db file; copying just the .db (the old behavior) risked a
# snapshot that silently missed those rows, or — on restore — risked a
# stale target -wal being replayed over a freshly restored .db. Copying all
# three as one matched set (only ever done while x-ui is stopped, so there
# is no concurrent writer) guarantees the fileset is internally consistent.
# See AUDIT.md §10.1.
sqlite_copy_with_sidecars() {
  local src="$1" dest="$2" side
  cp -p "$src" "$dest"
  for side in "-wal" "-shm"; do
    if [[ -f "${src}${side}" ]]; then
      cp -p "${src}${side}" "${dest}${side}"
    fi
  done
}

# sqlite_remove_sidecars PATH — removes PATH-wal/PATH-shm if present. Used
# before placing a freshly restored .db so a stale leftover -wal from the
# target's previous database can never be replayed over it.
sqlite_remove_sidecars() {
  local path="$1" side
  for side in "-wal" "-shm"; do
    rm -f "${path}${side}"
  done
}

sqlite_integrity_check() {
  local path="$1" result=""
  result=$(sqlite3 "$path" 'PRAGMA integrity_check;' 2>"$WORKDIR/sqlite_check.stderr") || result=""
  [[ "$result" == "ok" ]]
}

sqlite_sanity_counts() {
  local path="$1"
  local -n _inbounds="$2" _users="$3" _settings="$4"
  local inbounds="" users="" settings=""
  inbounds=$(sqlite3 "$path" 'SELECT count(*) FROM inbounds;' 2>"$WORKDIR/sqlite_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'inbounds' failed." "$(cat "$WORKDIR/sqlite_sanity.stderr" 2>/dev/null)"
  users=$(sqlite3 "$path" 'SELECT count(*) FROM users;' 2>"$WORKDIR/sqlite_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'users' failed." "$(cat "$WORKDIR/sqlite_sanity.stderr" 2>/dev/null)"
  settings=$(sqlite3 "$path" 'SELECT count(*) FROM settings;' 2>"$WORKDIR/sqlite_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'settings' failed." "$(cat "$WORKDIR/sqlite_sanity.stderr" 2>/dev/null)"
  _inbounds="${inbounds//[[:space:]]/}"
  _users="${users//[[:space:]]/}"
  _settings="${settings//[[:space:]]/}"
}

xui_is_active() {
  systemctl is-active --quiet "$XUI_SERVICE"
}

xui_stop_and_wait() {
  SERVICE_STOPPED=1
  if ! systemctl stop "$XUI_SERVICE"; then
    die "$EXIT_SERVICE_STOP_FAILED" "systemctl stop x-ui failed immediately."
  fi
  local waited=0
  while xui_is_active; do
    sleep 1
    waited=$((waited + 1))
    [[ $waited -ge $SERVICE_TIMEOUT_SECS ]] && die "$EXIT_SERVICE_STOP_FAILED" "x-ui service did not stop within ${SERVICE_TIMEOUT_SECS}s."
  done
}

xui_start_and_wait() {
  if ! systemctl start "$XUI_SERVICE"; then
    die "$EXIT_SERVICE_START_FAILED" "systemctl start x-ui failed immediately."
  fi
  local waited=0
  until xui_is_active; do
    sleep 1
    waited=$((waited + 1))
    [[ $waited -ge $SERVICE_TIMEOUT_SECS ]] && die "$EXIT_SERVICE_START_FAILED" "x-ui service did not become active within ${SERVICE_TIMEOUT_SECS}s."
  done
}

tail_xui_log() {
  local n="${1:-20}"
  printf '\n%s----- last %s lines of x-ui log -----%s\n' "$C_YELLOW" "$n" "$C_RESET"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$XUI_SERVICE" -n "$n" --no-pager 2>/dev/null || true
    return 0
  fi
  local f=""
  f=$(ls -t /var/log/x-ui/*.log 2>/dev/null | head -1) || true
  if [[ -n "$f" ]]; then
    tail -n "$n" "$f" || true
  else
    log_warn "No log source available (journalctl unavailable, no /var/log/x-ui/*.log found)."
  fi
}

extract_archive() {
  local archive="$1" dest_dir="$2"
  local -n _out="$3"
  [[ -f "$archive" ]] || die "$EXIT_ARCHIVE_INVALID" "Archive not found: $archive"
  if ! tar tzf "$archive" >/dev/null 2>"$WORKDIR/tar_test.stderr"; then
    die "$EXIT_ARCHIVE_INVALID" "Archive failed integrity check (corrupt or truncated): $archive" "$(cat "$WORKDIR/tar_test.stderr" 2>/dev/null)"
  fi
  if ! tar xzf "$archive" -C "$dest_dir"; then
    die "$EXIT_ARCHIVE_INVALID" "Failed to extract archive: $archive"
  fi
  local meta=""
  meta=$(find "$dest_dir" -maxdepth 2 -name meta.json | head -1)
  if [[ -z "$meta" ]]; then
    die "$EXIT_ARCHIVE_INVALID" "Archive did not contain the expected meta.json." "This may not be a valid xui-mover backup archive."
  fi
  _out="$meta"
}

# verify_archive_checksum_if_present ARCHIVE — if ARCHIVE.sha256 sits next
# to the archive (always true after --push-to, since push_archive() ships
# both files together; true for a manual scp only if the sidecar was copied
# too), verifies the archive against it and dies with EXIT_CHECKSUM_MISMATCH
# on a mismatch. If the sidecar isn't present, this is a no-op — the
# structural check in extract_archive() still runs regardless.
verify_archive_checksum_if_present() {
  local archive="$1" sidecar="${1}.sha256"
  [[ -f "$sidecar" ]] || { log_info "No .sha256 sidecar found next to the archive — skipping checksum verification."; return 0; }
  if ! (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$sidecar")") >/dev/null 2>"$WORKDIR/checksum_verify.stderr"; then
    die "$EXIT_CHECKSUM_MISMATCH" "Archive checksum verification failed against $(basename "$sidecar")." "The archive does not match its recorded checksum — do not proceed. Re-transfer it from the source."
  fi
  log_success "Archive checksum verified against $(basename "$sidecar")"
}

read_meta_json_field() {
  local file="$1" key="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"\$/\\1/"
}

read_meta_json_number() {
  local file="$1" key="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//'
}

restore_panel_certs() {
  local bundle="$1" path src
  if [[ -d "$bundle/cert" && -n "$(ls -A "$bundle/cert" 2>/dev/null)" ]]; then
    mkdir -p "$XUI_CERT_DIR"
    find "$XUI_CERT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    cp -a "$bundle/cert/." "$XUI_CERT_DIR/" || die "$EXIT_CERT_RESTORE_FAILED" "Failed to copy certs into $XUI_CERT_DIR."
    log_success "Certs restored to $XUI_CERT_DIR (replaced, not merged)."
  else
    log_warn "Archive contains no certs under cert/ — skipping $XUI_CERT_DIR restore."
  fi
  if [[ -d "$bundle/extra-certs/acme.sh" ]]; then
    rm -rf /root/.acme.sh
    cp -a "$bundle/extra-certs/acme.sh" /root/.acme.sh || die "$EXIT_CERT_RESTORE_FAILED" "Failed to restore /root/.acme.sh."
    chmod -R go-rwx /root/.acme.sh 2>/dev/null || true
    log_success "Restored /root/.acme.sh"
  fi
  if [[ -d "$bundle/extra-certs/letsencrypt" ]]; then
    rm -rf /etc/letsencrypt
    cp -a "$bundle/extra-certs/letsencrypt" /etc/letsencrypt || die "$EXIT_CERT_RESTORE_FAILED" "Failed to restore /etc/letsencrypt."
    log_success "Restored /etc/letsencrypt"
  fi
  if [[ -f "$bundle/extra-certs/paths.list" ]]; then
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      src="$bundle/extra-certs/files${path}"
      [[ -e "$src" ]] || continue
      mkdir -p "$(dirname "$path")"
      cp -a "$src" "$path" || die "$EXIT_CERT_RESTORE_FAILED" "Failed to restore cert file $path."
    done < "$bundle/extra-certs/paths.list"
  fi
}

harden_cert_permissions() {
  local dir="$1" f
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' f; do
    if command -v openssl >/dev/null 2>&1 && openssl pkey -in "$f" -noout >/dev/null 2>&1; then
      chmod 600 "$f"
    elif command -v openssl >/dev/null 2>&1 && openssl x509 -in "$f" -noout >/dev/null 2>&1; then
      chmod 644 "$f"
    else
      case "${f##*/}" in
        *key*|*KEY*) chmod 600 "$f" ;;
        *.pem|*.crt|*.cer) chmod 644 "$f" ;;
      esac
    fi
  done < <(find "$dir" -type f -print0 2>/dev/null)
}

take_pre_restore_snapshot() {
  local snap="${WORK_ROOT}/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$snap"
  chmod 700 "$snap"
  if [[ "$BACKEND" == "postgres" ]]; then
    if ! PGPASSWORD="$PG_PASS" pg_dump -Fc -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -f "$snap/x-ui.dump" 2>"$WORKDIR/pre_restore_dump.stderr"; then
      log_warn "Could not take a Postgres pre-restore snapshot (continuing anyway): $(tr '\n' ' ' <"$WORKDIR/pre_restore_dump.stderr" 2>/dev/null)"
      rm -rf "$snap"
      return 0
    fi
  else
    if [[ -f "$SQLITE_PATH" ]]; then
      sqlite_copy_with_sidecars "$SQLITE_PATH" "$snap/x-ui.db"
    fi
  fi
  if [[ -d "$XUI_CERT_DIR" ]]; then
    cp -a "$XUI_CERT_DIR" "$snap/cert" 2>/dev/null || true
  fi
  PRE_RESTORE_SNAPSHOT="$snap"
  log_info "Pre-restore safety snapshot saved at $snap (kept if restore is interrupted or fails)."
}

run_step() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[DRY RUN] would: $desc"
    return 0
  fi
  "$@"
}

# ============================================================================
# END shared helpers

# local_ip_literals — every IP address actually assigned to an interface on
# this host, one per line, plus the wildcard/loopback forms that are always
# bindable. Used to decide whether a restored inbound's `listen` value can
# still be bound here.
local_ip_literals() {
  {
    printf '0.0.0.0\n::\n127.0.0.1\n::1\n'
    if command -v ip >/dev/null 2>&1; then
      ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    elif command -v hostname >/dev/null 2>&1; then
      hostname -I 2>/dev/null | tr ' ' '\n'
    fi
  } | sed '/^$/d'
}

# primary_local_ip — this server's own primary IPv4: the source address the
# kernel would use for outbound traffic, i.e. the address the panel is
# actually reachable on. Uses the routing table rather than picking the first
# entry from `ip addr`, so tunnel/docker/loopback interfaces can't win. Prints
# nothing if it cannot be determined.
primary_local_ip() {
  local addr=""
  if command -v ip >/dev/null 2>&1; then
    addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || addr=""
  fi
  if [[ -z "$addr" ]] && command -v hostname >/dev/null 2>&1; then
    addr=$(hostname -I 2>/dev/null | awk '{print $1}') || addr=""
  fi
  [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || addr=""
  printf '%s' "$addr"
}

# rebind_stale_inbound_listens — 3x-ui stores a per-inbound `listen` address,
# and when the source panel pinned its inbounds to the source server's own
# public IP, that literal travels with the database. On the target that
# address is not assigned to any interface, so xray-core dies with
# "bind: cannot assign requested address" and CRASH-LOOPS: the panel itself
# comes up fine and every sanity count matches, but not one inbound is
# actually listening. That failure is silent from the restore script's point
# of view, which is exactly why it has to be handled here rather than left
# for the user to discover.
#
# The rewrite is the user's call, not the script's: a `listen` that is a
# non-empty IP literal not present on this host CAN be rewritten to THIS
# server's own primary IP, so an inbound that was deliberately pinned on the
# source stays pinned on the target — just to the right address. Values that
# are already bindable here, or already empty, are never touched.
#
# Deciding requires knowing which inbounds are actually affected, so the
# question is asked only after the scan and always lists them by name. In
# interactive mode that's a prompt; --rebind-listen / --no-rebind-listen
# answer it up front, and --listen-address overrides the detected IP (an
# empty value means '' — 3x-ui's default of binding all interfaces, which is
# also the fallback when the primary IP cannot be determined).
rebind_stale_inbound_listens() {
  if [[ "$REBIND_LISTEN" == "no" ]]; then
    log_info "Leaving inbound listen addresses exactly as they were on the source (--no-rebind-listen)."
    return 0
  fi

  local rows=""
  if [[ "$BACKEND" == "postgres" ]]; then
    rows=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tA -F '|' \
      -c "SELECT id, listen, remark FROM inbounds WHERE listen IS NOT NULL AND listen <> '';" 2>/dev/null) || rows=""
  else
    rows=$(sqlite3 -separator '|' "$SQLITE_PATH" \
      "SELECT id, listen, remark FROM inbounds WHERE listen IS NOT NULL AND listen != '';" 2>/dev/null) || rows=""
  fi
  [[ -z "$rows" ]] && return 0

  local new_listen="$LISTEN_ADDRESS_OVERRIDE" described=""
  if [[ -z "$new_listen" ]]; then
    new_listen=$(primary_local_ip)
  fi
  if [[ -n "$new_listen" ]]; then
    described="this server's IP ${new_listen}"
  else
    described="all interfaces (this server's primary IP could not be determined)"
  fi

  local locals=""; locals=$(local_ip_literals)
  local stale_ids=() stale_desc=() id listen remark
  while IFS='|' read -r id listen remark; do
    [[ -z "$id" ]] && continue
    if ! grep -qxF "$listen" <<<"$locals"; then
      stale_ids+=("$id")
      stale_desc+=("Inbound ${id} (${remark:-unnamed}) is pinned to ${listen}")
    fi
  done <<<"$rows"

  if [[ ${#stale_ids[@]} -eq 0 ]]; then
    return 0
  fi

  # Only now is there anything to decide about — show exactly what is
  # affected before asking, so the choice is informed rather than abstract.
  log_warn "${#stale_ids[@]} inbound(s) are pinned to an IP address this server does not have:"
  local d
  for d in "${stale_desc[@]}"; do
    printf '         - %s\n' "$d"
  done
  log_warn "xray-core cannot bind a foreign address: left as-is, it will crash-loop and NONE of your inbounds will serve traffic."
  log_info "Proposed change: rebind them to ${described}."

  if [[ "$REBIND_LISTEN" == "auto" ]]; then
    # This point is reached with x-ui already stopped and the database
    # already replaced, so bailing out here would strand the panel down.
    # Non-interactive runs therefore take the conservative branch — change
    # nothing, say so loudly — rather than either dying or silently deciding
    # on the user's behalf.
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      log_warn "Non-interactive run with no --rebind-listen/--no-rebind-listen: leaving these inbounds unchanged."
      log_warn "Re-run with --rebind-listen to rebind them to ${described}."
      return 0
    fi
    local reply=""
    read -r -p "Rebind these ${#stale_ids[@]} inbound(s)? [y/N]: " reply || reply=""
    if [[ ! "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      log_warn "Leaving inbound listen addresses unchanged, as chosen. Expect xray-core to fail until you fix them in the panel."
      return 0
    fi
  fi

  local id_list; id_list=$(IFS=,; printf '%s' "${stale_ids[*]}")
  if [[ "$BACKEND" == "postgres" ]]; then
    PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -q \
      -c "UPDATE inbounds SET listen = '${new_listen}' WHERE id IN (${id_list});" 2>"$WORKDIR/pg_rebind.stderr" \
      || die "$EXIT_RESTORE_FAILED" "Could not rewrite stale inbound listen addresses." "$(cat "$WORKDIR/pg_rebind.stderr" 2>/dev/null)"
  else
    sqlite3 "$SQLITE_PATH" "UPDATE inbounds SET listen = '${new_listen}' WHERE id IN (${id_list});" 2>"$WORKDIR/sqlite_rebind.stderr" \
      || die "$EXIT_RESTORE_FAILED" "Could not rewrite stale inbound listen addresses." "$(cat "$WORKDIR/sqlite_rebind.stderr" 2>/dev/null)"
  fi
  log_success "Rebound ${#stale_ids[@]} inbound(s) to ${described} (they were pinned to the source server's IP)."
}

# verify_xray_running — the panel process starting is NOT proof the migration
# worked: xray-core is a child of x-ui and restarts on its own, so a config
# it cannot apply shows up as a crash-loop behind a perfectly healthy-looking
# "active" unit. Scan the service log written since x-ui was started for
# xray's own start/failure lines and report what actually happened.
verify_xray_running() {
  local since="$1" logtxt=""
  logtxt=$(journalctl -u "$XUI_SERVICE" --since "$since" --no-pager 2>/dev/null) || return 0
  [[ -z "$logtxt" ]] && return 0
  if grep -q 'Failure in running xray-core' <<<"$logtxt"; then
    log_error "xray-core is failing to start — the panel is up but your inbounds are NOT serving traffic."
    grep -o 'XRAY: Failed to start:.*' <<<"$logtxt" | tail -1 | sed 's/^/         /' || true
    log_error "Check the inbound settings in the panel, then: systemctl restart ${XUI_SERVICE}"
    return 1
  fi
  if grep -q 'XRAY: core: Xray .* started' <<<"$logtxt"; then
    log_success "xray-core started cleanly with the restored configuration."
  fi
  return 0
}
# ============================================================================

trap 'rc=$?; [[ $rc -ge 2 ]] && exit "$rc"; die "$EXIT_GENERIC" "Unexpected error on line $LINENO (command: $BASH_COMMAND)"' ERR

# ---- restore.sh-specific state --------------------------------------------
ARCHIVE_PATH=""
CONFIRM_RESTORE=0
BACKEND=""
SQLITE_PATH=""
BUNDLE_DIR=""
SOURCE_INBOUNDS=""
SOURCE_USERS=""
SOURCE_SETTINGS=""

usage() {
  cat <<'EOF'
Usage: restore.sh [options]

Restore a 3x-ui panel from a tarball produced by backup.sh, onto a target
server that already has x-ui installed with its backend already configured.
This tool does not install x-ui or provision Postgres roles/databases.

Options:
  --archive PATH          Local path to the backup tarball (prompted if omitted)
  --yes                   Non-interactive mode for informational prompts (requires --confirm-restore)
  --confirm-restore       Explicit non-interactive equivalent of typing RESTORE
  --rebind-listen         Rebind, without asking, any inbound pinned to an IP
                          this server does not have (xray-core cannot bind a
                          foreign address and would otherwise crash-loop with
                          every inbound offline).
  --no-rebind-listen      Never rebind; keep each inbound's listen address
                          exactly as it was on the source.
  --listen-address ADDR   Address to rebind to (default: this server's own
                          primary IP, auto-detected). Pass an empty value to
                          bind all interfaces instead.
  --service-timeout SECS  Seconds to wait for x-ui to stop/start (default 30, or XUI_MOVER_SERVICE_TIMEOUT)
  --dry-run               Print what would happen without making changes
  --no-color              Disable colored output
  -h, --help               Show this help and exit

Without --rebind-listen or --no-rebind-listen, restore.sh only asks about
inbounds it finds are actually unbindable here, and lists them first. In
non-interactive mode (--yes) it does not guess: pass one of the two flags.

SAFETY: restore.sh replaces all existing panel data on this server. In
interactive mode you must type RESTORE at the confirmation prompt before
anything is touched. --yes alone never bypasses this gate — it must be
paired with --confirm-restore.
EOF
}

parse_flags() {
  require_flag_arg() {
    local flag="$1"
    if [[ $# -lt 2 || -z "${2:-}" || "${2}" == --* ]]; then
      echo "Missing value for $flag" >&2
      usage
      exit "$EXIT_BAD_ARGS"
    fi
  }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebind-listen) REBIND_LISTEN="yes"; shift ;;
      --no-rebind-listen|--keep-listen-addresses) REBIND_LISTEN="no"; shift ;;
      --listen-address) LISTEN_ADDRESS_OVERRIDE="${2:-}"; shift 2 ;;
      --listen-address=*) LISTEN_ADDRESS_OVERRIDE="${1#*=}"; shift ;;
      --archive) require_flag_arg "$@"; ARCHIVE_PATH="$2"; shift 2 ;;
      --archive=*) ARCHIVE_PATH="${1#*=}"; shift ;;
      --service-timeout) require_flag_arg "$@"; SERVICE_TIMEOUT_SECS="$2"; shift 2 ;;
      --service-timeout=*) SERVICE_TIMEOUT_SECS="${1#*=}"; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --confirm-restore) CONFIRM_RESTORE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-color) NO_COLOR_FLAG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit "$EXIT_BAD_ARGS" ;;
    esac
  done
  if [[ -n "$SERVICE_TIMEOUT_SECS" && ! "$SERVICE_TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
    echo "Invalid --service-timeout value: $SERVICE_TIMEOUT_SECS" >&2
    exit "$EXIT_BAD_ARGS"
  fi
  if [[ "$ASSUME_YES" -eq 1 && "$CONFIRM_RESTORE" -ne 1 ]]; then
    echo "Non-interactive mode requires --confirm-restore as well (never bypass the safety gate implicitly)." >&2
    exit "$EXIT_BAD_ARGS"
  fi
}

main() {
  parse_flags "$@"
  setup_colors
  setup_logging

  step_banner 1 9 "Preflight checks"
  require_root
  require_supported_os
  require_systemd
  local xui_bin=""
  discover_xui_installation XUI_SERVICE xui_bin
  make_workdir
  trap cleanup EXIT
  trap 'handle_interrupt 130' INT
  trap 'handle_interrupt 143' TERM
  require_free_space "$WORK_ROOT" 262144
  log_info "Working directory: $WORKDIR"

  step_banner 2 9 "Reading target configuration"
  local env_file=""; resolve_xui_env_file env_file
  if [[ -n "$env_file" ]]; then
    log_info "Environment file: $env_file"
  else
    log_info "No x-ui environment file found — normal for a SQLite-only install; continuing with backend auto-detection."
  fi
  detect_backend "$env_file" BACKEND
  local target_xui_version
  target_xui_version=$(get_xui_version "$xui_bin")
  log_info "This server's backend: $BACKEND   x-ui version: $target_xui_version"
  if [[ "$BACKEND" == "postgres" ]]; then
    local dsn=""
    dsn=$(grep -E '^XUI_DB_DSN=' "$env_file" | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r') || true
    [[ -z "$dsn" ]] && die "$EXIT_DSN_PARSE_FAILED" "XUI_DB_DSN not set in $env_file."
    parse_pg_dsn "$dsn"
    pg_client_precheck
    log_info "Target Postgres: $(mask_dsn "$dsn")"
    if ! pg_test_connection; then
      die "$EXIT_PG_TARGET_NOT_PROVISIONED" "Cannot connect to this server's configured Postgres role/database." "Run 'x-ui' on this server and use its PostgreSQL setup menu option to provision the role/db, then re-run restore.sh."
    fi
    log_success "Connected to target Postgres database."
  else
    sqlite_client_precheck
    SQLITE_PATH=$(resolve_sqlite_path "$env_file")
    mkdir -p "$(dirname "$SQLITE_PATH")"
    log_info "Target SQLite path: $SQLITE_PATH"
  fi

  step_banner 3 9 "Reading backup archive"
  if [[ -z "$ARCHIVE_PATH" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      die "$EXIT_BAD_ARGS" "No --archive given in non-interactive mode."
    fi
    read -r -p "Path to backup archive (.tar.gz): " ARCHIVE_PATH
  fi
  [[ -f "$ARCHIVE_PATH" ]] || die "$EXIT_ARCHIVE_INVALID" "Archive not found: $ARCHIVE_PATH"
  verify_archive_checksum_if_present "$ARCHIVE_PATH"
  local meta_json=""; extract_archive "$ARCHIVE_PATH" "$WORKDIR" meta_json
  BUNDLE_DIR=$(dirname "$meta_json")
  local archive_backend source_xui_version
  archive_backend=$(read_meta_json_field "$meta_json" "backend")
  source_xui_version=$(read_meta_json_field "$meta_json" "xui_version")
  SOURCE_INBOUNDS=$(read_meta_json_number "$meta_json" "inbounds")
  SOURCE_USERS=$(read_meta_json_number "$meta_json" "users")
  SOURCE_SETTINGS=$(read_meta_json_number "$meta_json" "settings")
  if [[ "$archive_backend" != "$BACKEND" ]]; then
    die "$EXIT_BACKEND_MISMATCH" "Archive backend ($archive_backend) does not match this server's configured backend ($BACKEND)." "Re-run restore.sh on a server configured for $archive_backend, or re-run backup.sh against a $BACKEND source."
  fi
  if [[ -n "$source_xui_version" && "$source_xui_version" != "unknown" && "$source_xui_version" != "$target_xui_version" ]]; then
    log_warn "x-ui version mismatch: archive was created on $source_xui_version, this server runs $target_xui_version. Cross-version schema changes are out of scope for this tool — verify manually if unsure."
  fi
  log_success "Archive OK — backend: $archive_backend, source inbounds: ${SOURCE_INBOUNDS:-?}, source users: ${SOURCE_USERS:-?}, source settings rows: ${SOURCE_SETTINGS:-?}"

  step_banner 4 9 "Confirm restore"
  local summary_lines=("Backend: $BACKEND")
  if [[ "$BACKEND" == "postgres" ]]; then
    summary_lines+=("Target database: $PG_DB   Role: $PG_USER   Host: $PG_HOST:$PG_PORT")
  else
    summary_lines+=("Target file: $SQLITE_PATH")
  fi
  summary_lines+=("" "ALL EXISTING PANEL DATA ON THIS SERVER WILL BE REPLACED." "A timestamped pre-restore snapshot will be kept under $WORK_ROOT.")
  print_box "${summary_lines[@]}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[DRY RUN] would require typed confirmation 'RESTORE' here; skipping since --dry-run makes no changes."
  elif [[ "$ASSUME_YES" -eq 1 && "$CONFIRM_RESTORE" -eq 1 ]]; then
    log_info "Non-interactive mode: --confirm-restore given, proceeding."
  else
    if ! confirm_typed "RESTORE"; then
      die "$EXIT_USER_ABORTED" "Confirmation not received — aborted. No changes were made."
    fi
  fi

  step_banner 5 9 "Stopping x-ui"
  run_step "stop x-ui" xui_stop_and_wait
  log_success "x-ui stopped."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    take_pre_restore_snapshot
  fi

  step_banner 6 9 "Restoring database"
  if [[ "$BACKEND" == "postgres" ]]; then
    run_step "pg_restore from $BUNDLE_DIR/db/x-ui.dump" pg_restore_from_file "$BUNDLE_DIR/db/x-ui.dump"
  else
    # Capture the pre-existing file's owner/mode (set by x-ui's own install)
    # before cp overwrites it, and reapply the same values afterward, rather
    # than guessing a fixed mode — matches whatever this fresh install
    # actually expects. Falls back to root:root/644 only when there was no
    # pre-existing file to inherit from.
    local sqlite_existing_perm="" sqlite_existing_owner=""
    if [[ -f "$SQLITE_PATH" ]]; then
      sqlite_existing_perm=$(stat -c '%a' "$SQLITE_PATH" 2>/dev/null) || sqlite_existing_perm=""
      sqlite_existing_owner=$(stat -c '%U:%G' "$SQLITE_PATH" 2>/dev/null) || sqlite_existing_owner=""
    fi
    # Remove any stale -wal/-shm left by the target's previous database
    # before placing the new one — otherwise SQLite would replay the old
    # WAL over the freshly restored .db on next open (AUDIT.md §10.1).
    run_step "remove stale WAL/SHM at $SQLITE_PATH" sqlite_remove_sidecars "$SQLITE_PATH"
    run_step "replace $SQLITE_PATH (+ WAL/SHM if present)" sqlite_copy_with_sidecars "$BUNDLE_DIR/db/x-ui.db" "$SQLITE_PATH"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      chown "${sqlite_existing_owner:-root:root}" "$SQLITE_PATH" 2>/dev/null || true
      chmod "${sqlite_existing_perm:-644}" "$SQLITE_PATH"
      local sqlite_side
      for sqlite_side in "-wal" "-shm"; do
        if [[ -f "${SQLITE_PATH}${sqlite_side}" ]]; then
          chown "${sqlite_existing_owner:-root:root}" "${SQLITE_PATH}${sqlite_side}" 2>/dev/null || true
          chmod "${sqlite_existing_perm:-644}" "${SQLITE_PATH}${sqlite_side}"
        fi
      done
      if ! sqlite_integrity_check "$SQLITE_PATH"; then
        die "$EXIT_RESTORE_FAILED" "Restored SQLite database failed PRAGMA integrity_check."
      fi
    fi
  fi
  # Must run while x-ui is still stopped and after the database is in place,
  # so xray-core reads the corrected inbounds on its very first start.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[DRY RUN] would: scan for inbounds pinned to an IP this server does not have, and ask whether to rebind them to $(primary_local_ip)"
  else
    rebind_stale_inbound_listens
  fi
  log_success "Database restored."

  step_banner 7 9 "Restoring certificates"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[DRY RUN] would: restore certs, acme.sh, Let's Encrypt, and extra cert paths from the archive"
  else
    restore_panel_certs "$BUNDLE_DIR"
    harden_cert_permissions "$XUI_CERT_DIR"
    harden_cert_permissions /root/.acme.sh
    harden_cert_permissions /etc/letsencrypt
  fi

  step_banner 8 9 "Starting x-ui"
  local xray_watch_since=""
  xray_watch_since=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || xray_watch_since=""
  run_step "start x-ui" xui_start_and_wait
  log_success "x-ui started."
  if [[ "$DRY_RUN" -eq 0 && -n "$xray_watch_since" ]]; then
    # xray-core is started by the panel a moment after the unit goes active.
    sleep 8
    verify_xray_running "$xray_watch_since" || XRAY_UNHEALTHY=1
  fi

  step_banner 9 9 "Sanity check & summary"
  local inbounds_count="?" users_count="?" settings_count="?"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ "$BACKEND" == "postgres" ]]; then
      pg_sanity_counts inbounds_count users_count settings_count
    else
      sqlite_sanity_counts "$SQLITE_PATH" inbounds_count users_count settings_count
    fi
    if [[ -n "$SOURCE_INBOUNDS" && "$inbounds_count" != "$SOURCE_INBOUNDS" ]]; then
      log_warn "Restored inbounds count ($inbounds_count) differs from the source backup's recorded count ($SOURCE_INBOUNDS) — verify manually."
    fi
    if [[ -n "$SOURCE_USERS" && "$users_count" != "$SOURCE_USERS" ]]; then
      log_warn "Restored users count ($users_count) differs from the source backup's recorded count ($SOURCE_USERS) — verify manually."
    fi
    if [[ -n "$SOURCE_SETTINGS" && "$settings_count" != "$SOURCE_SETTINGS" ]]; then
      log_warn "Restored settings row count ($settings_count) differs from the source backup's recorded count ($SOURCE_SETTINGS) — panel settings/Xray configuration may not have carried over correctly, verify manually."
    fi
  fi
  local xray_line="xray-core: running"
  [[ "$XRAY_UNHEALTHY" -eq 1 ]] && xray_line="xray-core: FAILING TO START — inbounds are NOT serving traffic"
  [[ "$DRY_RUN" -eq 1 ]] && xray_line=""
  print_summary "Restore complete" \
    "Backend: $BACKEND" \
    "Inbounds restored: $inbounds_count   Users restored: $users_count   Settings rows restored: $settings_count" \
    "x-ui service: active" \
    "${xray_line}" \
    "${PRE_RESTORE_SNAPSHOT:+Pre-restore snapshot: $PRE_RESTORE_SNAPSHOT}" \
    "" \
    "Next: log into your panel and confirm your inbounds/clients are present."
  [[ "$XRAY_UNHEALTHY" -eq 1 ]] && exit "$EXIT_RESTORE_FAILED"
  exit 0
}

main "$@"
