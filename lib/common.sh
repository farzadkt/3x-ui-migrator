#!/usr/bin/env bash
# lib/common.sh — REFERENCE / DEVELOPMENT COPY ONLY.
#
# backup.sh and restore.sh do NOT source this file at runtime. Both must stay
# runnable via `bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/backup.sh)`
# with no other files present, so the functions below are inlined verbatim
# into both entry-point scripts between the "BEGIN/END shared helpers"
# markers. If you change a function here, copy the change into both
# entry-point scripts by hand and note it in CHANGELOG.md.
#
# Design note: pg_dump/pg_restore always run as root, over TCP, using the
# credentials parsed out of XUI_DB_DSN (via PGPASSWORD) — never via
# `sudo -u postgres`. x-ui provisions its Postgres role for password/TCP
# auth, not OS-peer auth, so connecting this way sidesteps the classic
# "the postgres system user can't traverse into /root (mode 700)" failure
# by construction, rather than working around it with directory permissions.
#
# This file is not meant to be executed directly.

# ============================================================================
# Constants
# ============================================================================

# Places x-ui's systemd unit may load its EnvironmentFile from, depending on
# distro. This tool only supports Debian/Ubuntu (first entry) per the PRD's
# non-goals, but resolve_xui_env_file() checks the others too as a defensive
# fallback before giving up.
readonly XUI_ENV_FILE_CANDIDATES=(/etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui)
readonly XUI_SQLITE_FOLDER_DEFAULT="/etc/x-ui"
readonly XUI_SQLITE_FILENAME="x-ui.db"
readonly XUI_CERT_DIR="/root/cert"
# Working directory AND final archive both live under /root (not /tmp):
# everything here runs as root and /tmp is world-readable by default, so
# keeping credential-bearing files under /root reduces exposure.
readonly WORK_ROOT="/root/xui-mover"
readonly REMOTE_INCOMING_DIR_DEFAULT="/root/xui-mover-incoming"
# Overridable via --service-timeout or XUI_MOVER_SERVICE_TIMEOUT (AUDIT.md §2.5).
SERVICE_TIMEOUT_SECS="${XUI_MOVER_SERVICE_TIMEOUT:-30}"
readonly TOOL_VERSION="1.0.0"

# ============================================================================
# Exit codes — one distinct code per failure class (never a bare exit 1
# except the true catch-all), so scripted/support use can branch on $?.
# ============================================================================

readonly EXIT_GENERIC=1                     # unexpected/unhandled error (ERR trap catch-all)
readonly EXIT_NOT_ROOT=2                    # not running as root
readonly EXIT_UNSUPPORTED_OS=3              # non-systemd or non-Debian/Ubuntu host
readonly EXIT_XUI_NOT_INSTALLED=4           # x-ui service/binary not found
readonly EXIT_ENV_FILE_MISSING=5            # /etc/default/x-ui (or equivalent) not found
readonly EXIT_BACKEND_UNKNOWN=6             # unrecognized XUI_DB_TYPE value
readonly EXIT_DSN_PARSE_FAILED=7            # XUI_DB_DSN missing or doesn't match expected format
readonly EXIT_DB_FILE_MISSING=8             # SQLite db file not found at resolved path (backup side)
readonly EXIT_PG_CLIENT_MISSING=9           # pg_dump/pg_restore/psql not installed
readonly EXIT_SQLITE_CLIENT_MISSING=10      # sqlite3 not installed
readonly EXIT_MULTI_NODE_BLOCKED=11         # nodes table has rows, no override flag
readonly EXIT_DUMP_FAILED=12                # pg_dump non-zero, or sqlite snapshot copy failed
readonly EXIT_ARCHIVE_BUILD_FAILED=13       # tar failed while building the archive
readonly EXIT_CHECKSUM_MISMATCH=14          # local checksum verification failed
readonly EXIT_SSH_FAILED=15                 # SSH connectivity test failed (auth or unreachable)
readonly EXIT_PUSH_VERIFY_FAILED=16         # scp/rsync succeeded but remote file missing/checksum mismatch
readonly EXIT_ARCHIVE_INVALID=17            # archive missing/corrupt/missing expected members
readonly EXIT_BACKEND_MISMATCH=18           # archive backend != target's configured backend
readonly EXIT_PG_TARGET_NOT_PROVISIONED=19  # target's own Postgres role/db unreachable
readonly EXIT_USER_ABORTED=20               # typed confirmation didn't match, or user declined a prompt
readonly EXIT_SERVICE_STOP_FAILED=21        # systemctl stop x-ui didn't reach inactive within timeout
readonly EXIT_RESTORE_FAILED=22             # pg_restore reported errors, or sqlite replace/integrity-check failed
readonly EXIT_SANITY_CHECK_FAILED=23        # post-restore count query itself errored
readonly EXIT_SERVICE_START_FAILED=24       # systemctl start x-ui didn't reach active within timeout
readonly EXIT_CERT_RESTORE_FAILED=25        # cert copy/permission step failed
readonly EXIT_BAD_ARGS=26                   # invalid flag combination
readonly EXIT_DISK_FULL=27                  # not enough free space for dump/archive/extract

