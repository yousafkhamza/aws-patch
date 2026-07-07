#!/usr/bin/env bash
# lib/apt.sh
#
# APT-specific implementation for Ubuntu (20.04/22.04/24.04) and Debian (11/12).
# Supports Ubuntu Generic, Ubuntu AWS, and Ubuntu Virtual kernel flavors.
#
# Implements the pm_* function contract consumed by aws-patch.sh and
# lib/kernel.sh. No other module may call apt-get/dpkg directly.
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

if [[ "${_AWS_PATCH_APT_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_APT_SH_LOADED="true"

export DEBIAN_FRONTEND=noninteractive
readonly APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y)

pm_name() {
    echo "apt"
}

# ---------------------------------------------------------------------------
# pm_update_repos
#   Refreshes package indexes. Retries transient network failures.
# ---------------------------------------------------------------------------
pm_update_repos() {
    common_retry 3 5 -- apt-get update -q
}

# ---------------------------------------------------------------------------
# pm_upgrade
#   Standard upgrade: never removes packages to satisfy dependencies.
# ---------------------------------------------------------------------------
pm_upgrade() {
    common_retry 2 5 -- apt-get "${APT_OPTS[@]}" upgrade
}

# ---------------------------------------------------------------------------
# pm_full_upgrade
#   Equivalent to `apt full-upgrade` / old `dist-upgrade`: allowed to add
#   or remove packages as needed to resolve upgrades (e.g. new kernel
#   metapackages superseding old ones). Never touches GRUB or boot order --
#   that is a bootloader concern this project explicitly never automates.
# ---------------------------------------------------------------------------
pm_full_upgrade() {
    common_retry 2 5 -- apt-get "${APT_OPTS[@]}" full-upgrade
}

# ---------------------------------------------------------------------------
# pm_security_only
#   Installs updates only from the distro's -security pocket/suite.
#   Works for both Ubuntu (<codename>-security) and Debian (<codename>-security).
# ---------------------------------------------------------------------------
pm_security_only() {
    local codename
    codename="$(source /etc/os-release && echo "${VERSION_CODENAME:-}")"

    if [[ -z "$codename" ]]; then
        log_warn "Could not determine VERSION_CODENAME; falling back to full upgrade for security packages"
        pm_upgrade
        return $?
    fi

    log_debug "Applying security-only updates for suite: ${codename}-security"
    common_retry 2 5 -- apt-get "${APT_OPTS[@]}" \
        -t "${codename}-security" upgrade
}

# ---------------------------------------------------------------------------
# pm_install_kernel_meta
#   Ensures the latest kernel metapackage for the running flavor is
#   installed (generic / aws / virtual / cloud). Detecting the flavor from
#   the currently running kernel package name keeps this correct across
#   Ubuntu Generic, Ubuntu AWS, and Ubuntu Virtual, as well as Debian.
# ---------------------------------------------------------------------------
pm_install_kernel_meta() {
    local running_pkg flavor meta_pkg

    running_pkg="$(dpkg -S "/boot/vmlinuz-$(uname -r)" 2>/dev/null | cut -d: -f1 || true)"

    if [[ "$running_pkg" == *-aws ]]; then
        flavor="aws"
    elif [[ "$running_pkg" == *-virtual ]]; then
        flavor="virtual"
    elif [[ "$running_pkg" == *-cloud-* ]]; then
        flavor="cloud"
    else
        flavor="generic"
    fi

    case "$OS_ID" in
        ubuntu)
            meta_pkg="linux-${flavor}"
            ;;
        debian)
            meta_pkg="linux-image-${flavor}"
            # Debian doesn't ship an "aws" flavor metapackage on all releases;
            # fall back to the plain amd64/arm64 image metapackage.
            if ! apt-cache show "$meta_pkg" >/dev/null 2>&1; then
                meta_pkg="linux-image-${ARCH}"
            fi
            ;;
        *)
            meta_pkg="linux-generic"
            ;;
    esac

    log_debug "Installing/ensuring latest kernel metapackage: $meta_pkg"
    common_retry 2 5 -- apt-get "${APT_OPTS[@]}" install --only-upgrade "$meta_pkg" \
        || common_retry 2 5 -- apt-get "${APT_OPTS[@]}" install "$meta_pkg"
}

# ---------------------------------------------------------------------------
# pm_fix_broken
#   Attempts to repair a broken/unmet-dependency package state, e.g.:
#     "E: Unmet dependencies. Try 'apt --fix-broken install' ..."
#   which typically happens when a prior upgrade was interrupted or a
#   versioned metapackage (like linux-headers-<ver>) was left pointing at
#   a package version no longer available.
#
#   Only ever repairs and reconfigures existing package state; never
#   removes kernels and never touches GRUB/bootloader configuration.
#   Invoked automatically by aws-patch.sh when --broken-fix is passed and
#   a package operation fails after exhausting its normal retries.
# ---------------------------------------------------------------------------
pm_fix_broken() {
    log_warn "Attempting automatic repair of broken package state (apt)"

    # Finish configuring any package left half-installed by an interrupted
    # prior run before touching dependency resolution.
    common_retry 1 0 -- dpkg --configure -a || true

    # Let apt's own dependency resolver fix unmet dependencies. This can
    # install or upgrade packages as needed to reach a consistent state,
    # but never removes an installed kernel package as a side effect --
    # apt's --fix-broken only resolves dependency graphs, it doesn't prune
    # unrelated packages.
    common_retry 2 5 -- apt-get "${APT_OPTS[@]}" --fix-broken install
}

# ---------------------------------------------------------------------------
# pm_get_installed_kernels
#   Lists installed kernel image versions (one per line), consumed by
#   lib/kernel.sh. Never removes anything; read-only query.
# ---------------------------------------------------------------------------
pm_get_installed_kernels() {
    dpkg-query -W -f='${Package} ${Version}\n' 'linux-image-*' 2>/dev/null \
        | awk '$1 ~ /^linux-image-[0-9]/ {print $1}' \
        | sed -E 's/^linux-image-//' \
        | sort -V
}

# ---------------------------------------------------------------------------
# pm_list_upgradable
#   Read-only: lists packages with available upgrades.
# ---------------------------------------------------------------------------
pm_list_upgradable() {
    apt list --upgradable 2>/dev/null | grep -v '^Listing' || true
}

# ---------------------------------------------------------------------------
# pm_count_security_updates
#   Read-only count of packages upgradable from a -security suite.
# ---------------------------------------------------------------------------
pm_count_security_updates() {
    local codename count
    codename="$(source /etc/os-release && echo "${VERSION_CODENAME:-}")"
    count="$(apt-get -s upgrade -o Debug::NoLocking=true 2>/dev/null \
        | grep -c "${codename}-security" || true)"
    echo "${count:-0}"
}
