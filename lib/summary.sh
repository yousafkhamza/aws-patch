#!/usr/bin/env bash
#
# ==============================================================================
# AWS Patch Utility - Summary Module
# ==============================================================================

########################################
# Globals
########################################

PATCH_STATUS="SUCCESS"

########################################
# Line
########################################

summary_line() {

    printf "%-24s : %s\n" "$1" "$2"

}

########################################
# Header
########################################

summary_header() {

    divider

    echo "                 PATCH SUMMARY"

    divider

}

########################################
# Kernel Status
########################################

summary_kernel() {

    summary_line "Running Kernel" "$CURRENT_KERNEL"

    summary_line "Installed Kernel" "$LATEST_KERNEL"

    if [[ "$REBOOT_REQUIRED" -eq 1 ]]
    then
        summary_line "Kernel Updated" "YES"
    else
        summary_line "Kernel Updated" "NO"
    fi

}

########################################
# Package Status
########################################

summary_packages() {

    case "$PKG_MANAGER" in

        apt)

            summary_line "Package Manager" "APT"

            summary_line "Security Updates" "${APT_SECURITY_UPDATES:-0}"

            ;;

        yum)

            summary_line "Package Manager" "YUM"

            summary_line "Security Updates" "${YUM_SECURITY_UPDATES:-0}"

            ;;

        dnf)

            summary_line "Package Manager" "DNF"

            summary_line "Security Updates" "${DNF_SECURITY_UPDATES:-0}"

            ;;

    esac

}

########################################
# System
########################################

summary_system() {

    summary_line "Hostname" "$HOSTNAME"

    summary_line "Operating System" "$OS_NAME"

    summary_line "Architecture" "$ARCH"

}

########################################
# Reboot
########################################

summary_reboot() {

    if [[ "$REBOOT_REQUIRED" -eq 1 ]]
    then

        warn "Reboot Required"

        echo

        echo "A newer kernel has been installed."

        echo "The running kernel will remain active until reboot."

    else

        success "No reboot required."

    fi

}

########################################
# Log
########################################

summary_log() {

    summary_line "Log File" "$LOG_FILE"

}

########################################
# Footer
########################################

summary_footer() {

    divider

    if [[ "$PATCH_STATUS" == "SUCCESS" ]]
    then

        success "Patch completed successfully."

    else

        error "Patch finished with errors."

    fi

    echo

}

########################################
# Recovery Information
########################################

summary_recovery() {

cat <<EOF

Recovery Recommendations

 • Previous kernels were retained.

 • GRUB configuration was not modified.

 • If the instance fails after reboot:

     1. Use EC2 Serial Console (if enabled)

     2. Or stop the instance

     3. Detach the root EBS volume

     4. Attach it to a rescue EC2 instance

     5. Repair or restore configuration

     6. Reattach the volume

 • If an AMI was created before patching,
   launch a replacement instance if necessary.

EOF

}

########################################
# Main
########################################

print_summary() {

    summary_header

    summary_system

    echo

    summary_packages

    echo

    summary_kernel

    echo

    summary_log

    echo

    summary_reboot

    summary_footer

    summary_recovery

}