# ============================================================================
# Global state (mutated by functions below; each entry-point's main() must
# initialize these before parse_flags/preflight runs, since `set -u` is on)
# ============================================================================

DRY_RUN=0                 # set by --dry-run; run_step() no-ops mutating calls
NO_COLOR_FLAG=0            # set by --no-color
ASSUME_YES=0                # set by --yes
WORKDIR=""                   # set by make_workdir()
LOG_FILE=""                   # set by setup_logging()
SERVICE_STOPPED=0              # set to 1 once xui_stop_and_wait() begins; die() tails logs when 1
XUI_SERVICE=""                   # discovered at runtime by discover_xui_installation — never hardcoded
PG_USER=""; PG_PASS=""; PG_HOST=""; PG_PORT=""; PG_DB=""; PG_CONN_NOAUTH=""
SSH_USE_PASSWORD=0; SSH_PASSWORD=""
STDIO_REDIRECTED=0            # set by setup_logging; flush_logs restores stdio so tee/sed drain
INTERRUPT_RESTART_XUI=0       # backup SQLite snapshot window: restart x-ui on INT/TERM
PRE_RESTORE_SNAPSHOT=""       # restore.sh safety copy path, kept outside WORKDIR

# ============================================================================
# Output / logging
# ============================================================================

# True if stdout is a terminal and color hasn't been disabled.
ui_supports_color() {
  [[ -t 1 && "$NO_COLOR_FLAG" -eq 0 && -z "${NO_COLOR:-}" ]]
}

# Populates C_RED/C_GREEN/C_YELLOW/C_BLUE/C_BOLD/C_RESET, real ANSI codes or
# empty strings depending on ui_supports_color(). Call once after parse_flags.
setup_colors() {
  if ui_supports_color; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
  else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
  fi
}

# Tees all subsequent stdout/stderr to both the terminal (with color) and a
# log file (ANSI stripped, so it's shareable as plain text for support).
# Falls back to $WORK_ROOT if /var/log isn't writable.
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

# Close the tee/sed pipe so the last lines (summary or failure reason) land
# in $LOG_FILE before the process exits (AUDIT.md §2.4).
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

# step_banner CUR TOTAL DESCRIPTION — the numbered phase header printed once
# per phase, e.g. "[3/8] Dumping database...".
step_banner() {
  printf '\n%s%s[%s/%s] %s%s\n' "$C_BLUE" "$C_BOLD" "$1" "$2" "$3" "$C_RESET"
}

# print_box LINE... — bordered block, visually distinct from step banners.
# Used for the restore.sh confirmation gate and the multi-node warning so
# they can't be skimmed past as ordinary log output.
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

# print_summary TITLE LINE... — final one-screen summary block.
print_summary() {
  local title="$1"; shift
  printf '\n'
  print_box "$title" "" "$@"
}

# die EXIT_CODE MESSAGE [HINT] — the single chokepoint for every non-zero
# exit. Logs the error, an optional actionable hint, auto-tails the x-ui log
# if SERVICE_STOPPED=1 (i.e. we're past the point of no return), then exits.
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

