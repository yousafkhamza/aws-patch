#!/usr/bin/env bash
# lib/summary.sh
#
# Renders the final patch-run summary. Consumes globals set earlier in the
# run (by common.sh, kernel.sh, and aws-patch.sh) and prints/logs a
# professional summary block. Contains no package-manager-specific or
# kernel-comparison logic of its own.
#
# Public functions:
#   summary_render

set -Eeuo pipefail

if [[ "${_AWS_PATCH_SUMMARY_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_SUMMARY_SH_LOADED="true"

# ---------------------------------------------------------------------------
# summary_render
#   Expects the following globals to already be set:
#     HOSTNAME_FQDN, OS_NAME, PKG_MANAGER, ARCH,
#     KERNEL_RUNNING, KERNEL_LATEST_INSTALLED, KERNEL_REBOOT_REQUIRED,
#     SECURITY_UPDATE_COUNT, PATCH_STATUS, AWS_PATCH_LOG_FILE
#   Missing values are rendered as "unknown" rather than failing, so this
#   function is safe to call even from --check mode where some fields may
#   not have been populated.
# ---------------------------------------------------------------------------
summary_render() {
    local reboot_display security_display

    if utils_is_true "${KERNEL_REBOOT_REQUIRED:-false}"; then
        reboot_display="${C_YELLOW}YES${C_RESET}"
    else
        reboot_display="${C_GREEN}NO${C_RESET}"
    fi

    security_display="${SECURITY_UPDATE_COUNT:-0}"

    ui_header "aws-patch Summary"

    printf '  %-22s %s\n' "Hostname:"            "${HOSTNAME_FQDN:-unknown}"
    printf '  %-22s %s\n' "Operating System:"    "${OS_NAME:-unknown}"
    printf '  %-22s %s\n' "Package Manager:"     "${PKG_MANAGER:-unknown}"
    printf '  %-22s %s\n' "Architecture:"        "${ARCH:-unknown}"
    printf '  %-22s %s\n' "Running Kernel:"      "${KERNEL_RUNNING:-unknown}"
    printf '  %-22s %s\n' "Installed Kernel:"    "${KERNEL_LATEST_INSTALLED:-unknown}"
    printf '  %-22s %b\n' "Reboot Required:"     "$reboot_display"
    printf '  %-22s %s\n' "Security Updates:"    "$security_display"
    printf '  %-22s %s\n' "Patch Status:"        "${PATCH_STATUS:-unknown}"
    printf '  %-22s %s\n' "Log File:"            "${AWS_PATCH_LOG_FILE:-unknown}"
    printf '\n'

    if utils_is_true "${KERNEL_REBOOT_REQUIRED:-false}"; then
        log_warn "A reboot is recommended to run the latest installed kernel."
        log_warn "aws-patch never reboots automatically unless --reboot was passed."
    fi

    # Persist a machine-parseable summary line to the log for audit trails.
    log_line "SUMMARY" "host=${HOSTNAME_FQDN:-unknown} os=${OS_NAME:-unknown} pm=${PKG_MANAGER:-unknown} arch=${ARCH:-unknown} running_kernel=${KERNEL_RUNNING:-unknown} latest_kernel=${KERNEL_LATEST_INSTALLED:-unknown} reboot_required=${KERNEL_REBOOT_REQUIRED:-unknown} security_updates=${security_display} status=${PATCH_STATUS:-unknown}"
}
