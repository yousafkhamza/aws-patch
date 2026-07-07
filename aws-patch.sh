#!/usr/bin/env bash
#
# aws-patch.sh - Enterprise-grade Linux patch utility for AWS EC2 instances.
#
# Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12, Amazon Linux 2/2023,
#           RHEL 7/8/9, Rocky Linux, AlmaLinux, CentOS 7.
#
# Usage:
#   sudo ./aws-patch.sh [OPTIONS]
#
# Options:
#   --check       Report system/kernel/patch status only; do not install anything
#   --dry-run     Show what would be done without making changes
#   --reboot      Automatically reboot if required after patching
#   --yes         Assume "yes" to any interactive prompts (non-interactive mode)
#   --verbose     Enable debug-level console output
#   --version     Print version and exit
#   --help        Print this help and exit
#
# Safety guarantees:
#   - Never removes installed kernels
#   - Never modifies GRUB or bootloader configuration
#   - Never changes the default boot entry
#   - Never force-reboots; reboot only happens if --reboot was explicitly passed
#
# Exit codes:
#   0   success
#   1   generic failure
#   2   invalid usage / arguments
#   3   unsupported OS or package manager
#   4   pre-flight check failed (connectivity/disk space) and could not proceed
#   77  not running as root
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory so this works regardless of invocation path
# (direct execution, symlink, or `sudo bash aws-patch.sh`).
# ---------------------------------------------------------------------------
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SCRIPT_SOURCE" ]]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR

# ---------------------------------------------------------------------------
# Source library modules in dependency order.
# logger.sh first (everything logs), then common.sh + utils.sh, then the
# active pm module (chosen after detection), then kernel.sh + summary.sh.
# ---------------------------------------------------------------------------
# shellcheck source=lib/logger.sh
source "${SCRIPT_DIR}/lib/logger.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
if [[ -r "${SCRIPT_DIR}/VERSION" ]]; then
    AWS_PATCH_VERSION="$(<"${SCRIPT_DIR}/VERSION")"
else
    AWS_PATCH_VERSION="unknown"
fi
readonly AWS_PATCH_VERSION
readonly MIN_DISK_SPACE_MB=1024

# ---------------------------------------------------------------------------
# Defaults / flags
# ---------------------------------------------------------------------------
FLAG_CHECK="false"
FLAG_DRY_RUN="false"
FLAG_REBOOT="false"
FLAG_YES="false"
VERBOSE="false"
PATCH_STATUS="not_started"
SECURITY_UPDATE_COUNT=0

# ---------------------------------------------------------------------------
# usage / version
# ---------------------------------------------------------------------------
print_help() {
    cat <<EOF
aws-patch v${AWS_PATCH_VERSION}
Enterprise-grade Linux patch utility for AWS EC2 instances.

Usage:
  sudo aws-patch.sh [OPTIONS]

Options:
  --check       Report system/kernel/patch status only; do not install anything
  --dry-run     Show what would be done without making changes
  --reboot      Automatically reboot if required after patching
  --yes         Assume "yes" to any interactive prompts (non-interactive mode)
  --verbose     Enable debug-level console output
  --version     Print version and exit
  --help        Print this help and exit

Examples:
  sudo aws-patch.sh --check
  sudo aws-patch.sh --dry-run
  sudo aws-patch.sh --yes
  sudo aws-patch.sh --yes --reboot

Safety:
  aws-patch never removes kernels, never modifies GRUB, and never changes
  the default boot entry. Reboots only happen if --reboot is explicitly
  passed; otherwise the administrator decides when to reboot.

Log file: ${AWS_PATCH_LOG_FILE}
EOF
}

print_version() {
    echo "aws-patch v${AWS_PATCH_VERSION}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                FLAG_CHECK="true"
                ;;
            --dry-run)
                FLAG_DRY_RUN="true"
                ;;
            --reboot)
                FLAG_REBOOT="true"
                ;;
            --yes)
                FLAG_YES="true"
                ;;
            --verbose)
                VERBOSE="true"
                ;;
            --version)
                print_version
                exit 0
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Run 'aws-patch.sh --help' for usage." >&2
                exit 2
                ;;
        esac
        shift
    done
    export VERBOSE
}