# confirm_yes_no PROMPT [DEFAULT=n] — informational, non-safety-critical
# prompt. Honors ASSUME_YES. Never used for the restore.sh destructive gate.
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

# confirm_typed EXPECTED — byte-exact match against typed input. Never
# accepts y/yes as equivalent. This is restore.sh's safety-critical gate.
confirm_typed() {
  local expected="$1" reply
  read -r -p "Type '${expected}' to proceed: " reply || reply=""
  [[ "$reply" == "$expected" ]]
}

# ============================================================================
# Cleanup / traps
# ============================================================================

# Creates $WORK_ROOT/run-<ts>-$$ (mode 700) and sets WORKDIR to it.
# `mkdir -p -m` only applies the mode to directories it actually creates — a
# pre-existing WORK_ROOT (e.g. left over from an older version, or created
# some other way) would silently keep whatever permissions it already had.
# chmod explicitly so a credential-bearing directory is never left more
# permissive than 700 regardless of prior state.
make_workdir() {
  mkdir -p "$WORK_ROOT"
  chmod 700 "$WORK_ROOT"
  WORKDIR="${WORK_ROOT}/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR"
}

# Removes WORKDIR on exit (success or failure). Path-guarded so a bad
# expansion can never rm -rf something unintended. Registered via
# `trap cleanup EXIT` — does not call exit itself, so the script's real exit
# status is preserved.
cleanup() {
  flush_logs
  if [[ -n "${WORKDIR:-}" && "$WORKDIR" == "$WORK_ROOT"/run-* && -d "$WORKDIR" ]]; then
    # `|| true`: this runs as the EXIT trap under `set -e` — an rm failure
    # here (busy mount, odd permissions) must never override the script's
    # real exit code.
    rm -rf "$WORKDIR" || true
  fi
}

# ============================================================================
# Preflight / detection
# ============================================================================

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

# Finds x-ui's environment file: checks the known candidate paths first,
# falls back to asking systemd what it actually configured.
#
# resolve_xui_env_file OUT_VAR — writes the result into OUT_VAR (nameref)
# instead of printing it for `$(...)` capture. A `die` inside a command
# substitution only kills that subshell, not the script (set -e then trips
# the generic ERR trap and both the real exit code and message are lost) —
# see AUDIT.md #1.1. Running in the caller's own shell via nameref avoids
# that entirely.
#
# The env file itself is genuinely optional: x-ui's own systemd unit
# declares it with `ignore_errors=yes` (verified against a real install),
# because it only ever gets created when Postgres is configured through
# x-ui's own setup menu. A plain SQLite install may never have one at all.
# So its absence is NOT treated as fatal here — OUT_VAR is simply left
# empty, and detect_backend/resolve_sqlite_path (which already tolerate a
# missing/unreadable file, defaulting to SQLite) take it from there. Only
# an actually undetectable backend should ever be fatal, not this file's
# mere absence.
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
# and executable without assuming any fixed unit name or install path (see
# AUDIT.md §7 — the old resolve_xui_bin/require_xui_installed pair assumed
# XUI_SERVICE="x-ui" and fell back to a hardcoded /usr/local/x-ui/x-ui).
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

# detect_backend ENV_FILE OUT_VAR — reads XUI_DB_TYPE, writes "postgres" or
# "sqlite" into OUT_VAR (nameref). Dies on anything else. See
# resolve_xui_env_file above for why this isn't a `$(...)`-captured return.
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

# ============================================================================
# Postgres
# ============================================================================

# Percent-decode a URL component. Does NOT treat `+` as space — that rule
# belongs to application/x-www-form-urlencoded query strings, not the
# userinfo (user:password) component of a URI (AUDIT.md §1.3). Only valid
# `%HH` sequences are decoded; a stray `%` or a literal backslash is left
# untouched, so printf `%b` cannot mis-interpret password bytes (AUDIT.md §1.4).
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

