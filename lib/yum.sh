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
