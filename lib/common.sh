#!/usr/bin/env bash
# lib/common.sh
#
# Shared, package-manager-agnostic helpers for aws-patch:
#   - OS / distro detection
#   - Package manager detection
#   - Architecture / hostname detection
#   - Connectivity and disk-space checks
#   - Root/privilege checks
#   - Retry helper for transient command failures
#
# IMPORTANT: This file must NEVER contain package-manager-specific logic
# (no apt-get/yum/dnf calls) and must NEVER contain kernel-comparison logic.
# Those live in lib/apt.sh, lib/yum.sh, lib/dnf.sh, and lib/kernel.sh.
#
# Public functions:
#   common_require_root
#   common_detect_os          -> sets OS_ID, OS_VERSION_ID, OS_NAME, OS_FAMILY
#   common_detect_pkg_manager -> sets PKG_MANAGER
#   common_detect_arch        -> sets ARCH
#   common_detect_hostname    -> sets HOSTNAME_FQDN
#   common_check_connectivity -> returns 0/1, sets NET_OK
#   common_check_disk_space   <path> <required_mb>
#   common_retry <max_attempts> <sleep_seconds> -- <command...>

set -Eeuo pipefail

if [[ "${_AWS_PATCH_COMMON_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_COMMON_SH_LOADED="true"

# ---------------------------------------------------------------------------
# common_require_root
#   Exits with code 77 (EX_NOPERM-ish) if not running as root, unless
#   explicitly running in --dry-run/--check mode (caller decides).
# ---------------------------------------------------------------------------
common_require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_error "aws-patch must be run as root (try: sudo aws-patch.sh)"
        exit 77
    fi
}

# ---------------------------------------------------------------------------
# common_detect_os
#   Parses /etc/os-release (present on all supported distros) into:
#     OS_ID           e.g. ubuntu, debian, amzn, rhel, rocky, almalinux, centos
#     OS_VERSION_ID   e.g. 22.04, 12, 2023, 9, 7
#     OS_NAME         human readable PRETTY_NAME
#     OS_FAMILY        debian | rhel  (used only for high-level branching;
#                      actual package commands still live in apt.sh/yum.sh/dnf.sh)
# ---------------------------------------------------------------------------
common_detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        log_error "/etc/os-release not found or unreadable; cannot detect OS"
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"

    case "$OS_ID" in
        ubuntu|debian)
            OS_FAMILY="debian"
            ;;
        amzn|rhel|centos|rocky|almalinux)
            OS_FAMILY="rhel"
            ;;
        *)
            # Fall back to ID_LIKE if the primary ID is unrecognized
            # (covers rebrands / derivatives).
            if [[ "${ID_LIKE:-}" == *debian* ]]; then
                OS_FAMILY="debian"
            elif [[ "${ID_LIKE:-}" == *rhel*fedora* || "${ID_LIKE:-}" == *fedora* || "${ID_LIKE:-}" == *rhel* ]]; then
                OS_FAMILY="rhel"
            else
                log_error "Unsupported or unrecognized operating system: $OS_NAME"
                exit 1
            fi
            ;;
    esac

    export OS_ID OS_VERSION_ID OS_NAME OS_FAMILY
    log_debug "Detected OS: $OS_NAME (id=$OS_ID version=$OS_VERSION_ID family=$OS_FAMILY)"
}

# ---------------------------------------------------------------------------
# common_detect_pkg_manager
#   Sets PKG_MANAGER to one of: apt | yum | dnf
#   Detection is based on binary availability, cross-checked against OS_ID
#   so that, e.g., a RHEL 8 box with a stray `yum` shim still resolves to dnf.
# ---------------------------------------------------------------------------
common_detect_pkg_manager() {
    if [[ -z "${OS_ID:-}" ]]; then
        common_detect_os
    fi

    case "$OS_FAMILY" in
        debian)
            if command -v apt-get >/dev/null 2>&1; then
                PKG_MANAGER="apt"
            else
                log_error "Debian-family OS detected but apt-get is not available"
                exit 1
            fi
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER="yum"
            else
                log_error "RHEL-family OS detected but neither dnf nor yum is available"
                exit 1
            fi
            ;;
        *)
            log_error "Cannot determine package manager for OS family: $OS_FAMILY"
            exit 1
            ;;
    esac

    export PKG_MANAGER
    log_debug "Detected package manager: $PKG_MANAGER"
}

# ---------------------------------------------------------------------------
# common_detect_arch
#   Sets ARCH to the `uname -m` value (e.g. x86_64, aarch64).
# ---------------------------------------------------------------------------
common_detect_arch() {
    ARCH="$(uname -m)"
    export ARCH
    log_debug "Detected architecture: $ARCH"
}

# ---------------------------------------------------------------------------
# common_detect_hostname
# ---------------------------------------------------------------------------
common_detect_hostname() {
    HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"
    export HOSTNAME_FQDN
    log_debug "Detected hostname: $HOSTNAME_FQDN"
}

