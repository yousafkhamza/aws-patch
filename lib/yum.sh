#!/usr/bin/env bash
#
# ==============================================================================
# AWS Patch Utility - YUM Module
# ==============================================================================
#
# Supported:
#   - Amazon Linux 2
#   - RHEL 7
#   - CentOS 7
#
# ==============================================================================

########################################
# Globals
########################################

YUM_UPDATED=0
YUM_UPGRADED=0
YUM_SECURITY_UPDATES=0

########################################
# Wait for Yum Lock
########################################

yum_wait_lock() {

    local timeout=300
    local waited=0

    while pgrep -f "yum|rpm|dnf" >/dev/null 2>&1
    do
        warn "Another package manager is running. Waiting..."

        sleep 5

        waited=$((waited+5))

        if [[ $waited -ge $timeout ]]; then
            error "Timeout waiting for yum lock."
            return 1
        fi
    done
}

########################################
# Update Metadata
########################################

yum_update_cache() {

    yum_wait_lock

    run_cmd \
        "Refreshing yum metadata" \
        yum makecache -y

    YUM_UPDATED=1
}

########################################
# List Updates
########################################

yum_list_updates() {

    info "Checking available updates..."

    yum check-update | tee -a "$LOG_FILE" || true

}

########################################
# Count Security Updates
########################################

yum_count_security_updates() {

    if yum updateinfo summary >/dev/null 2>&1; then

        YUM_SECURITY_UPDATES=$(
            yum updateinfo summary |
            awk '/Security/ {print $2}' |
            head -1
        )

    else

        YUM_SECURITY_UPDATES="Unknown"

    fi

    info "Security updates : ${YUM_SECURITY_UPDATES}"

}

########################################
# Upgrade Packages
########################################

yum_upgrade() {

    run_cmd \
        "Installing package updates" \
        yum update -y

    YUM_UPGRADED=1
}

########################################
# Detect Latest Installed Kernel
########################################

yum_detect_latest_kernel() {

    INSTALLED_KERNEL_PACKAGE="$(
        rpm -q kernel |
        sort -V |
        tail -1
    )"

    info "Latest installed kernel : ${INSTALLED_KERNEL_PACKAGE}"

}

########################################
# Check Kernel Update
########################################

yum_kernel_update() {

    if yum list updates kernel >/dev/null 2>&1; then

        info "Kernel update available."

    else

        info "Kernel already up to date."

    fi

}

########################################
# Cleanup
########################################

yum_cleanup() {

    run_cmd \
        "Cleaning yum cache" \
        yum clean all

}

########################################
# Reboot Detection
########################################

yum_check_reboot() {

    local running
    local newest

    running="$(uname -r)"

    newest="$(
        rpm -q kernel |
        sed 's/^kernel-//' |
        sort -V |
        tail -1
    )"

    if [[ "$running" != "$newest" ]]; then

        REBOOT_REQUIRED=1

    else

        REBOOT_REQUIRED=0

    fi

}

########################################
# Main
########################################

run_yum_updates() {

    divider

    info "Starting YUM patch process"

    divider

    yum_update_cache

    if [[ "${DRY_RUN:-0}" == "1" ]]; then

        yum_list_updates

        yum_count_security_updates

        return

    fi

    yum_list_updates

    yum_count_security_updates

    yum_upgrade

    yum_kernel_update

    yum_detect_latest_kernel

    yum_cleanup

    yum_check_reboot

    success "YUM patch completed."

}