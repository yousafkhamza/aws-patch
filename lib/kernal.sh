#!/usr/bin/env bash
#
# ==============================================================================
# AWS Patch Utility - Kernel Module
# ==============================================================================
#
# Responsibilities
#
#   • Detect current running kernel
#   • Detect newest installed kernel
#   • Compare versions
#   • Detect reboot requirement
#   • Never modify GRUB
#   • Never delete old kernels
#
# ==============================================================================

########################################
# Globals
########################################

CURRENT_KERNEL=""
LATEST_KERNEL=""
KERNEL_CHANGED=0
REBOOT_REQUIRED=0

########################################
# Running Kernel
########################################

kernel_running() {

    CURRENT_KERNEL="$(uname -r)"

}

########################################
# Latest Installed Kernel
########################################

kernel_latest() {

    case "${PKG_MANAGER}" in

        apt)

            LATEST_KERNEL="$(
                dpkg-query \
                    -W \
                    -f='${Package}\n' \
                    'linux-image-*' 2>/dev/null |
                grep '^linux-image-' |
                sort -V |
                tail -1 |
                sed 's/^linux-image-//'
            )"

            ;;

        yum|dnf)

            LATEST_KERNEL="$(
                rpm -q kernel 2>/dev/null |
                sed 's/^kernel-//' |
                sort -V |
                tail -1
            )"

            ;;

        *)

            warn "Kernel detection is not supported for package manager: ${PKG_MANAGER}"
            return 1
            ;;

    esac

}

########################################
# Compare
########################################

kernel_compare() {

    kernel_running

    kernel_latest

    info "Running Kernel : ${CURRENT_KERNEL}"
    info "Latest Kernel  : ${LATEST_KERNEL}"

    if [[ -z "${LATEST_KERNEL}" ]]; then

        warn "Unable to determine latest installed kernel."

        REBOOT_REQUIRED=0
        KERNEL_CHANGED=0

        return

    fi

    if [[ "${CURRENT_KERNEL}" == "${LATEST_KERNEL}" ]]; then

        success "System is running the latest installed kernel."

        REBOOT_REQUIRED=0
        KERNEL_CHANGED=0

    else

        warn "A newer installed kernel is available."

        REBOOT_REQUIRED=1
        KERNEL_CHANGED=1

    fi

}

########################################
# Kernel Information
########################################

kernel_info() {

    divider

    echo "Running Kernel : ${CURRENT_KERNEL}"
    echo "Installed      : ${LATEST_KERNEL}"

    if [[ "${REBOOT_REQUIRED}" -eq 1 ]]; then
        echo "Reboot         : Required"
    else
        echo "Reboot         : Not Required"
    fi

    divider

}

########################################
# Installed Kernels
########################################

kernel_list() {

    info "Installed kernels"

    case "${PKG_MANAGER}" in

        apt)

            dpkg-query \
                -W \
                -f='${Package}\n' \
                'linux-image-*' 2>/dev/null |
                sort -V

            ;;

        yum|dnf)

            rpm -q kernel | sort -V

            ;;

    esac

}

########################################
# Bootloader Information
########################################

kernel_bootloader() {

    info "Bootloader"

    if command -v grubby >/dev/null 2>&1; then

        grubby --default-kernel 2>/dev/null || true

    elif command -v grub2-editenv >/dev/null 2>&1; then

        grub2-editenv list 2>/dev/null || true

    elif command -v grub-editenv >/dev/null 2>&1; then

        grub-editenv list 2>/dev/null || true

    else

        warn "Unable to detect GRUB configuration."

    fi

}

########################################
# Ask Reboot
########################################

ask_reboot() {

    if [[ "${REBOOT_REQUIRED}" -eq 0 ]]; then

        success "No reboot required."

        return

    fi

    echo

    read -rp "Reboot now? [y/N]: " ans

    case "${ans}" in

        y|Y|yes|YES)

            info "Rebooting..."

            reboot

            ;;

        *)

            warn "Reboot skipped."

            ;;

    esac

}

########################################
# Automatic Reboot
########################################

auto_reboot() {

    if [[ "${REBOOT_REQUIRED}" -eq 1 ]]; then

        info "Automatic reboot requested."

        reboot

    fi

}

########################################
# Main
########################################

kernel_check() {

    kernel_compare

    kernel_info

}