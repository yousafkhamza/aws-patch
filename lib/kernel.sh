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
# Read-only inspection of the current GRUB default (e.g. `grubby
# --default-kernel`) is fine -- it's writes that are forbidden, so that
# a --reboot can be sanity-checked against reality before it happens.
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
#                                   (also sets KERNEL_INSTALL_INCOMPLETE if the
#                                   "latest installed" kernel's boot files are
#                                   missing from /boot -- see
#                                   _kernel_boot_files_present below -- and
#                                   KERNEL_BOOT_DEFAULT_MISMATCH if the boot
#                                   files exist but GRUB's current default
#                                   doesn't point at them, where verifiable --
#                                   see _kernel_grub_default_matches below)
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
# _kernel_boot_files_present <version>
#   Private helper (not part of the pm_* or kernel_* public contract).
#   Sanity-checks that a kernel version the package manager reports as
#   "installed" actually has a bootable vmlinuz file on disk at
#   /boot/vmlinuz-<version> -- the exact file GRUB/BLS boot entries point
#   at, and the same naming convention used by every supported distro
#   (Debian/Ubuntu and every RPM-based family: Amazon Linux, RHEL, Rocky,
#   AlmaLinux, CentOS). Returns 0 if present, 1 if missing.
#
#   This exists because a package manager's own database can end up
#   recording a kernel as "installed" when its actual files were never
#   written -- most commonly a kernel transaction interrupted partway
#   through (Ctrl+C/Ctrl+Z, an OOM kill, a lost SSH session). Without
#   this check, aws-patch would report "reboot required" for a kernel
#   that physically cannot be booted into -- a reboot would just return
#   to the exact same running kernel, and an administrator has no way to
#   tell that from the summary alone.
# ---------------------------------------------------------------------------
_kernel_boot_files_present() {
    local version="$1"
    [[ -n "$version" ]] || return 1
    [[ -e "${AWS_PATCH_BOOT_DIR:-/boot}/vmlinuz-${version}" ]]
}

# ---------------------------------------------------------------------------
# _kernel_grub_default_matches <version>
#   Private helper. Read-only GRUB inspection ONLY (see file header) --
#   asks `grubby` what the current default boot entry is and compares it
#   against the kernel version we expect a reboot to load. This is the
#   check that would have caught the exact real-world failure this
#   function exists for: a kernel installs cleanly with real boot files
#   present, but the automatic scriptlet chain that's supposed to also
#   set it as the default boot entry doesn't complete -- so a reboot
#   silently restarts into the SAME kernel that's already running, and
#   nothing about the summary would otherwise reveal that in advance.
#
#   Only reliably verifiable where `grubby` is present (RHEL-family:
#   Amazon Linux, RHEL, Rocky, AlmaLinux, CentOS -- standard tooling
#   there). Debian/Ubuntu doesn't ship a grubby equivalent by default;
#   rather than guess by parsing grub.cfg (fragile, distro-version
#   dependent, and a false positive here would block a perfectly good
#   reboot), this is left unverifiable there and never blocks anything.
#
#   Echoes one of: "match" (default already points at $version),
#   "mismatch" (default points elsewhere -- reboot would not help),
#   "unknown" (grubby unavailable or its output couldn't be parsed --
#   nothing to act on either way).
# ---------------------------------------------------------------------------
_kernel_grub_default_matches() {
    local version="$1"
    local default_path

    if ! command -v grubby >/dev/null 2>&1; then
        printf 'unknown'
        return 0
    fi

    default_path="$(grubby --default-kernel 2>/dev/null || true)"
    if [[ -z "$default_path" ]]; then
        printf 'unknown'
        return 0
    fi

    if [[ "$default_path" == "${AWS_PATCH_BOOT_DIR:-/boot}/vmlinuz-${version}" ]]; then
        printf 'match'
    else
        printf 'mismatch'
    fi
}