# parse_pg_dsn DSN — populates PG_USER/PG_PASS/PG_HOST/PG_PORT/PG_DB and
# PG_CONN_NOAUTH (a credential-free connection URI reconstructed from the
# original, preserving arbitrary query params like sslmode instead of
# assuming one). Accepts the forms x-ui actually writes and the common
# shortenings operators type by hand: optional password, optional port
# (defaults to 5432), IPv6 hosts in brackets (AUDIT.md §11.2). Dies on an
# unparseable DSN. Password is percent-decoded via url_decode.
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

# mask_dsn DSN — password replaced with **** for safe display/logging.
mask_dsn() {
  printf '%s' "$1" | sed -E 's|(://[^:/@]+:)[^@]+@|\1****@|'
}

pg_client_precheck() {
  command -v pg_dump >/dev/null 2>&1 && command -v pg_restore >/dev/null 2>&1 \
    || die "$EXIT_PG_CLIENT_MISSING" "pg_dump/pg_restore not found." "Install with: apt-get install -y postgresql-client, or run: x-ui pgclient <server-major-version>"
}

# pg_test_connection — returns non-zero (does NOT die) on failure; callers
# decide the right exit code/hint for their context (e.g. restore.sh's
# "provision it via x-ui's menu" guidance).
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

# pg_restore_from_file DUMP_FILE — restores with --no-owner --role=<user>
# -c --if-exists so ownership reassignment and pre-existing-object cleanup
# both happen in one pass. Matches "^pg_restore: error:" specifically
# (not a bare "ERROR" grep) to avoid false positives on the expected
# --if-exists NOTICE lines during a first restore.
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

# pg_sanity_counts OUT_INBOUNDS OUT_USERS OUT_SETTINGS — writes the three
# counts into the given namerefs. Dies only on a genuine query error, not on
# a legitimate zero count — but see resolve_xui_env_file above: this must be
# called directly (never via `read ... <<<"$(pg_sanity_counts)"`), otherwise
# that die() only kills the subshell and the failure is silently swallowed
# (AUDIT.md #1.2). The settings-table count exists because that single table
# holds the panel's global settings *and* the Xray Configuration template
# (outbounds/routing/DNS, stored as one JSON blob under key
# "xrayTemplateConfig") — comparing its row count pre/post restore catches
# "the settings table itself didn't come across" without needing to parse
# the JSON.
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

# ============================================================================
# SQLite
# ============================================================================

sqlite_client_precheck() {
  command -v sqlite3 >/dev/null 2>&1 || die "$EXIT_SQLITE_CLIENT_MISSING" "sqlite3 not found." "Install with: apt-get install -y sqlite3"
}

# resolve_sqlite_path ENV_FILE — reads XUI_DB_FOLDER (falls back to the
# documented default) and joins it with the fixed x-ui.db filename.
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
# See AUDIT.md §10.1. Used by both backup.sh (workdir copy) and restore.sh
# (bundle -> target copy) — same operation either direction.
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
# by restore.sh before placing a freshly restored .db so a stale leftover
# -wal from the target's previous database can never be replayed over it.
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

# sqlite_sanity_counts PATH OUT_INBOUNDS OUT_USERS OUT_SETTINGS — see
# pg_sanity_counts above: must be called directly, not via `$(...)` capture.
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

# ============================================================================
# Service control
# ============================================================================

xui_is_active() {
  systemctl is-active --quiet "$XUI_SERVICE"
}

# Stops x-ui and polls until inactive (or SERVICE_TIMEOUT_SECS elapses).
# Sets SERVICE_STOPPED=1 immediately, before even attempting the stop, so
# that any failure from this point on (including the stop itself failing)
# triggers die()'s automatic log-tail.
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

# tail_xui_log [N=20] — journalctl is x-ui's actual log source (no
# guaranteed static log file); falls back to /var/log/x-ui/*.log if
# journalctl is unavailable. Called automatically by die() once
# SERVICE_STOPPED=1, so call sites never need to invoke it themselves.
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

# ============================================================================
# Multi-node guard
# ============================================================================

