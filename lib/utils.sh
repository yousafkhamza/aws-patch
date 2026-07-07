#!/usr/bin/env bash
# lib/utils.sh
#
# Generic, distro-agnostic utility functions used across aws-patch modules.
# No package-manager or kernel-specific logic belongs here.
#
# Public functions:
#   utils_version_ge <v1> <v2>   -> returns 0 if v1 >= v2
#   utils_version_gt <v1> <v2>   -> returns 0 if v1 >  v2
#   utils_confirm <prompt>       -> returns 0 if user answers yes
#   utils_is_true <value>        -> returns 0 if value is a truthy string
#   utils_human_duration <secs>  -> echoes "Xm Ys" style duration
#   utils_command_exists <name>  -> returns 0 if command is on PATH
#   utils_die <exit_code> <msg>  -> logs error and exits

set -Eeuo pipefail

if [[ "${_AWS_PATCH_UTILS_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_UTILS_SH_LOADED="true"

# ---------------------------------------------------------------------------
# utils_version_ge <v1> <v2>
#   Dotted/dashed version comparison using `sort -V`. Works for kernel
#   version strings like "5.15.0-105-generic" as well as simple "22.04".
# ---------------------------------------------------------------------------
utils_version_ge() {
    local v1="$1"
    local v2="$2"
    [[ "$v1" == "$v2" ]] && return 0
    local highest
    highest="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -n1)"
    [[ "$highest" == "$v1" ]]
}

# ---------------------------------------------------------------------------
# utils_version_gt <v1> <v2>
# ---------------------------------------------------------------------------
utils_version_gt() {
    local v1="$1"
    local v2="$2"
    [[ "$v1" == "$v2" ]] && return 1
    utils_version_ge "$v1" "$v2"
}

# ---------------------------------------------------------------------------
# utils_confirm <prompt>
#   Prompts the user interactively. Returns 0 for yes, 1 for no.
#   If ASSUME_YES=true (from --yes flag) or not running on a TTY in a
#   context where a default was provided, the caller should check that
#   flag *before* calling this function.
# ---------------------------------------------------------------------------
utils_confirm() {
    local prompt="${1:-Are you sure?}"
    local reply

    if [[ ! -t 0 ]]; then
        # No interactive terminal available; default to "no" for safety.
        log_warn "No interactive terminal available; defaulting to 'no' for: $prompt"
        return 1
    fi

    read -r -p "$prompt [y/N]: " reply
    case "$reply" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# utils_is_true <value>
#   Accepts true/1/yes/on (case-insensitive) as truthy.
# ---------------------------------------------------------------------------
utils_is_true() {
    local value="${1:-}"
    case "${value,,}" in
        true|1|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# utils_human_duration <seconds>
#   Echoes a human-readable duration, e.g. "2m 5s" or "45s".
# ---------------------------------------------------------------------------
utils_human_duration() {
    local total_secs="${1:?seconds required}"
    local mins=$(( total_secs / 60 ))
    local secs=$(( total_secs % 60 ))

    if (( mins > 0 )); then
        printf '%dm %ds' "$mins" "$secs"
    else
        printf '%ds' "$secs"
    fi
}

# ---------------------------------------------------------------------------
# utils_command_exists <name>
# ---------------------------------------------------------------------------
utils_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# utils_die <exit_code> <message>
#   Logs an error (if logger.sh is loaded) or falls back to plain stderr,
#   then exits with the given code. Centralizes fatal-error handling so
#   aws-patch.sh's trap can distinguish expected exits from crashes.
# ---------------------------------------------------------------------------
utils_die() {
    local exit_code="${1:?exit_code required}"
    shift
    local message="$*"

    if declare -F log_error >/dev/null 2>&1; then
        log_error "$message"
    else
        printf 'ERROR: %s\n' "$message" >&2
    fi

    exit "$exit_code"
}
