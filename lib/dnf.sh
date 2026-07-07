#!/usr/bin/env bash
#
# ==============================================================================
# AWS Patch Utility - DNF Module
# ==============================================================================
#
# Supported:
#   Amazon Linux 2023
#   RHEL 8 / 9
#   Rocky Linux 8 / 9
#   AlmaLinux 8 / 9
#
# ==============================================================================

########################################
# Globals
########################################

DNF_UPDATED=0
DNF_UPGRADED=0
DNF_SECURITY_UPDATES=0

########################################
# Wait for DNF Lock
########################################

dnf_wait_lock() {

    local timeout=300
    local waited=0

    while fuser /var/lib/rpm/.rpm.lock >/dev/null 2>&1 || \
          pgrep -f "dnf|rpm" >/dev/null 2>&1
    do

        warn "Waiting for package manager lock..."

        sleep 5

        waited=$((waited+5))

        if [[ $waited -ge $timeout ]]; then

            error "Timeout waiting for DNF lock."

            return 1

        fi

    done

}

########################################
# Refresh Metadata
########################################

dnf_update_cache() {

    dnf_wait_lock

    run_cmd \
        "Refreshing repositories" \
        dnf makecache --refresh -y

    DNF_UPDATED=1

}

########################################
# List Updates
########################################

dnf_list_updates() {

    info "Checking available updates..."

    dnf check-update | tee -a "$LOG_FILE" || true

}

########################################
# Count Security Updates
########################################

dnf_count_security_updates() {

    DNF_SECURITY_UPDATES="$(
        dnf updateinfo list security 2>/dev/null |
        grep -vc "^$" || true
    )"

    info "Security updates : ${DNF_SECURITY_UPDATES}"

}

########################################
# Upgrade Packages
########################################

dnf_upgrade() {

    run_cmd \
        "Installing updates" \
        dnf upgrade --refresh -y

    DNF_UPGRADED=1

}

########################################
# Security Only
########################################

dnf_security_upgrade() {

    run_cmd \
        "Installing security updates" \
        dnf upgrade --security -y

}

########################################
# Latest Installed Kernel
########################################

dnf_detect_latest_kernel() {

    INSTALLED_KERNEL_PACKAGE="$(
        rpm -q kernel |
        sort -V |
        tail -1
    )"

    info "Latest Installed Kernel : ${INSTALLED_KERNEL_PACKAGE}"

}

########################################
# Kernel Update Check
########################################

dnf_kernel_update() {

    if dnf list updates kernel >/dev/null 2>&1
    then

        info "Kernel update available."

    else

        info "Kernel already up to date."

    fi

}

########################################
# Cleanup
########################################

dnf_cleanup() {

    run_cmd \
        "Cleaning DNF cache" \
        dnf clean all

}

########################################
# Detect Reboot
########################################

dnf_check_reboot() {

    local running
    local newest

    running="$(uname -r)"

    newest="$(
        rpm -q kernel |
        sed 's/^kernel-//' |
        sort -V |
        tail -1
    )"

    if [[ "$running" != "$newest" ]]
    then

        REBOOT_REQUIRED=1

    else

        REBOOT_REQUIRED=0

    fi

}

########################################
# Main
########################################

run_dnf_updates() {

    divider

    info "Starting DNF Patch Process"

    divider

    dnf_update_cache

    if [[ "${DRY_RUN:-0}" == "1" ]]
    then

        dnf_list_updates

        dnf_count_security_updates

        return

    fi

    dnf_list_updates

    dnf_count_security_updates

    if [[ "${SECURITY_ONLY:-0}" == "1" ]]
    then

        dnf_security_upgrade

    else

        dnf_upgrade

    fi

    dnf_kernel_update

    dnf_detect_latest_kernel

    dnf_cleanup

    dnf_check_reboot

    success "DNF patch completed."

}