# ---------------------------------------------------------------------------
# common_check_connectivity
#   Verifies outbound connectivity to the distro's package repositories by
#   attempting a lightweight TCP connection. Sets NET_OK=true/false and
#   returns 0 if reachable, 1 otherwise. Never treats lack of connectivity
#   as a hard failure by itself -- caller decides what to do.
# ---------------------------------------------------------------------------
common_check_connectivity() {
    local test_hosts=("1.1.1.1" "8.8.8.8")
    local host

    NET_OK="false"

    for host in "${test_hosts[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsS --max-time 5 -o /dev/null "https://${host}" 2>/dev/null; then
                NET_OK="true"
                break
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q --timeout=5 -O /dev/null "https://${host}" 2>/dev/null; then
                NET_OK="true"
                break
            fi
        else
            # Fall back to /dev/tcp if neither curl nor wget exist.
            if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/443" 2>/dev/null; then
                NET_OK="true"
                break
            fi
        fi
    done

    export NET_OK

    if [[ "$NET_OK" == "true" ]]; then
        log_debug "Connectivity check passed"
        return 0
    else
        log_warn "Connectivity check failed (no route to common public endpoints)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# common_check_disk_space <path> <required_mb>
#   Verifies at least <required_mb> megabytes are free at <path>.
#   Returns 0 if sufficient, 1 otherwise.
# ---------------------------------------------------------------------------
common_check_disk_space() {
    local path="${1:?path required}"
    local required_mb="${2:?required_mb required}"
    local available_mb

    available_mb="$(df -Pm "$path" 2>/dev/null | awk 'NR==2 {print $4}')"

    if [[ -z "$available_mb" ]]; then
        log_warn "Unable to determine free disk space for $path"
        return 1
    fi

    if (( available_mb < required_mb )); then
        log_warn "Low disk space on $path: ${available_mb}MB available, ${required_mb}MB recommended"
        return 1
    fi

    log_debug "Disk space check passed for $path (${available_mb}MB available)"
    return 0
}

# ---------------------------------------------------------------------------
# common_retry <max_attempts> <sleep_seconds> -- <command...>
#   Retries a command on failure with a fixed delay between attempts.
#   Intended for transient network/package-repo failures.
#
#   Example:
#     common_retry 3 5 -- apt-get update
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# common_retry <max_attempts> <sleep_seconds> -- <command...>
#   Retries a command on failure with a fixed delay between attempts.
#   Intended for transient network/package-repo failures.
#
#   The command's own stdout/stderr are captured to a temp file rather than
#   left to print directly to the terminal. This prevents package-manager
#   output (e.g. apt-get's own progress lines) from interleaving with the
#   \r-based spinner and producing garbled console output. Captured output
#   is always appended to the log file; on final failure it is additionally
#   printed to the console so the operator sees the real error immediately,
#   without needing to open the log file separately.
#
#   Example:
#     common_retry 3 5 -- apt-get update
# ---------------------------------------------------------------------------
common_retry() {
    local max_attempts="${1:?max_attempts required}"
    local sleep_seconds="${2:?sleep_seconds required}"
    shift 2

    if [[ "${1:-}" != "--" ]]; then
        log_error "common_retry: expected -- before command"
        return 2
    fi
    shift

    local attempt=1
    local rc=0
    local out_file
    out_file="$(mktemp "${TMPDIR:-/tmp}/aws-patch-cmd.XXXXXX" 2>/dev/null || echo "/tmp/aws-patch-cmd.$$")"

    while (( attempt <= max_attempts )); do
        # IMPORTANT: rc must be captured inside the else clause. A bare
        # `if cmd; then ...; fi` with no else has an exit status of 0 when
        # the condition is false (POSIX-defined behavior), so capturing
        # "$?" *after* the fi always reads 0 -- silently masking every
        # failure. Capturing it here, still inside the conditional, is the
        # only place the real exit code of "$@" is guaranteed valid.
        if "$@" >"$out_file" 2>&1; then
            {
                echo "---- command output (attempt ${attempt}, succeeded): $* ----"
                cat "$out_file"
            } >> "$AWS_PATCH_LOG_FILE" 2>/dev/null || true
            rm -f "$out_file" 2>/dev/null || true
            return 0
        else
            rc=$?
        fi

        {
            echo "---- command output (attempt ${attempt}, exit ${rc}): $* ----"
            cat "$out_file"
        } >> "$AWS_PATCH_LOG_FILE" 2>/dev/null || true

        log_warn "Command failed (attempt ${attempt}/${max_attempts}, exit ${rc}): $*"
        if (( attempt < max_attempts )); then
            sleep "$sleep_seconds"
        fi
        (( attempt++ ))
    done

    log_error "Command failed after ${max_attempts} attempts (exit ${rc}): $*"
    if [[ -s "$out_file" ]]; then
        printf '%b---- last command output ----%b\n' "$C_DIM" "$C_RESET"
        cat "$out_file"
        printf '%b------------------------------%b\n' "$C_DIM" "$C_RESET"
    fi
    rm -f "$out_file" 2>/dev/null || true

    return "$rc"
}