# ---------------------------------------------------------------------------
# kernel_reboot_required
#   Returns 0 (true) if the running kernel differs from the latest
#   installed kernel, 1 (false) otherwise. Sets globals:
#     KERNEL_RUNNING, KERNEL_LATEST_INSTALLED, KERNEL_REBOOT_REQUIRED,
#     KERNEL_INSTALL_INCOMPLETE, KERNEL_BOOT_DEFAULT_MISMATCH
# ---------------------------------------------------------------------------
kernel_reboot_required() {
    KERNEL_RUNNING="$(kernel_get_running)"
    KERNEL_LATEST_INSTALLED="$(kernel_get_latest_installed)"
    export KERNEL_RUNNING KERNEL_LATEST_INSTALLED

    # Integrity check: if the package manager thinks a different kernel
    # is installed but that kernel has no boot files on disk, this is a
    # stale/phantom database entry -- not a real pending kernel. Flag it
    # distinctly so the summary and reboot messaging can tell the truth
    # instead of recommending a reboot that cannot possibly help.
    KERNEL_INSTALL_INCOMPLETE="false"
    if [[ "$KERNEL_RUNNING" != "$KERNEL_LATEST_INSTALLED" ]] \
        && ! _kernel_boot_files_present "$KERNEL_LATEST_INSTALLED"; then
        KERNEL_INSTALL_INCOMPLETE="true"
        log_warn "Kernel ${KERNEL_LATEST_INSTALLED} is recorded as installed, but ${AWS_PATCH_BOOT_DIR:-/boot}/vmlinuz-${KERNEL_LATEST_INSTALLED} does not exist."
        log_warn "This is a stale package-database entry (usually from an interrupted kernel transaction) -- rebooting will NOT load this kernel."
        log_warn "See docs/troubleshooting.md#stale-kernel-database-entry for how to clear it."
    fi
    export KERNEL_INSTALL_INCOMPLETE

    # Second, distinct risk check: boot files DO exist, but is GRUB's
    # current default actually set to boot them? Only evaluated when
    # there's a real pending kernel to check in the first place (not a
    # stale entry, and a version mismatch actually exists) -- and only
    # acted on where verifiable (see _kernel_grub_default_matches).
    KERNEL_BOOT_DEFAULT_MISMATCH="false"
    if [[ "$KERNEL_RUNNING" != "$KERNEL_LATEST_INSTALLED" ]] \
        && ! utils_is_true "$KERNEL_INSTALL_INCOMPLETE"; then
        case "$(_kernel_grub_default_matches "$KERNEL_LATEST_INSTALLED")" in
            mismatch)
                KERNEL_BOOT_DEFAULT_MISMATCH="true"
                log_warn "Kernel ${KERNEL_LATEST_INSTALLED} is installed, but GRUB's current default boot entry does not point at it."
                log_warn "Rebooting now would very likely restart into the exact same kernel that's already running."
                log_warn "aws-patch never modifies GRUB -- set the default yourself first: sudo grubby --set-default ${AWS_PATCH_BOOT_DIR:-/boot}/vmlinuz-${KERNEL_LATEST_INSTALLED}"
                log_warn "See docs/troubleshooting.md#grub-default-not-updated-to-the-new-kernel for details."
                ;;
        esac
    fi
    export KERNEL_BOOT_DEFAULT_MISMATCH

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
        if utils_is_true "${KERNEL_INSTALL_INCOMPLETE:-false}"; then
            line="Running: ${KERNEL_RUNNING} | Latest installed: ${KERNEL_LATEST_INSTALLED} | Reboot required: STALE ENTRY (boot files missing, reboot won't help)"
        elif utils_is_true "${KERNEL_BOOT_DEFAULT_MISMATCH:-false}"; then
            line="Running: ${KERNEL_RUNNING} | Latest installed: ${KERNEL_LATEST_INSTALLED} | Reboot required: GRUB DEFAULT MISMATCH (reboot won't load it -- see below)"
        else
            line="Running: ${KERNEL_RUNNING} | Latest installed: ${KERNEL_LATEST_INSTALLED} | Reboot required: YES"
        fi
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
