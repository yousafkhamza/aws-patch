#!/usr/bin/env bash
#
# ==============================================================================
# AWS Patch Utility - Common Library
# ==============================================================================
#
# Common reusable functions used across the project.
#
# Supported:
#   - Ubuntu / Debian
#   - Amazon Linux 2
#   - Amazon Linux 2023
#   - RHEL
#   - Rocky Linux
#   - AlmaLinux
#   - CentOS
#
# ==============================================================================

########################################
# Global Variables
########################################

readonly APP_NAME="aws-patch"

OS_ID=""
OS_NAME=""
OS_VERSION=""
OS_CODENAME=""
ARCH=""
HOSTNAME=""
PKG_MANAGER=""
CURRENT_KERNEL=""
INSTALLED_KERNEL=""
REBOOT_REQUIRED=0

########################################
# Terminal
########################################

if [[ -t 1 ]]; then
    COLOR_RED="\033[0;31m"
    COLOR_GREEN="\033[0;32m"
    COLOR_YELLOW="\033[1;33m"
    COLOR_BLUE="\033[0;34m"
    COLOR_CYAN="\033[0;36m"
    COLOR_WHITE="\033[1;37m"
    COLOR_RESET="\033[0m"
else
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_CYAN=""
    COLOR_WHITE=""
    COLOR_RESET=""
fi

########################################
# Root Check
########################################

require_root() {

    if [[ "${EUID}" -ne 0 ]]; then

        error "This utility must be run as root."

        echo

        echo "Example"

        echo

        echo "sudo bash aws-patch.sh"

        echo

        echo "or"

        echo

        echo "curl -fsSL URL | sudo bash"

        exit 1

    fi

}

########################################
# Detect Operating System
########################################

detect_os() {

    if [[ ! -f /etc/os-release ]]; then
        error "/etc/os-release not found."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID}"
    OS_NAME="${PRETTY_NAME}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-unknown}"

    success "Detected ${OS_NAME}"

}

########################################
# Detect Package Manager
########################################

detect_package_manager() {

    if command -v apt >/dev/null 2>&1; then

        PKG_MANAGER="apt"

    elif command -v dnf >/dev/null 2>&1; then

        PKG_MANAGER="dnf"

    elif command -v yum >/dev/null 2>&1; then

        PKG_MANAGER="yum"

    else

        error "Unsupported package manager."

        exit 1

    fi

    info "Package Manager : ${PKG_MANAGER}"

}

########################################
# Detect Architecture
########################################

detect_architecture() {

    ARCH="$(uname -m)"

    info "Architecture    : ${ARCH}"

}

########################################
# Detect Hostname
########################################

detect_hostname() {

    HOSTNAME="$(hostname)"

}

########################################
# Detect Running Kernel
########################################

detect_running_kernel() {

    CURRENT_KERNEL="$(uname -r)"

}

########################################
# Detect Installed Kernel
########################################

detect_installed_kernel() {

    case "${PKG_MANAGER}" in

        apt)

            INSTALLED_KERNEL="$(
                dpkg -l |
                awk '/linux-image-[0-9].*-aws/ && $1=="ii" {print $2}' |
                sort -V |
                tail -1
            )"

            ;;

        yum|dnf)

            INSTALLED_KERNEL="$(
                rpm -q kernel |
                sort -V |
                tail -1
            )"

            ;;

    esac

}

########################################
# Verify Supported OS
########################################

validate_os() {

    case "${OS_ID}" in

        ubuntu|debian)

            ;;

        amzn)

            ;;

        rhel)

            ;;

        rocky)

            ;;

        almalinux)

            ;;

        centos)

            ;;

        *)

            error "Unsupported Operating System: ${OS_ID}"

            exit 1

            ;;

    esac

}

########################################
# Gather System Information
########################################

gather_system_information() {

    detect_os

    validate_os

    detect_package_manager

    detect_architecture

    detect_hostname

    detect_running_kernel

    detect_installed_kernel

}