#!/usr/bin/env bash
# lib/dnf.sh
#
# DNF-specific implementation for Amazon Linux 2023, RHEL 8/9, Rocky Linux,
# and AlmaLinux.
#
# Implements the pm_* function contract consumed by aws-patch.sh and
# lib/kernel.sh. No other module may call dnf/rpm directly.
#
# Public functions (contract):
#   pm_name
#   pm_update_repos
#   pm_upgrade
#   pm_full_upgrade
#   pm_security_only
#   pm_install_kernel_meta
#   pm_get_installed_kernels
#   pm_list_upgradable
#   pm_count_security_updates

set -Eeuo pipefail

if [[ "${_AWS_PATCH_DNF_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_DNF_SH_LOADED="true"

pm_name() {
    echo "dnf"
}

# ---------------------------------------------------------------------------
# pm_update_repos
# ---------------------------------------------------------------------------
pm_update_repos() {
    common_retry 3 5 -- dnf makecache -y
}

# ---------------------------------------------------------------------------
# pm_upgrade
# ---------------------------------------------------------------------------
pm_upgrade() {
    common_retry 2 5 -- dnf upgrade -y
}

# ---------------------------------------------------------------------------
# pm_full_upgrade
#   `dnf upgrade` already handles obsoletes by default; --best ensures the
#   highest available versions are chosen rather than partial updates.
# ---------------------------------------------------------------------------
pm_full_upgrade() {
    common_retry 2 5 -- dnf upgrade -y --best --allowerasing
}

# ---------------------------------------------------------------------------
# pm_security_only
#   Native dnf security filtering (no extra plugin needed, unlike yum on
#   RHEL/CentOS 7).
# ---------------------------------------------------------------------------
pm_security_only() {
    if dnf updateinfo --security --assumeno >/dev/null 2>&1 || true; then
        common_retry 2 5 -- dnf upgrade -y --security
    else
        log_warn "dnf security metadata unavailable; falling back to full upgrade"
        pm_upgrade
    fi
}

# ---------------------------------------------------------------------------
# pm_install_kernel_meta
#   Ensures the latest kernel package is installed. installonly_limit is
#   explicitly overridden to 0 (unlimited) for this invocation so old
#   kernels are never pruned as a side effect, preserving rollback
#   capability per this project's safety requirements.
# ---------------------------------------------------------------------------
pm_install_kernel_meta() {
    log_debug "Ensuring latest kernel package is installed (installonly_limit preserved, no pruning)"

    local kernel_pkg="kernel"
    if [[ "$OS_ID" == "amzn" ]]; then
        kernel_pkg="kernel"
    fi

    common_retry 2 5 -- dnf install -y --setopt=installonly_limit=0 "$kernel_pkg"
}

# ---------------------------------------------------------------------------
# pm_get_installed_kernels
#   Read-only: lists installed kernel package versions.
# ---------------------------------------------------------------------------
pm_get_installed_kernels() {
    rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V
}

# ---------------------------------------------------------------------------
# pm_list_upgradable
# ---------------------------------------------------------------------------
pm_list_upgradable() {
    dnf check-update -q 2>/dev/null | grep -Ev '^(Last metadata|$)' || true
}

# ---------------------------------------------------------------------------
# pm_count_security_updates
# ---------------------------------------------------------------------------
pm_count_security_updates() {
    local count
    count="$(dnf updateinfo list security 2>/dev/null | grep -c '.' || true)"
    echo "${count:-0}"
}
