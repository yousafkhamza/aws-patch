#!/usr/bin/env bash
#
# ==============================================================================
# AWS Patch Utility - APT Module
# ==============================================================================
#
# Supported:
#   Ubuntu 20.04 / 22.04 / 24.04
#   Debian 11 / 12
#
# ==============================================================================

########################################
# Globals
########################################

APT_UPDATED=0
APT_UPGRADED=0
APT_SECURITY_UPDATES=0

########################################
# Update Package Cache
########################################

apt_update_cache() {

    run_cmd "Updating APT package cache" \
        apt update

    APT_UPDATED=1
}

########################################
# List Available Updates
########################################

apt_list_updates() {

    info "Checking available updates..."

    apt list --upgradable 2>/dev/null | tee -a "$LOG_FILE"

}

########################################
# Count Security Updates
########################################

apt_count_security_updates() {

    APT_SECURITY_UPDATES=$(
        apt list --upgradable 2>/dev/null |
        grep -c security || true
    )

    info "Security updates : ${APT_SECURITY_UPDATES}"

}

########################################
# Upgrade Packages
########################################

apt_upgrade() {

    run_cmd \
        "Installing package updates" \
        env DEBIAN_FRONTEND=noninteractive \
        apt upgrade -y

    APT_UPGRADED=1

}

########################################
# Full Upgrade
########################################

apt_full_upgrade() {

    run_cmd \
        "Installing distribution updates" \
        env DEBIAN_FRONTEND=noninteractive \
        apt full-upgrade -y

}

########################################
# Detect Installed Kernel Package
########################################

apt_detect_latest_kernel() {

    #
    # Returns newest installed kernel package.
    # Supports:
    # Ubuntu Generic
    # Ubuntu AWS
    # Ubuntu Azure
    # Ubuntu GCP
    # Debian
    #

    INSTALLED_KERNEL_PACKAGE="$(
        dpkg-query \
            -W \
            -f='${Package}\n' \
        'linux-image-*' 2>/dev/null |
        grep '^linux-image-' |
        sort -V |
        tail -1
    )"

    info "Latest installed kernel package : ${INSTALLED_KERNEL_PACKAGE}"

}

########################################
# Install Recommended Kernel Meta Packages
########################################

apt_install_kernel() {

    #
    # Install the proper meta package only
    # if already installed.
    #

    if dpkg -s linux-aws >/dev/null 2>&1; then

        run_cmd \
            "Updating AWS kernel" \
            env DEBIAN_FRONTEND=noninteractive \
            apt install --install-recommends linux-aws -y

        return

    fi

    if dpkg -s linux-generic >/dev/null 2>&1; then

        run_cmd \
            "Updating Generic kernel" \
            env DEBIAN_FRONTEND=noninteractive \
            apt install --install-recommends linux-generic -y

        return

    fi

    if dpkg -s linux-virtual >/dev/null 2>&1; then

        run_cmd \
            "Updating Virtual kernel" \
            env DEBIAN_FRONTEND=noninteractive \
            apt install --install-recommends linux-virtual -y

        return

    fi

    warn "No supported kernel meta-package detected."

}

########################################
# Cleanup
########################################

apt_cleanup() {

    run_cmd \
        "Cleaning package cache" \
        apt clean

    #
    # Intentionally DO NOT run:
    #
    # apt autoremove
    #
    # Previous kernels are retained for rollback.
    #

}

########################################
# Reboot Check
########################################

apt_check_reboot() {

    if [[ -f /var/run/reboot-required ]]; then

        REBOOT_REQUIRED=1

    else

        REBOOT_REQUIRED=0

    fi

}

########################################
# Main
########################################

run_apt_updates() {

    divider

    info "Starting APT patch process"

    divider

    apt_update_cache

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        apt_list_updates
        apt_count_security_updates
        return
    fi

    apt_list_updates

    apt_count_security_updates

    apt_upgrade

    apt_full_upgrade

    apt_install_kernel

    apt_detect_latest_kernel

    apt_cleanup

    apt_check_reboot

    success "APT patch completed"

}