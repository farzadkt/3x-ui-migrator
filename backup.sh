#!/usr/bin/env bash
# backup.sh — run on the OLD/source 3x-ui server.
#
# Produces a single timestamped tarball containing everything needed to
# restore a 3x-ui panel on another server (Postgres dump or SQLite file,
# /root/cert/, and a reference copy of the environment file), and optionally
# pushes it directly to the target over SSH.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/alionthecode/xui-mover/main/backup.sh)
#   backup.sh --push-to root@1.2.3.4
#
# Run `backup.sh --help` for the full flag list. Must be run as root on a
# Debian/Ubuntu host with x-ui already installed. See restore.sh for the
# other half of the migration.
set -Eeuo pipefail

# ============================================================================
# BEGIN shared helpers — kept in sync manually with lib/common.sh.
# Do not fetch lib/common.sh at runtime; this block must be self-contained so
# `bash <(curl -fsSL .../backup.sh)` works with no other files present.
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
readonly REMOTE_INCOMING_DIR_DEFAULT="/root/xui-mover-incoming"
readonly SERVICE_TIMEOUT_SECS=30
readonly TOOL_VERSION="1.0.0"

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
SSH_USE_PASSWORD=0; SSH_PASSWORD=""
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

confirm_yes_no() {
  local prompt="$1" default="${2:-n}" reply suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  read -r -p "$prompt $suffix " reply || reply=""
  reply="${reply,,}"
  if [[ -z "$reply" ]]; then
    [[ "$default" == "y" ]]
    return
  fi
  [[ "$reply" == "y" || "$reply" == "yes" ]]
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
  local f
  for f in "${XUI_ENV_FILE_CANDIDATES[@]}"; do
    [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  local shown=""
  shown=$(systemctl show -p EnvironmentFiles "$XUI_SERVICE" 2>/dev/null | sed -E 's/^EnvironmentFiles=//; s/ \(.*\)$//') || true
  if [[ -n "$shown" && -r "$shown" ]]; then
    printf '%s' "$shown"
    return 0
  fi
  die "$EXIT_ENV_FILE_MISSING" "Could not find x-ui's environment file." "Expected /etc/default/x-ui — is x-ui installed?"
}

resolve_xui_bin() {
  local execstart="" path=""
  execstart=$(systemctl show -p ExecStart "$XUI_SERVICE" 2>/dev/null) || true
  path=$(printf '%s' "$execstart" | grep -oE 'path=[^ ;]+' | head -1 | cut -d= -f2-) || true
  [[ -z "$path" ]] && path="${XUI_MAIN_FOLDER_DEFAULT}/x-ui"
  if [[ -x "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi
  die "$EXIT_XUI_NOT_INSTALLED" "x-ui binary not found or not executable at: $path" "This tool does not install x-ui — install it first, then re-run."
}

require_xui_installed() {
  systemctl list-unit-files 2>/dev/null | grep -q "^${XUI_SERVICE}\.service" \
    || die "$EXIT_XUI_NOT_INSTALLED" "x-ui systemd service not found." "This tool does not install x-ui — install it first, then re-run."
  resolve_xui_bin >/dev/null
}

detect_backend() {
  local env_file="$1" val=""
  val=$(grep -E '^XUI_DB_TYPE=' "$env_file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r') || true
  case "${val,,}" in
    ""|sqlite) printf 'sqlite' ;;
    postgres|postgresql|pg) printf 'postgres' ;;
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

pg_dump_to_file() {
  local out_file="$1"
  mkdir -p "$(dirname "$out_file")"
  if ! PGPASSWORD="$PG_PASS" pg_dump -Fc -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -f "$out_file" 2>"$WORKDIR/pg_dump.stderr"; then
    log_error "pg_dump failed:"
    tail -n 20 "$WORKDIR/pg_dump.stderr" >&2 2>/dev/null || true
    die "$EXIT_DUMP_FAILED" "Database dump failed." "Check Postgres connectivity/credentials in the environment file."
  fi
}

pg_sanity_counts() {
  local inbounds="" users="" settings=""
  inbounds=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM inbounds;' 2>"$WORKDIR/pg_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'inbounds' failed." "$(cat "$WORKDIR/pg_sanity.stderr" 2>/dev/null)"
  users=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM users;' 2>"$WORKDIR/pg_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'users' failed." "$(cat "$WORKDIR/pg_sanity.stderr" 2>/dev/null)"
  settings=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM settings;' 2>"$WORKDIR/pg_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'settings' failed." "$(cat "$WORKDIR/pg_sanity.stderr" 2>/dev/null)"
  printf '%s %s %s' "${inbounds//[[:space:]]/}" "${users//[[:space:]]/}" "${settings//[[:space:]]/}"
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

sqlite_sanity_counts() {
  local path="$1" inbounds="" users="" settings=""
  inbounds=$(sqlite3 "$path" 'SELECT count(*) FROM inbounds;' 2>"$WORKDIR/sqlite_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'inbounds' failed." "$(cat "$WORKDIR/sqlite_sanity.stderr" 2>/dev/null)"
  users=$(sqlite3 "$path" 'SELECT count(*) FROM users;' 2>"$WORKDIR/sqlite_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'users' failed." "$(cat "$WORKDIR/sqlite_sanity.stderr" 2>/dev/null)"
  settings=$(sqlite3 "$path" 'SELECT count(*) FROM settings;' 2>"$WORKDIR/sqlite_sanity.stderr") \
    || die "$EXIT_SANITY_CHECK_FAILED" "Sanity-check query on 'settings' failed." "$(cat "$WORKDIR/sqlite_sanity.stderr" 2>/dev/null)"
  printf '%s %s %s' "${inbounds//[[:space:]]/}" "${users//[[:space:]]/}" "${settings//[[:space:]]/}"
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

count_nodes_rows() {
  local n=""
  if [[ "$BACKEND" == "postgres" ]]; then
    n=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM nodes;' 2>/dev/null) || n="0"
  else
    n=$(sqlite3 "$SQLITE_PATH" 'SELECT count(*) FROM nodes;' 2>/dev/null) || n="0"
  fi
  n="${n//[[:space:]]/}"
  [[ -z "$n" ]] && n="0"
  printf '%s' "$n"
}

check_multi_node_guard() {
  local allow_flag="$1" n=""
  n=$(count_nodes_rows)
  if [[ "$n" -gt 0 ]]; then
    print_box "MULTI-NODE PANEL DETECTED (${n} node row(s))" \
      "Only master-node data (inbounds/settings/certs) will be backed up." \
      "Per-node API tokens/config are NOT included in this backup." \
      "Multi-node migration is not supported by this tool (v1)."
    if [[ "$allow_flag" -ne 1 ]]; then
      die "$EXIT_MULTI_NODE_BLOCKED" "Multi-node setup detected; aborting to avoid an incomplete backup." "Re-run with --i-know-this-is-multi-node to proceed anyway."
    fi
    log_warn "Proceeding anyway due to --i-know-this-is-multi-node."
  fi
}

build_archive() {
  local out_tar="$1" src_dir="$2" archive_stem="$3"; shift 3
  if ! tar czf "$out_tar" -C "$src_dir" --transform "s,^,${archive_stem}/," "$@"; then
    die "$EXIT_ARCHIVE_BUILD_FAILED" "Failed to build archive $out_tar."
  fi
}

checksum_file() {
  local path="$1" sum=""
  sum=$(sha256sum "$path" | awk '{print $1}')
  (cd "$(dirname "$path")" && sha256sum "$(basename "$path")" > "$(basename "$path").sha256")
  printf '%s' "$sum"
}

write_meta_json() {
  local out_file="$1" hostname_v="$2" backend_v="$3" xui_version_v="$4" inbounds_v="$5" users_v="$6" settings_v="$7" nodes_v="$8"
  cat > "$out_file" <<EOF
{
  "tool_version": "${TOOL_VERSION}",
  "created_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "${hostname_v}",
  "backend": "${backend_v}",
  "xui_version": "${xui_version_v}",
  "source_counts": {"inbounds": ${inbounds_v}, "users": ${users_v}, "settings": ${settings_v}, "nodes": ${nodes_v}}
}
EOF
}

ssh_opts() {
  local identity="$1" port="$2"
  local -n _out="$3"
  _out=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  [[ -n "$identity" ]] && _out+=(-i "$identity")
  [[ -n "$port" ]] && _out+=(-p "$port")
}

ssh_test_connection() {
  local user_host="$1" port="$2" identity="$3"
  local opts=()
  ssh_opts "$identity" "$port" opts
  if ssh "${opts[@]}" "$user_host" true 2>"$WORKDIR/ssh_test.stderr"; then
    SSH_USE_PASSWORD=0
    return 0
  fi
  if command -v sshpass >/dev/null 2>&1; then
    log_warn "Key/agent auth failed for $user_host; falling back to password auth."
    local pass=""
    read -r -s -p "SSH password for $user_host: " pass
    printf '\n'
    if SSHPASS="$pass" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "${opts[@]}" "$user_host" true 2>"$WORKDIR/ssh_test.stderr"; then
      SSH_PASSWORD="$pass"
      SSH_USE_PASSWORD=1
      return 0
    fi
  fi
  local err=""; err=$(cat "$WORKDIR/ssh_test.stderr" 2>/dev/null) || true
  local hint="Check host/port/user and that the target is reachable."
  [[ "$err" == *"Permission denied"* ]] && hint="Authentication failed — check your SSH key/password and that the user has SSH access. Install 'sshpass' to enable the password-auth fallback."
  [[ "$err" == *"Connection timed out"* || "$err" == *"No route to host"* ]] && hint="Host unreachable — check the address/port and firewall rules."
  die "$EXIT_SSH_FAILED" "Could not establish SSH connection to $user_host." "$hint"
}

push_archive() {
  local user_host="$1" port="$2" identity="$3" local_tar="$4" remote_dir="$5"
  local opts=() rc=0
  ssh_opts "$identity" "$port" opts
  local local_sum=""; local_sum=$(sha256sum "$local_tar" | awk '{print $1}')

  rc=0
  if [[ "$SSH_USE_PASSWORD" -eq 1 ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "${opts[@]}" "$user_host" "mkdir -p '$remote_dir'" || rc=$?
  else
    ssh "${opts[@]}" "$user_host" "mkdir -p '$remote_dir'" || rc=$?
  fi
  [[ $rc -ne 0 ]] && die "$EXIT_PUSH_VERIFY_FAILED" "Failed to create remote directory $remote_dir on $user_host."

  local scp_opts=(-q -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  [[ -n "$port" ]] && scp_opts+=(-P "$port")
  [[ -n "$identity" ]] && scp_opts+=(-i "$identity")
  rc=0
  if [[ "$SSH_USE_PASSWORD" -eq 1 ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e scp "${scp_opts[@]}" "$local_tar" "${local_tar}.sha256" "${user_host}:${remote_dir}/" || rc=$?
  else
    scp "${scp_opts[@]}" "$local_tar" "${local_tar}.sha256" "${user_host}:${remote_dir}/" || rc=$?
  fi
  [[ $rc -ne 0 ]] && die "$EXIT_PUSH_VERIFY_FAILED" "File transfer to $user_host failed."

  local remote_sum=""
  if [[ "$SSH_USE_PASSWORD" -eq 1 ]]; then
    remote_sum=$(SSHPASS="$SSH_PASSWORD" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "${opts[@]}" "$user_host" "sha256sum '${remote_dir}/$(basename "$local_tar")'" 2>/dev/null | awk '{print $1}') || remote_sum=""
  else
    remote_sum=$(ssh "${opts[@]}" "$user_host" "sha256sum '${remote_dir}/$(basename "$local_tar")'" 2>/dev/null | awk '{print $1}') || remote_sum=""
  fi

  if [[ -z "$remote_sum" || "$remote_sum" != "$local_sum" ]]; then
    die "$EXIT_PUSH_VERIFY_FAILED" "Remote checksum did not match local checksum after transfer." "Local: $local_sum  Remote: ${remote_sum:-<missing>}"
  fi
  REMOTE_ARCHIVE_PATH="${remote_dir}/$(basename "$local_tar")"
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

# ---- backup.sh-specific state --------------------------------------------
PUSH_TO=""
SSH_IDENTITY=""
REMOTE_DIR="$REMOTE_INCOMING_DIR_DEFAULT"
MULTI_NODE_OVERRIDE=0
SSH_USER_HOST=""
SSH_PORT=""
REMOTE_ARCHIVE_PATH=""
BACKEND=""
SQLITE_PATH=""

usage() {
  cat <<'EOF'
Usage: backup.sh [options]

Back up a 3x-ui panel (Postgres or SQLite backend) into a single tarball,
optionally pushing it directly to a target server over SSH.

Options:
  --push-to USER@HOST[:PORT]     Push the archive to a target server over SSH
  -i, --identity PATH            SSH private key to use for --push-to
  --remote-dir PATH              Remote directory to push into (default: /root/xui-mover-incoming)
  --i-know-this-is-multi-node    Proceed even if this panel has registered nodes (v1 does not migrate node data)
  --yes                          Assume yes on informational prompts (does not bypass the multi-node guard)
  --dry-run                      Print what would happen without making changes
  --no-color                     Disable colored output
  -h, --help                     Show this help and exit

After a local (non --push-to) backup, run restore.sh on the new server,
pointing it at the printed archive path.
EOF
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --push-to) PUSH_TO="${2:-}"; shift 2 ;;
      --push-to=*) PUSH_TO="${1#*=}"; shift ;;
      -i|--identity) SSH_IDENTITY="${2:-}"; shift 2 ;;
      --identity=*) SSH_IDENTITY="${1#*=}"; shift ;;
      --remote-dir) REMOTE_DIR="${2:-}"; shift 2 ;;
      --remote-dir=*) REMOTE_DIR="${1#*=}"; shift ;;
      --i-know-this-is-multi-node) MULTI_NODE_OVERRIDE=1; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-color) NO_COLOR_FLAG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit "$EXIT_BAD_ARGS" ;;
    esac
  done
  if [[ -n "$PUSH_TO" ]]; then
    if [[ "$PUSH_TO" =~ ^([^@]+)@([^:]+):([0-9]+)$ ]]; then
      SSH_USER_HOST="${BASH_REMATCH[1]}@${BASH_REMATCH[2]}"
      SSH_PORT="${BASH_REMATCH[3]}"
    elif [[ "$PUSH_TO" =~ ^([^@]+)@([^:]+)$ ]]; then
      SSH_USER_HOST="$PUSH_TO"
      SSH_PORT=""
    else
      echo "Invalid --push-to value: $PUSH_TO (expected user@host[:port])" >&2
      exit "$EXIT_BAD_ARGS"
    fi
  fi
}

main() {
  parse_flags "$@"
  setup_colors
  setup_logging

  step_banner 1 8 "Preflight checks"
  require_root
  require_supported_os
  require_systemd
  require_xui_installed
  make_workdir
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  log_info "Working directory: $WORKDIR"

  step_banner 2 8 "Detecting backend"
  local env_file; env_file=$(resolve_xui_env_file)
  log_info "Environment file: $env_file"
  BACKEND=$(detect_backend "$env_file")
  local xui_bin xui_version
  xui_bin=$(resolve_xui_bin)
  xui_version=$(get_xui_version "$xui_bin")
  log_info "Backend: $BACKEND   x-ui version: $xui_version"
  if [[ "$BACKEND" == "postgres" ]]; then
    local dsn=""
    dsn=$(grep -E '^XUI_DB_DSN=' "$env_file" | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r') || true
    [[ -z "$dsn" ]] && die "$EXIT_DSN_PARSE_FAILED" "XUI_DB_DSN not set in $env_file."
    parse_pg_dsn "$dsn"
    pg_client_precheck
    log_info "Postgres target: $(mask_dsn "$dsn")"
  else
    sqlite_client_precheck
    SQLITE_PATH=$(resolve_sqlite_path "$env_file")
    [[ -f "$SQLITE_PATH" ]] || die "$EXIT_DB_FILE_MISSING" "SQLite database not found at $SQLITE_PATH."
    log_info "SQLite database: $SQLITE_PATH"
  fi

  step_banner 3 8 "Checking for multi-node configuration"
  check_multi_node_guard "$MULTI_NODE_OVERRIDE"
  local node_count; node_count=$(count_nodes_rows)

  step_banner 4 8 "Dumping database"
  mkdir -p "$WORKDIR/db"
  local inbounds_count=0 users_count=0 settings_count=0
  if [[ "$BACKEND" == "postgres" ]]; then
    run_step "pg_dump -Fc to $WORKDIR/db/x-ui.dump" pg_dump_to_file "$WORKDIR/db/x-ui.dump"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      read -r inbounds_count users_count settings_count <<<"$(pg_sanity_counts)"
    fi
  else
    local was_active=1
    xui_is_active && was_active=0
    run_step "stop x-ui for a consistent snapshot" xui_stop_and_wait
    run_step "copy $SQLITE_PATH" cp -p "$SQLITE_PATH" "$WORKDIR/db/x-ui.db"
    if [[ "$DRY_RUN" -eq 0 && $was_active -eq 0 ]]; then
      run_step "restart x-ui" xui_start_and_wait
    fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
      read -r inbounds_count users_count settings_count <<<"$(sqlite_sanity_counts "$WORKDIR/db/x-ui.db")"
    fi
  fi
  log_success "Dump complete (inbounds: ${inbounds_count:-0}, users: ${users_count:-0}, settings rows: ${settings_count:-0})"

  step_banner 5 8 "Collecting certs and reference config"
  if [[ -d "$XUI_CERT_DIR" ]]; then
    run_step "copy $XUI_CERT_DIR" cp -a "$XUI_CERT_DIR" "$WORKDIR/cert"
  else
    log_warn "$XUI_CERT_DIR not found — skipping (no certs to back up)."
    mkdir -p "$WORKDIR/cert"
  fi
  {
    printf '# REFERENCE ONLY — captured from %s on %s.\n' "$env_file" "$(hostname)"
    printf '# Do NOT apply this file verbatim on the target: XUI_DB_DSN is server-specific.\n#\n'
    cat "$env_file"
  } > "$WORKDIR/etc-default-x-ui.reference"
  write_meta_json "$WORKDIR/meta.json" "$(hostname)" "$BACKEND" "$xui_version" "${inbounds_count:-0}" "${users_count:-0}" "${settings_count:-0}" "${node_count:-0}"
  log_success "Collected certs and metadata."

  step_banner 6 8 "Building archive"
  mkdir -p "$WORK_ROOT"
  local archive_name archive archive_stem checksum=""
  archive_name="xui-backup-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  archive="$WORK_ROOT/$archive_name"
  archive_stem="${archive_name%.tar.gz}"
  run_step "tar czf $archive" build_archive "$archive" "$WORKDIR" "$archive_stem" meta.json db cert etc-default-x-ui.reference
  if [[ "$DRY_RUN" -eq 0 ]]; then
    checksum=$(checksum_file "$archive")
    local size; size=$(du -h "$archive" 2>/dev/null | cut -f1) || size="?"
    log_success "Archive built: $archive ($size)"
  fi

  step_banner 7 8 "Transfer"
  if [[ -n "$PUSH_TO" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "[DRY RUN] would: test SSH connection and push $archive to ${SSH_USER_HOST}:${REMOTE_DIR}"
    else
      log_info "Testing SSH connectivity to $SSH_USER_HOST..."
      SSH_USE_PASSWORD=0; SSH_PASSWORD=""
      ssh_test_connection "$SSH_USER_HOST" "$SSH_PORT" "$SSH_IDENTITY"
      push_archive "$SSH_USER_HOST" "$SSH_PORT" "$SSH_IDENTITY" "$archive" "$REMOTE_DIR"
      log_success "Archive pushed and verified: ${SSH_USER_HOST}:${REMOTE_ARCHIVE_PATH}"
    fi
  else
    log_info "Local archive: $archive"
    printf '\nCopy it to your new server with:\n'
    printf '  scp "%s" root@<new-server>:/root/xui-mover-incoming/\n' "$archive"
  fi

  step_banner 8 8 "Summary"
  local dest_line
  if [[ -n "$PUSH_TO" ]]; then
    dest_line="Pushed to: ${SSH_USER_HOST}:${REMOTE_ARCHIVE_PATH:-$REMOTE_DIR (dry-run)}"
  else
    dest_line="Local path: $archive"
  fi
  print_summary "Backup complete" \
    "Backend: $BACKEND (x-ui $xui_version)" \
    "Inbounds: ${inbounds_count:-0}   Users: ${users_count:-0}   Settings rows: ${settings_count:-0}   Nodes: ${node_count:-0}" \
    "$dest_line" \
    "SHA256: ${checksum:-<dry-run>}" \
    "" \
    "Next: run restore.sh on the new server, pointing it at this archive."
  exit 0
}

main "$@"
