#!/usr/bin/env bash
# lib/kernel.sh
#
# Kernel version comparison logic ONLY.
#
# This file must NEVER:
#   - modify GRUB or any bootloader configuration
#   - call grub2-set-default, grub2-reboot, update-grub, or similar
#   - remove/purge any installed kernel package
#   - change the default boot entry
#
# It answers exactly one question: is the currently running kernel the
# same as the newest kernel installed on disk? If not, a reboot is
# recommended -- and only recommended. The administrator decides.
#
# Package-manager-specific discovery of "what kernels are installed" is
# delegated to a function each pm module (apt.sh/yum.sh/dnf.sh) must
# implement: pm_get_installed_kernels. This file only consumes that
# output; it never runs apt/yum/dnf commands itself.
#
# It also, separately and read-only, answers a second, predictive
# question via an OPTIONAL pm_get_latest_available_kernel function: what
# is the newest kernel version currently offered by the repo, whether or
# not it's installed yet? This lets --check/--dry-run reveal that
# patching WILL require a reboot before any packages are actually
# touched -- rather than only being able to say so after the fact, once
# the newer kernel is already installed. If a pm module doesn't
# implement this optional function, the predictive check is silently
# skipped; it never blocks or fails the run.
#
# Public functions:
#   kernel_get_running          -> echoes `uname -r`
#   kernel_get_latest_installed -> echoes newest installed kernel version string
#   kernel_get_latest_available -> echoes newest kernel version offered by the
#                                   repo (installed or not); empty if unknown
#   kernel_reboot_required      -> returns 0 if reboot recommended, 1 otherwise
#   kernel_update_available     -> returns 0 if a newer kernel than what's
#                                   currently installed is available in the repo
#   kernel_summary_line         -> echoes a human-readable one-line summary

set -Eeuo pipefail

if [[ "${_AWS_PATCH_KERNEL_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_KERNEL_SH_LOADED="true"

# ---------------------------------------------------------------------------
# kernel_get_running
# ---------------------------------------------------------------------------
kernel_get_running() {
    uname -r
}

# ---------------------------------------------------------------------------
# kernel_get_latest_installed
#   Delegates enumeration to pm_get_installed_kernels (provided by the
#   active pm module: apt.sh, yum.sh, or dnf.sh), then picks the highest
#   version using sort -V. This function contains zero pm-specific logic.
# ---------------------------------------------------------------------------
kernel_get_latest_installed() {
    if ! declare -F pm_get_installed_kernels >/dev/null 2>&1; then
        log_error "pm_get_installed_kernels is not defined; a pm module must be loaded first"
        return 1
    fi

    local kernels
    kernels="$(pm_get_installed_kernels || true)"

    if [[ -z "$kernels" ]]; then
        log_warn "No installed kernel versions could be enumerated; falling back to running kernel"
        kernel_get_running
        return 0
    fi

    printf '%s\n' "$kernels" | sort -V | tail -n1
}

# ---------------------------------------------------------------------------
# kernel_get_latest_available
#   Delegates to the OPTIONAL pm_get_latest_available_kernel (provided by
#   apt.sh/yum.sh/dnf.sh when implemented). Read-only: queries what the
#   repo currently offers without installing anything. Echoes nothing
#   (and returns 1) if the active pm module doesn't implement this, or if
#   it couldn't determine an answer -- callers must treat that as "unknown",
#   not "no update available".
# ---------------------------------------------------------------------------
kernel_get_latest_available() {
    if ! declare -F pm_get_latest_available_kernel >/dev/null 2>&1; then
        return 1
    fi

    local latest
    latest="$(pm_get_latest_available_kernel 2>/dev/null || true)"

    if [[ -z "$latest" ]]; then
        return 1
    fi

    printf '%s' "$latest"
}

# ---------------------------------------------------------------------------
# kernel_update_available
#   Predictive check: is a newer kernel than what's currently installed
#   available from the repo right now? This is what lets --check/--dry-run
#   reveal that a live patch run WILL require a reboot, before any
#   packages are touched. Sets KERNEL_LATEST_AVAILABLE when known.
#   Returns 0 if a newer kernel is available, 1 if not available or
#   unknown (e.g. pm module doesn't implement the optional query).
# ---------------------------------------------------------------------------
kernel_update_available() {
    local latest_available
    latest_available="$(kernel_get_latest_available)" || return 1

    KERNEL_LATEST_AVAILABLE="$latest_available"
    export KERNEL_LATEST_AVAILABLE

    local latest_installed
    latest_installed="$(kernel_get_latest_installed)"

    utils_version_gt "$latest_available" "$latest_installed"
}

# ---------------------------------------------------------------------------
# kernel_reboot_required
#   Returns 0 (true) if the running kernel differs from the latest
#   installed kernel, 1 (false) otherwise. Sets globals:
#     KERNEL_RUNNING, KERNEL_LATEST_INSTALLED, KERNEL_REBOOT_REQUIRED
# ---------------------------------------------------------------------------
kernel_reboot_required() {
    KERNEL_RUNNING="$(kernel_get_running)"
    KERNEL_LATEST_INSTALLED="$(kernel_get_latest_installed)"
    export KERNEL_RUNNING KERNEL_LATEST_INSTALLED

    # Also respect the distro-native indicator when available, since
    # version-string comparison alone can be unreliable across kernel
    # naming schemes (e.g. Amazon Linux kernel-5.10 vs kernel-5.10-longterm).
    local native_flag="false"
    if [[ -x /usr/bin/needs-restarting ]]; then
        # RHEL-family: `needs-restarting -r` exits 1 if a reboot is required.
        if ! /usr/bin/needs-restarting -r >/dev/null 2>&1; then
            native_flag="true"
        fi
    elif [[ -e /var/run/reboot-required ]]; then
        # Debian-family: apt leaves this marker file after a kernel upgrade.
        native_flag="true"
    fi

    if [[ "$KERNEL_RUNNING" != "$KERNEL_LATEST_INSTALLED" ]] || utils_is_true "$native_flag"; then
        KERNEL_REBOOT_REQUIRED="true"
        export KERNEL_REBOOT_REQUIRED
        return 0
    else
        KERNEL_REBOOT_REQUIRED="false"
        export KERNEL_REBOOT_REQUIRED
        return 1
    fi
}

# ---------------------------------------------------------------------------
# kernel_summary_line
#   Human-readable summary for the final report. Includes the predictive
#   "available" kernel only when the active pm module can determine it.
# ---------------------------------------------------------------------------
kernel_summary_line() {
    local line
    if kernel_reboot_required; then
        line="Running: ${KERNEL_RUNNING} | Latest installed: ${KERNEL_LATEST_INSTALLED} | Reboot required: YES"
    else
        line="Running: ${KERNEL_RUNNING} | Latest installed: ${KERNEL_LATEST_INSTALLED} | Reboot required: NO"
    fi

    if kernel_update_available; then
        if utils_is_true "${KERNEL_REBOOT_REQUIRED:-false}"; then
            line="${line} | Available: ${KERNEL_LATEST_AVAILABLE}"
        else
            line="${line} | Available: ${KERNEL_LATEST_AVAILABLE} (patching would require a reboot)"
        fi
    fi

    printf '%s' "$line"
}
