#!/usr/bin/env bash
# lib/logger.sh
#
# Logging and colorized console output for aws-patch.
#
# Responsibilities:
#   - Write timestamped entries to the log file (/var/log/aws-patch.log by default)
#   - Print colorized, icon-prefixed status lines to the console
#   - Provide a spinner helper with elapsed time for long-running commands
#
# This file must not contain any package-manager-specific or kernel-specific
# logic. It is a pure presentation/logging layer.
#
# Public functions:
#   log_init
#   log_line   <level> <message>
#   log_info   <message>
#   log_warn   <message>
#   log_error  <message>
#   log_debug  <message>
#   log_success <message>
#   ui_header  <message>
#   ui_step    <message>
#   ui_spinner_start <message>
#   ui_spinner_stop  [status]
#
# Expects (optionally pre-set by caller):
#   AWS_PATCH_LOG_FILE   - path to log file (default: /var/log/aws-patch.log)
#   VERBOSE              - "true"/"false", controls whether debug lines print to console
#   NO_COLOR              - if set (any value), disables ANSI color output

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Guard against double-sourcing
# ---------------------------------------------------------------------------
if [[ "${_AWS_PATCH_LOGGER_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_LOGGER_SH_LOADED="true"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
AWS_PATCH_LOG_FILE="${AWS_PATCH_LOG_FILE:-/var/log/aws-patch.log}"
VERBOSE="${VERBOSE:-false}"

# ---------------------------------------------------------------------------
# Colors / Icons
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET="\033[0m"
    readonly C_BOLD="\033[1m"
    readonly C_DIM="\033[2m"
    readonly C_RED="\033[31m"
    readonly C_GREEN="\033[32m"
    readonly C_YELLOW="\033[33m"
    readonly C_BLUE="\033[34m"
    readonly C_MAGENTA="\033[35m"
    readonly C_CYAN="\033[36m"
else
    readonly C_RESET=""
    readonly C_BOLD=""
    readonly C_DIM=""
    readonly C_RED=""
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_BLUE=""
    readonly C_MAGENTA=""
    readonly C_CYAN=""
fi

readonly ICON_INFO="ℹ"
readonly ICON_OK="✔"
readonly ICON_WARN="⚠"
readonly ICON_ERR="✖"
readonly ICON_DEBUG="•"
readonly ICON_STEP="➜"

# ---------------------------------------------------------------------------
# log_init
#   Ensures the log file exists and is writable. Falls back to a temp file
#   if /var/log is not writable (e.g. running as non-root during --dry-run
#   or in test environments).
# ---------------------------------------------------------------------------
log_init() {
    local log_dir
    log_dir="$(dirname -- "$AWS_PATCH_LOG_FILE")"

    if [[ ! -d "$log_dir" ]]; then
        mkdir -p -- "$log_dir" 2>/dev/null || true
    fi

    if ! touch "$AWS_PATCH_LOG_FILE" 2>/dev/null; then
        AWS_PATCH_LOG_FILE="/tmp/aws-patch-$(id -u).log"
        touch "$AWS_PATCH_LOG_FILE" 2>/dev/null || true
    fi

    log_line "INFO" "==== aws-patch log initialized (PID $$) ===="
}

# ---------------------------------------------------------------------------
# log_line <level> <message>
#   Writes a single timestamped line to the log file. Never fails the
#   script even if the log file becomes unwritable mid-run.
# ---------------------------------------------------------------------------
log_line() {
    local level="$1"
    shift
    local message="$*"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    printf '%s [%-5s] %s\n' "$ts" "$level" "$message" >> "$AWS_PATCH_LOG_FILE" 2>/dev/null || true
}

log_info() {
    log_line "INFO" "$*"
    printf '%b %s%s%b\n' "$C_BLUE$ICON_INFO$C_RESET" "" "$*" "$C_RESET"
}

log_success() {
    log_line "OK" "$*"
    printf '%b %s%b\n' "$C_GREEN$ICON_OK$C_RESET" "$*" "$C_RESET"
}

log_warn() {
    log_line "WARN" "$*"
    printf '%b %s%b\n' "$C_YELLOW$ICON_WARN$C_RESET" "$*" "$C_RESET" >&2
}

log_error() {
    log_line "ERROR" "$*"
    printf '%b %s%b\n' "$C_RED$ICON_ERR$C_RESET" "$*" "$C_RESET" >&2
}

log_debug() {
    log_line "DEBUG" "$*"
    if [[ "$VERBOSE" == "true" ]]; then
        printf '%b %s%b\n' "$C_DIM$ICON_DEBUG" "$*" "$C_RESET"
    fi
}

# ---------------------------------------------------------------------------
# ui_header <message>
#   Prints a bold section header to the console and logs it.
# ---------------------------------------------------------------------------
ui_header() {
    local message="$*"
    log_line "INFO" "== $message =="
    printf '\n%b%s%b\n' "$C_BOLD$C_CYAN" "== $message ==" "$C_RESET"
}

# ---------------------------------------------------------------------------
# ui_step <message>
#   Prints a single workflow step line.
# ---------------------------------------------------------------------------
ui_step() {
    local message="$*"
    log_line "STEP" "$message"
    printf '%b %s%b\n' "$C_MAGENTA$ICON_STEP$C_RESET" "$message" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Spinner
#   ui_spinner_start "message"   -> begins a background spinner with elapsed time
#   ui_spinner_stop  [ok|fail]   -> stops it and prints a final status line
#
# Implementation notes:
#   - Uses a background subshell writing to the same terminal line via \r.
#   - PID tracked in _SPINNER_PID so multiple spinners never overlap.
#   - Disabled automatically when stdout is not a TTY (e.g. CI logs), in
#     which case it degrades to a single static log line.
# ---------------------------------------------------------------------------
_SPINNER_PID=""
_SPINNER_MSG=""
_SPINNER_START_TS=0

ui_spinner_start() {
    _SPINNER_MSG="$*"
    _SPINNER_START_TS="$(date +%s)"
    log_line "STEP" "$_SPINNER_MSG (started)"

    if [[ ! -t 1 ]]; then
        printf '%b %s...%b\n' "$C_MAGENTA$ICON_STEP$C_RESET" "$_SPINNER_MSG" "$C_RESET"
        return 0
    fi

    (
        local frames=("|" "/" "-" "\\")
        local i=0
        while true; do
            local now elapsed
            now="$(date +%s)"
            elapsed=$(( now - _SPINNER_START_TS ))
            i=$(( (i + 1) % 4 ))
            printf '\r%b %s%b %s (%ds) ' \
                "$C_MAGENTA" "${frames[$i]}" "$C_RESET" "$_SPINNER_MSG" "$elapsed"
            sleep 0.2
        done
    ) &
    disown
    _SPINNER_PID=$!
}

ui_spinner_stop() {
    local status="${1:-ok}"
    local elapsed=$(( $(date +%s) - _SPINNER_START_TS ))

    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
    fi

    if [[ -t 1 ]]; then
        printf '\r%*s\r' 80 ""
    fi

    case "$status" in
        ok)
            log_success "${_SPINNER_MSG} (${elapsed}s)"
            ;;
        fail)
            log_error "${_SPINNER_MSG} failed (${elapsed}s)"
            ;;
        *)
            log_info "${_SPINNER_MSG} (${elapsed}s)"
            ;;
    esac
}

# Ensure spinner is killed if the script exits unexpectedly.
_logger_cleanup_spinner() {
    if [[ -n "${_SPINNER_PID:-}" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
    fi
}
trap _logger_cleanup_spinner EXIT