# ---------------------------------------------------------------------------
# Load the appropriate pm module after detection. Only one is sourced,
# keeping the running process's function table free of the other two
# package managers' implementations.
# ---------------------------------------------------------------------------
load_pm_module() {
    case "$PKG_MANAGER" in
        apt)
            # shellcheck source=lib/apt.sh
            source "${SCRIPT_DIR}/lib/apt.sh"
            ;;
        yum)
            # shellcheck source=lib/yum.sh
            source "${SCRIPT_DIR}/lib/yum.sh"
            ;;
        dnf)
            # shellcheck source=lib/dnf.sh
            source "${SCRIPT_DIR}/lib/dnf.sh"
            ;;
        *)
            utils_die 3 "Unsupported package manager: $PKG_MANAGER"
            ;;
    esac

    # shellcheck source=lib/kernel.sh
    source "${SCRIPT_DIR}/lib/kernel.sh"
    # shellcheck source=lib/summary.sh
    source "${SCRIPT_DIR}/lib/summary.sh"
}

# ---------------------------------------------------------------------------
# Preflight: detection + environment checks. Always runs, even in --check.
# ---------------------------------------------------------------------------
run_preflight() {
    ui_header "Detecting environment"

    common_detect_os
    common_detect_pkg_manager
    common_detect_arch
    common_detect_hostname
    load_pm_module

    log_info "Hostname:        $HOSTNAME_FQDN"
    log_info "OS:              $OS_NAME"
    log_info "Package Manager: $PKG_MANAGER"
    log_info "Architecture:    $ARCH"

    ui_header "Pre-flight checks"

    if common_check_connectivity; then
        log_success "Internet connectivity: OK"
    else
        log_warn "Internet connectivity check failed; package operations may fail"
        if [[ "$FLAG_CHECK" != "true" && "$FLAG_DRY_RUN" != "true" ]]; then
            if [[ "$FLAG_YES" != "true" ]] && ! utils_confirm "Continue without confirmed connectivity?"; then
                utils_die 4 "Aborting: no connectivity and user declined to continue"
            fi
        fi
    fi

    if common_check_disk_space / "$MIN_DISK_SPACE_MB"; then
        log_success "Disk space: OK"
    else
        log_warn "Disk space below recommended ${MIN_DISK_SPACE_MB}MB threshold"
        if [[ "$FLAG_YES" != "true" && "$FLAG_CHECK" != "true" && "$FLAG_DRY_RUN" != "true" ]]; then
            if ! utils_confirm "Continue with low disk space?"; then
                utils_die 4 "Aborting: insufficient disk space and user declined to continue"
            fi
        fi
    fi

    kernel_reboot_required || true
    log_info "$(kernel_summary_line)"
}

# ---------------------------------------------------------------------------
# AWS-specific recovery guidance (informational only; never automated).
# ---------------------------------------------------------------------------
print_aws_recovery_guidance() {
    ui_header "AWS Recovery Recommendations"
    cat <<'EOF'
  Before patching production instances, consider:

    1. Create an AMI of this instance (or verify a recent one exists):
         aws ec2 create-image --instance-id <id> --name "pre-patch-$(date +%F)" --no-reboot

    2. Snapshot attached EBS volumes as an additional safety net:
         aws ec2 create-snapshot --volume-id <vol-id> --description "pre-patch-$(date +%F)"

    3. If a reboot leaves the instance unreachable, recovery options include:
         - Attach the root EBS volume to a rescue instance to inspect logs/fstab
         - Use EC2 Serial Console (where enabled) to access the boot prompt
         - Roll back by launching a new instance from the pre-patch AMI

  aws-patch does not call the AWS CLI or modify AMIs/snapshots itself --
  this is guidance only. Automate it in your own pipeline if desired.
EOF
}