# count_nodes_rows — relies on the caller having set BACKEND and (for
# sqlite) SQLITE_PATH globals. A missing 'nodes' table is treated as 0
# (older/never-multi-node installs). Any other query error is fatal: failing
# open (coercing errors to 0) would silently skip the multi-node guard
# (AUDIT.md §2.3).
count_nodes_rows() {
  local n="" err=""
  if [[ "$BACKEND" == "postgres" ]]; then
    n=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT count(*) FROM nodes;' 2>"$WORKDIR/nodes.stderr") || {
      err=$(cat "$WORKDIR/nodes.stderr" 2>/dev/null || true)
      if [[ "$err" == *"does not exist"* ]]; then
        printf '0'
        return 0
      fi
      die "$EXIT_SANITY_CHECK_FAILED" "Could not determine node count (refusing to skip the multi-node guard)." "$err"
    }
  else
    n=$(sqlite3 "$SQLITE_PATH" 'SELECT count(*) FROM nodes;' 2>"$WORKDIR/nodes.stderr") || {
      err=$(cat "$WORKDIR/nodes.stderr" 2>/dev/null || true)
      if [[ "$err" == *"no such table"* ]]; then
        printf '0'
        return 0
      fi
      die "$EXIT_SANITY_CHECK_FAILED" "Could not determine node count (refusing to skip the multi-node guard)." "$err"
    }
  fi
  n="${n//[[:space:]]/}"
  [[ -z "$n" ]] && n="0"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    die "$EXIT_SANITY_CHECK_FAILED" "Node count query returned a non-numeric value." "Got: ${n:0:80}"
  fi
  printf '%s' "$n"
}

# check_multi_node_guard ALLOW_FLAG(0|1) — warns loudly and dies unless the
# override flag was given (--i-know-this-is-multi-node), per product
# decision: backup.sh must not silently produce an incomplete backup.
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

# ============================================================================
# Archive
# ============================================================================

# build_archive OUT_TAR SRC_DIR ARCHIVE_STEM MEMBER... — tars only the named
# members of SRC_DIR under a renamed top-level ARCHIVE_STEM/ directory (via
# GNU tar --transform), so scratch/stderr-capture files left loose in
# WORKDIR never leak into the shipped archive.
build_archive() {
  local out_tar="$1" src_dir="$2" archive_stem="$3"; shift 3
  if ! tar czf "$out_tar" -C "$src_dir" --transform "s,^,${archive_stem}/," "$@"; then
    die "$EXIT_ARCHIVE_BUILD_FAILED" "Failed to build archive $out_tar."
  fi
}

# checksum_file PATH — prints the sha256 and writes a PATH.sha256 sidecar
# in `sha256sum -c`-compatible format.
checksum_file() {
  local path="$1" sum=""
  sum=$(sha256sum "$path" | awk '{print $1}')
  (cd "$(dirname "$path")" && sha256sum "$(basename "$path")" > "$(basename "$path").sha256")
  printf '%s' "$sum"
}

# verify_local_checksum PATH — re-reads PATH from disk (backup.sh side) and
# checks it against the .sha256 sidecar checksum_file() just wrote,
# independently of that write. Catches the archive having been
# altered/truncated/corrupted between being built and being read back (bad
# disk, race with another process, etc.) instead of trusting the in-memory
# value computed a moment earlier. Uses EXIT_CHECKSUM_MISMATCH, which was
# previously defined but never actually triggered by any code path
# (AUDIT.md §13).
verify_local_checksum() {
  local path="$1" sidecar="${1}.sha256"
  [[ -f "$sidecar" ]] || die "$EXIT_CHECKSUM_MISMATCH" "Checksum sidecar file not found: $sidecar"
  if ! (cd "$(dirname "$path")" && sha256sum -c "$(basename "$sidecar")") >/dev/null 2>"$WORKDIR/checksum_verify.stderr"; then
    die "$EXIT_CHECKSUM_MISMATCH" "Local checksum verification failed for $path." "The archive on disk does not match its own recorded checksum — do not transfer or restore from it. Re-run backup.sh."
  fi
}

