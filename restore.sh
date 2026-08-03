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
#   bash <(curl -fsSL https://raw.githubusercontent.com/alionthecode/xui-mover/main/restore.sh)
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
readonly XUI_SERVICE="x-ui"
readonly XUI_MAIN_FOLDER_DEFAULT="/usr/local/x-ui"
readonly XUI_SQLITE_FOLDER_DEFAULT="/etc/x-ui"
readonly XUI_SQLITE_FILENAME="x-ui.db"
readonly XUI_CERT_DIR="/root/cert"
readonly WORK_ROOT="/root/xui-mover"
readonly SERVICE_TIMEOUT_SECS=30

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

DRY_RUN=0
NO_COLOR_FLAG=0
ASSUME_YES=0
WORKDIR=""
LOG_FILE=""
SERVICE_STOPPED=0
PG_USER=""; PG_PASS=""; PG_HOST=""; PG_PORT=""; PG_DB=""; PG_CONN_NOAUTH=""
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
  exec > >(tee >(sed -u -r 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
  log_info "Logging to $LOG_FILE"
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
  local border; border=$(printf -- '-%.0s' $(seq 1 $((max + 2))))
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
  exit "$code"
}

confirm_typed() {
  local expected="$1" reply
  read -r -p "Type '${expected}' to proceed: " reply || reply=""
  [[ "$reply" == "$expected" ]]
}

make_workdir() {
  mkdir -p -m 700 "$WORK_ROOT"
  WORKDIR="${WORK_ROOT}/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p -m 700 "$WORKDIR"
}

cleanup() {
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
  die "$EXIT_ENV_FILE_MISSING" "Could not find x-ui's environment file." "Expected /etc/default/x-ui — is x-ui installed?"
}

resolve_xui_bin() {
  local -n _out="$1"
  local execstart="" path=""
  execstart=$(systemctl show -p ExecStart "$XUI_SERVICE" 2>/dev/null) || true
  path=$(printf '%s' "$execstart" | grep -oE 'path=[^ ;]+' | head -1 | cut -d= -f2-) || true
  [[ -z "$path" ]] && path="${XUI_MAIN_FOLDER_DEFAULT}/x-ui"
  if [[ -x "$path" ]]; then
    _out="$path"
    return 0
  fi
  die "$EXIT_XUI_NOT_INSTALLED" "x-ui binary not found or not executable at: $path" "This tool does not install x-ui — install it first, then re-run."
}

require_xui_installed() {
  systemctl list-unit-files 2>/dev/null | grep -q "^${XUI_SERVICE}\.service" \
    || die "$EXIT_XUI_NOT_INSTALLED" "x-ui systemd service not found." "This tool does not install x-ui — install it first, then re-run."
  local _bin=""
  resolve_xui_bin _bin
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
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

parse_pg_dsn() {
  local dsn="$1"
  if [[ "$dsn" =~ ^postgres(ql)?://([^:@/]+):([^@]*)@([^:/]+):([0-9]+)/([^?]+)(\?(.*))?$ ]]; then
    PG_USER="${BASH_REMATCH[2]}"
    PG_PASS="$(url_decode "${BASH_REMATCH[3]}")"
    PG_HOST="${BASH_REMATCH[4]}"
    PG_PORT="${BASH_REMATCH[5]}"
    PG_DB="${BASH_REMATCH[6]}"
    local query="${BASH_REMATCH[8]}"
    PG_CONN_NOAUTH="postgres://${PG_HOST}:${PG_PORT}/${PG_DB}${query:+?$query}"
  else
    die "$EXIT_DSN_PARSE_FAILED" "Could not parse XUI_DB_DSN." "Expected format: postgres://user:pass@host:port/dbname?sslmode=disable"
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
  PGPASSWORD="$PG_PASS" pg_restore --no-owner --role="$PG_USER" -c --if-exists \
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

read_meta_json_field() {
  local file="$1" key="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"\$/\\1/"
}

read_meta_json_number() {
  local file="$1" key="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//'
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
  --dry-run               Print what would happen without making changes
  --no-color              Disable colored output
  -h, --help               Show this help and exit

SAFETY: restore.sh replaces all existing panel data on this server. In
interactive mode you must type RESTORE at the confirmation prompt before
anything is touched. --yes alone never bypasses this gate — it must be
paired with --confirm-restore.
EOF
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archive) ARCHIVE_PATH="${2:-}"; shift 2 ;;
      --archive=*) ARCHIVE_PATH="${1#*=}"; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --confirm-restore) CONFIRM_RESTORE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-color) NO_COLOR_FLAG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit "$EXIT_BAD_ARGS" ;;
    esac
  done
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
  require_xui_installed
  make_workdir
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  log_info "Working directory: $WORKDIR"

  step_banner 2 9 "Reading target configuration"
  local env_file=""; resolve_xui_env_file env_file
  detect_backend "$env_file" BACKEND
  local xui_bin="" target_xui_version
  resolve_xui_bin xui_bin
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
  summary_lines+=("" "ALL EXISTING PANEL DATA ON THIS SERVER WILL BE REPLACED." "This cannot be undone.")
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
    run_step "replace $SQLITE_PATH" cp -f "$BUNDLE_DIR/db/x-ui.db" "$SQLITE_PATH"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      chown "${sqlite_existing_owner:-root:root}" "$SQLITE_PATH" 2>/dev/null || true
      chmod "${sqlite_existing_perm:-644}" "$SQLITE_PATH"
      if ! sqlite_integrity_check "$SQLITE_PATH"; then
        die "$EXIT_RESTORE_FAILED" "Restored SQLite database failed PRAGMA integrity_check."
      fi
    fi
  fi
  log_success "Database restored."

  step_banner 7 9 "Restoring certificates"
  if [[ -d "$BUNDLE_DIR/cert" && -n "$(ls -A "$BUNDLE_DIR/cert" 2>/dev/null)" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "[DRY RUN] would: copy certs into $XUI_CERT_DIR"
    else
      mkdir -p "$XUI_CERT_DIR"
      if ! cp -a "$BUNDLE_DIR/cert/." "$XUI_CERT_DIR/"; then
        die "$EXIT_CERT_RESTORE_FAILED" "Failed to copy certs into $XUI_CERT_DIR."
      fi
      find "$XUI_CERT_DIR" -type f -iname '*key*' -exec chmod 600 {} \; 2>/dev/null || true
      find "$XUI_CERT_DIR" -type f \( -iname '*.pem' -o -iname '*.crt' \) ! -iname '*key*' -exec chmod 644 {} \; 2>/dev/null || true
      log_success "Certs restored to $XUI_CERT_DIR."
    fi
  else
    log_warn "Archive contains no certs — skipping cert restore."
  fi

  step_banner 8 9 "Starting x-ui"
  run_step "start x-ui" xui_start_and_wait
  log_success "x-ui started."

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
    if [[ -n "$SOURCE_SETTINGS" && "$settings_count" != "$SOURCE_SETTINGS" ]]; then
      log_warn "Restored settings row count ($settings_count) differs from the source backup's recorded count ($SOURCE_SETTINGS) — panel settings/Xray configuration may not have carried over correctly, verify manually."
    fi
  fi
  print_summary "Restore complete" \
    "Backend: $BACKEND" \
    "Inbounds restored: $inbounds_count   Users restored: $users_count   Settings rows restored: $settings_count" \
    "x-ui service: active" \
    "" \
    "Next: log into your panel and confirm your inbounds/clients are present."
  exit 0
}

main "$@"