# ---------------------------------------------------------------------------
# Patch execution
# ---------------------------------------------------------------------------
run_patch() {
    ui_header "Applying patches (pm=${PKG_MANAGER})"

    if [[ "$FLAG_DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would run: pm_update_repos"
        log_info "[dry-run] Would run: pm_full_upgrade"
        log_info "[dry-run] Would run: pm_install_kernel_meta"
        log_info "[dry-run] Would list upgradable packages:"
        pm_list_upgradable || true
        PATCH_STATUS="dry_run_only"
        return 0
    fi

    ui_spinner_start "Refreshing package repositories"
    if pm_update_repos; then
        ui_spinner_stop ok
    else
        ui_spinner_stop fail
        utils_die 1 "Failed to refresh package repositories"
    fi

    ui_spinner_start "Applying package upgrades"
    if pm_full_upgrade; then
        ui_spinner_stop ok
    else
        ui_spinner_stop fail
        utils_die 1 "Package upgrade failed"
    fi

    ui_spinner_start "Ensuring latest kernel package is installed"
    if pm_install_kernel_meta; then
        ui_spinner_stop ok
    else
        ui_spinner_stop fail
        log_warn "Kernel metapackage installation reported an issue; continuing"
    fi

    SECURITY_UPDATE_COUNT="$(pm_count_security_updates 2>/dev/null || echo 0)"
    PATCH_STATUS="completed"
}

# ---------------------------------------------------------------------------
# Reboot handling
# ---------------------------------------------------------------------------
handle_reboot() {
    if ! kernel_reboot_required; then
        log_info "No reboot required; running kernel matches latest installed kernel"
        return 0
    fi

    if [[ "$FLAG_DRY_RUN" == "true" || "$FLAG_CHECK" == "true" ]]; then
        log_info "Reboot would be recommended (skipped: $( [[ "$FLAG_CHECK" == "true" ]] && echo check-only || echo dry-run )  mode)"
        return 0
    fi

    if [[ "$FLAG_REBOOT" == "true" ]]; then
        log_warn "Reboot requested via --reboot. Rebooting now."
        log_line "INFO" "System reboot triggered by aws-patch (--reboot flag)"
        sleep 2
        reboot
        return 0
    fi

    if [[ "$FLAG_YES" == "true" ]]; then
        log_warn "Reboot required but --reboot was not passed. Skipping automatic reboot."
        log_warn "Run 'sudo reboot' manually when convenient."
        return 0
    fi

    if utils_confirm "A reboot is required to load the latest kernel. Reboot now?"; then
        log_line "INFO" "System reboot triggered by aws-patch (interactive confirmation)"
        sleep 2
        reboot
    else
        log_warn "Reboot deferred by administrator. Run 'sudo reboot' when convenient."
    fi
}

# ---------------------------------------------------------------------------
# Cleanup / trap
# ---------------------------------------------------------------------------
on_exit() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        log_line "ERROR" "aws-patch exited with code ${exit_code}"
    fi
    exit "$exit_code"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    log_init

    if [[ "$FLAG_CHECK" != "true" && "$FLAG_DRY_RUN" != "true" ]]; then
        common_require_root
    fi

    ui_header "aws-patch v${AWS_PATCH_VERSION}"

    run_preflight

    if [[ "$FLAG_CHECK" == "true" ]]; then
        PATCH_STATUS="check_only"
        SECURITY_UPDATE_COUNT="$(pm_count_security_updates 2>/dev/null || echo 0)"
        summary_render
        print_aws_recovery_guidance
        exit 0
    fi

    print_aws_recovery_guidance

    if [[ "$FLAG_YES" != "true" && "$FLAG_DRY_RUN" != "true" ]]; then
        if ! utils_confirm "Proceed with patching ${HOSTNAME_FQDN}?"; then
            log_info "Aborted by administrator."
            exit 0
        fi
    fi

    run_patch
    summary_render
    handle_reboot
}

main "$@"
