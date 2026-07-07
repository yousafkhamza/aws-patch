#!/usr/bin/env bash
# lib/yum.sh
#
# YUM-specific implementation for Amazon Linux 2, RHEL 7, and CentOS 7.
#
# Implements the pm_* function contract consumed by aws-patch.sh and
# lib/kernel.sh. No other module may call yum/rpm directly.
#
# Public functions (contract):
#   pm_name
#   pm_update_repos
#   pm_upgrade
#   pm_full_upgrade
#   pm_security_only
#   pm_install_kernel_meta
#   pm_get_installed_kernels
#   pm_get_latest_available_kernel
#   pm_list_upgradable
#   pm_count_security_updates

set -Eeuo pipefail

if [[ "${_AWS_PATCH_YUM_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_YUM_SH_LOADED="true"

pm_name() {
    echo "yum"
}

# ---------------------------------------------------------------------------
# pm_update_repos
#   `yum` doesn't require a separate metadata-refresh step the way apt
#   does -- `yum check-update` / `yum update` refresh automatically -- but
#   we explicitly clean expired cache metadata so subsequent operations
#   see current package lists.
# ---------------------------------------------------------------------------
pm_update_repos() {
    common_retry 3 5 -- yum makecache -y
}

# ---------------------------------------------------------------------------
# pm_upgrade
#   On yum-based systems, "update" is the non-destructive upgrade path
#   (yum does not distinguish upgrade vs full-upgrade the way apt does,
#   but we keep this separate from pm_full_upgrade for interface symmetry
#   and so a future distro-specific refinement has somewhere to live).
# ---------------------------------------------------------------------------
pm_upgrade() {
    common_retry 2 5 -- yum update -y
}

# ---------------------------------------------------------------------------
# pm_full_upgrade
#   Includes obsoletes processing (drops obsoleted packages' *metadata*,
#   not installed kernels -- kernel packages are never removed by this
#   tool regardless of obsoletes processing).
# ---------------------------------------------------------------------------
pm_full_upgrade() {
    common_retry 2 5 -- yum update -y --obsoletes
}

# ---------------------------------------------------------------------------
# pm_security_only
#   Requires yum-plugin-security on RHEL/CentOS 7. Amazon Linux 2 supports
#   `--security` natively via its own yum plugin set.
# ---------------------------------------------------------------------------
pm_security_only() {
    if ! rpm -q yum-plugin-security >/dev/null 2>&1 && [[ "$OS_ID" != "amzn" ]]; then
        log_warn "yum-plugin-security not installed; attempting install for security-only updates"
        common_retry 2 5 -- yum install -y yum-plugin-security || {
            log_warn "Could not install yum-plugin-security; falling back to full update"
            pm_upgrade
            return $?
        }
    fi

    common_retry 2 5 -- yum update -y --security
}

# ---------------------------------------------------------------------------
# pm_fix_broken
#   Attempts to repair a broken package/transaction state on yum-based
#   systems (Amazon Linux 2, RHEL 7, CentOS 7). Unlike apt, yum doesn't
#   normally leave "unmet dependency" errors behind since transactions are
#   resolved atomically -- but an interrupted yum run, a stale/corrupt
#   metadata cache, or duplicate package entries left over from a prior
#   partial upgrade can produce equivalent symptoms. This function only
#   cleans metadata and completes/repairs existing package state; it never
#   removes an installed kernel and never touches GRUB/bootloader config.
#
#   Invoked automatically by aws-patch.sh when --broken-fix is passed and
#   a package operation fails after exhausting its normal retries.
# ---------------------------------------------------------------------------
pm_fix_broken() {
    log_warn "Attempting automatic repair of broken package state (yum)"

    # Stale/corrupt repo metadata is the most common cause of spurious
    # dependency resolution failures; clear it first.
    common_retry 1 0 -- yum clean all || true

    # Finish any transaction left incomplete by an interrupted prior run.
    if utils_command_exists yum-complete-transaction; then
        common_retry 1 0 -- yum-complete-transaction --cleanup-only || true
    fi

    # Remove duplicate package entries (a common side effect of interrupted
    # kernel upgrades) if yum-utils is available. This only deduplicates
    # existing entries; it does not remove distinct installed kernels.
    if utils_command_exists package-cleanup; then
        common_retry 1 0 -- package-cleanup --cleandupes -y || true
    fi

    # Refresh metadata and retry, allowing yum to skip packages it truly
    # cannot resolve rather than aborting the whole transaction. This is
    # the least destructive repair path available; it never force-removes
    # packages this tool didn't already intend to touch.
    common_retry 2 5 -- yum update -y --skip-broken
}

# ---------------------------------------------------------------------------
# pm_install_kernel_meta
#   Ensures the latest kernel package is installed. On Amazon Linux 2 this
#   is "kernel"; on RHEL7/CentOS7 also "kernel". We never uninstall older
#   kernel packages -- yum's default installonly_limit behavior (which can
#   prune old kernels) is explicitly overridden to preserve rollback
#   capability, per this project's safety requirements.
# ---------------------------------------------------------------------------
pm_install_kernel_meta() {
    log_debug "Ensuring latest kernel package is installed (installonly_limit preserved, no pruning)"

    # Force installonly_limit=0 (unlimited) for this invocation only, so a
    # system-wide yum.conf setting can never cause old kernels to be culled
    # as a side effect of this tool's run.
    common_retry 2 5 -- yum install -y --setopt=installonly_limit=0 kernel
}

# ---------------------------------------------------------------------------
# pm_get_installed_kernels
#   Read-only: lists installed kernel package versions.
# ---------------------------------------------------------------------------
pm_get_installed_kernels() {
    rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V
}

# ---------------------------------------------------------------------------
# pm_get_latest_available_kernel
#   Read-only, predictive: echoes the newest kernel version currently
#   known to yum, whether or not it's installed yet. Lets
#   --check/--dry-run reveal that a live patch run WILL require a reboot
#   before any packages are touched. Never installs or removes anything.
#
#   Collects kernel version candidates from every source below
#   unconditionally, then picks the true highest across all of them --
#   different yum configurations/repo setups surface available kernel
#   builds differently, so the more sources checked, the less likely a
#   real update is missed:
#     - `yum list kernel --showduplicates` (deliberately WITHOUT an
#       "available"-only filter, which is not reliably supported the
#       same way across all yum configurations; this lists every kernel
#       build yum knows about, both installed and available)
#     - `yum check-update kernel` (explicit update-check output)
#   If the highest version found happens to already be installed,
#   kernel_update_available (lib/kernel.sh) correctly reports no update
#   needed; this function only reports the ceiling of what's known, never
#   a judgment about install state.
#   Output is normalized to match pm_get_installed_kernels' format
#   ("<version>-<release>.<arch>") so the two are directly comparable.
# ---------------------------------------------------------------------------
pm_get_latest_available_kernel() {
    local candidates ver

    candidates="$(yum list kernel --showduplicates -q 2>/dev/null \
        | awk '/^kernel\.[a-zA-Z0-9_]+/ {print $2}' || true)"
    candidates+=$'\n'
    candidates+="$(yum check-update kernel -q 2>&1 \
        | awk '/^kernel\.[a-zA-Z0-9_]+/ {print $2}' || true)"

    ver="$(printf '%s\n' "$candidates" | grep -E '.' | sort -V | tail -n1 || true)"

    if [[ -n "$ver" ]]; then
        printf '%s.%s' "$ver" "${ARCH:-$(uname -m)}"
    fi
}

# ---------------------------------------------------------------------------
# pm_list_upgradable
# ---------------------------------------------------------------------------
pm_list_upgradable() {
    yum check-update -q 2>/dev/null | grep -Ev '^(Loaded plugins|$)' || true
}

# ---------------------------------------------------------------------------
# pm_count_security_updates
# ---------------------------------------------------------------------------
pm_count_security_updates() {
    local count
    count="$(yum updateinfo list security 2>/dev/null | grep -c '.' || true)"
    echo "${count:-0}"
}