# verify_archive_checksum_if_present ARCHIVE — restore.sh side counterpart:
# if ARCHIVE.sha256 sits next to the archive (always true after --push-to,
# since push_archive() ships both files together; true for a manual scp
# only if the sidecar was copied too), verifies the archive against it and
# dies with EXIT_CHECKSUM_MISMATCH on a mismatch. If the sidecar isn't
# present, this is a no-op — the structural check in extract_archive() below
# still runs regardless.
verify_archive_checksum_if_present() {
  local archive="$1" sidecar="${1}.sha256"
  [[ -f "$sidecar" ]] || { log_info "No .sha256 sidecar found next to the archive — skipping checksum verification."; return 0; }
  if ! (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$sidecar")") >/dev/null 2>"$WORKDIR/checksum_verify.stderr"; then
    die "$EXIT_CHECKSUM_MISMATCH" "Archive checksum verification failed against $(basename "$sidecar")." "The archive does not match its recorded checksum — do not proceed. Re-transfer it from the source."
  fi
  log_success "Archive checksum verified against $(basename "$sidecar")"
}

# extract_archive ARCHIVE DEST_DIR OUT_VAR — extracts and writes the path to
# the archive's meta.json into OUT_VAR (nameref); dies if missing/corrupt.
# Caller derives the bundle root via `dirname` of that path. Nameref rather
# than `$(...)` capture — see resolve_xui_env_file above. Runs `tar tzf`
# first (structural check only, no extraction) so a truncated/corrupted
# archive is caught with a clear message instead of a partial extraction or
# a confusing downstream failure.
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

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Hand-rolled flat JSON writer/reader — deliberately no jq dependency, since
# we fully control meta.json's format (single-level, plus one nested object)
# and the PRD never requires jq. String fields are escaped (AUDIT.md §1.8).
write_meta_json() {
  local out_file="$1" hostname_v="$2" backend_v="$3" xui_version_v="$4" inbounds_v="$5" users_v="$6" settings_v="$7" nodes_v="$8"
  hostname_v="$(json_escape "$hostname_v")"
  backend_v="$(json_escape "$backend_v")"
  xui_version_v="$(json_escape "$xui_version_v")"
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

read_meta_json_field() {
  local file="$1" key="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"\$/\\1/"
}

read_meta_json_number() {
  local file="$1" key="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//'
}

# ============================================================================
# SSH transfer
# ============================================================================

# ssh_opts IDENTITY PORT OUT_ARRAY_NAME — builds a shared -o option set via
# nameref (bash 4.3+, present on all supported Ubuntu/Debian releases).
ssh_opts() {
  local identity="$1" port="$2"
  local -n _out="$3"
  _out=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
  [[ -n "$identity" ]] && _out+=(-i "$identity")
  [[ -n "$port" ]] && _out+=(-p "$port")
}

# ssh_test_connection USER_HOST PORT IDENTITY — tries key/agent auth first;
# if that fails and sshpass is available, prompts for a password and
# retries (product decision: support both auth modes, not key-only). Sets
# SSH_USE_PASSWORD/SSH_PASSWORD globals for push_archive() to reuse. Dies
# with an auth-vs-unreachable-specific hint on total failure.
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

# push_archive USER_HOST PORT IDENTITY LOCAL_TAR REMOTE_DIR — creates the
# remote dir, scp's the archive + its .sha256 sidecar, then re-hashes the
# remote copy and compares against the local checksum. Only sets
# REMOTE_ARCHIVE_PATH (and only reports success) once that comparison
# passes — matches scp's exit 0 not being sufficient per the PRD's
# acceptance criteria.
push_archive() {
  local user_host="$1" port="$2" identity="$3" local_tar="$4" remote_dir="$5"
  local opts=() rc=0
  ssh_opts "$identity" "$port" opts
  local local_sum=""; local_sum=$(sha256sum "$local_tar" | awk '{print $1}')

  rc=0
  local remote_dir_q tar_q
  printf -v remote_dir_q '%q' "$remote_dir"
  printf -v tar_q '%q' "${remote_dir}/$(basename "$local_tar")"
  if [[ "$SSH_USE_PASSWORD" -eq 1 ]]; then
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "${opts[@]}" "$user_host" "mkdir -p ${remote_dir_q}" || rc=$?
  else
    ssh "${opts[@]}" "$user_host" "mkdir -p ${remote_dir_q}" || rc=$?
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
    remote_sum=$(SSHPASS="$SSH_PASSWORD" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "${opts[@]}" "$user_host" "sha256sum ${tar_q}" 2>/dev/null | awk '{print $1}') || remote_sum=""
  else
    remote_sum=$(ssh "${opts[@]}" "$user_host" "sha256sum ${tar_q}" 2>/dev/null | awk '{print $1}') || remote_sum=""
  fi

  if [[ -z "$remote_sum" || "$remote_sum" != "$local_sum" ]]; then
    die "$EXIT_PUSH_VERIFY_FAILED" "Remote checksum did not match local checksum after transfer." "Local: $local_sum  Remote: ${remote_sum:-<missing>}"
  fi
  REMOTE_ARCHIVE_PATH="${remote_dir}/$(basename "$local_tar")"
}

# ============================================================================
# Certs
# ============================================================================

list_cert_paths_from_db() {
  local sql="SELECT value FROM settings WHERE key IN ('webCertFile','webKeyFile');"
  local raw="" blob=""
  if [[ "${BACKEND:-}" == "postgres" ]]; then
    raw=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc "$sql" 2>/dev/null) || raw=""
    blob=$(PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_CONN_NOAUTH" -tAc 'SELECT settings FROM inbounds;' 2>/dev/null) || blob=""
  elif [[ -n "${SQLITE_PATH:-}" && -f "$SQLITE_PATH" ]]; then
    raw=$(sqlite3 "$SQLITE_PATH" "$sql" 2>/dev/null) || raw=""
    blob=$(sqlite3 "$SQLITE_PATH" 'SELECT settings FROM inbounds;' 2>/dev/null) || blob=""
  fi
  printf '%s\n' "$raw"
  printf '%s' "$blob" | grep -oE '/[^[:space:]\"'\'']+\.(pem|crt|key|cer|cert)' || true
}

