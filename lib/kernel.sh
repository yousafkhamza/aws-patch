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
# Public functions:
#   kernel_get_running          -> echoes `uname -r`
#   kernel_get_latest_installed -> echoes newest installed kernel version string
#   kernel_reboot_required      -> returns 0 if reboot recommended, 1 otherwise
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
#   Human-readable summary for the final report.
# ---------------------------------------------------------------------------
kernel_summary_line() {
    if kernel_reboot_required; then
        printf 'Running: %s | Latest installed: %s | Reboot required: YES' \
            "$KERNEL_RUNNING" "$KERNEL_LATEST_INSTALLED"
    else
        printf 'Running: %s | Latest installed: %s | Reboot required: NO' \
            "$KERNEL_RUNNING" "$KERNEL_LATEST_INSTALLED"
    fi
}
