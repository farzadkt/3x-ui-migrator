#!/usr/bin/env bash
# source.sh — public entry point for the OLD/source 3x-ui server.
#
# Thin wrapper around backup.sh. This is the name referenced by the README's
# "one command on the old server" workflow; backup.sh remains a fully
# supported, independently runnable entry point for backward compatibility.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main/source.sh)
#
# All flags are passed straight through to backup.sh — run
# `source.sh --help` (equivalent to `backup.sh --help`) for the full list.
#
# Resolution order:
#   1. If backup.sh exists next to this script (e.g. after `git clone`),
#      run it directly — no network fetch needed.
#   2. Otherwise (e.g. when piped via `bash <(curl ...)`, where no other
#      repo files are present on disk) fetch backup.sh from the same repo
#      this script itself was fetched from and run it the same way.
set -Eeuo pipefail

readonly RAW_BASE="https://raw.githubusercontent.com/farzadkt/3x-ui-migrator/main"

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
fi

if [[ -n "$script_dir" && -f "$script_dir/backup.sh" ]]; then
  exec bash "$script_dir/backup.sh" "$@"
fi

tmp="$(mktemp)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

if ! curl -fsSL "$RAW_BASE/backup.sh" -o "$tmp"; then
  echo "[ERROR] Failed to download backup.sh from $RAW_BASE" >&2
  echo "-> Check your network connection, or clone the repo and run backup.sh directly." >&2
  exit 1
fi

bash "$tmp" "$@"
exit $?