collect_panel_certs() {
  local dest="$1" copied=0 path rel
  mkdir -p "$dest/cert"
  if [[ -d "$XUI_CERT_DIR" ]]; then
    cp -a "$XUI_CERT_DIR/." "$dest/cert/"
  fi
  mkdir -p "$dest/extra-certs"
  if [[ -d /root/.acme.sh ]]; then
    cp -a /root/.acme.sh "$dest/extra-certs/acme.sh"
    copied=1
    log_info "Captured /root/.acme.sh"
  fi
  if [[ -d /etc/letsencrypt ]]; then
    cp -a /etc/letsencrypt "$dest/extra-certs/letsencrypt"
    copied=1
    log_info "Captured /etc/letsencrypt"
  fi
  : >"$dest/extra-certs/paths.list"
  while IFS= read -r path; do
    [[ -z "$path" || ! -e "$path" ]] && continue
    case "$path" in
      "$XUI_CERT_DIR"/*|/root/.acme.sh/*|/etc/letsencrypt/*) continue ;;
    esac
    rel="files${path}"
    mkdir -p "$dest/extra-certs/$(dirname "$rel")"
    cp -a "$path" "$dest/extra-certs/$rel"
    printf '%s\n' "$path" >> "$dest/extra-certs/paths.list"
    copied=1
    log_info "Captured extra cert path: $path"
  done < <(list_cert_paths_from_db)
  if [[ "$copied" -eq 0 ]]; then
    rm -rf "$dest/extra-certs"
  fi
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

# ============================================================================
# Dry-run
# ============================================================================

# run_step DESCRIPTION FUNC [ARGS...] — mutating operations are called
# through this wrapper; under --dry-run it prints the intended action and
# returns 0 without calling FUNC. Read-only detection calls should NOT go
# through this wrapper, so dry-run summaries stay accurate.
run_step() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[DRY RUN] would: $desc"
    return 0
  fi
  "$@"
}
