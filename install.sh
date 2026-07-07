#!/usr/bin/env bash
#
# install.sh - Remote installer for aws-patch.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<org>/aws-patch/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/<org>/aws-patch/main/install.sh | sudo bash -s -- --reboot
#
# Responsibilities:
#   - Download all required project files from the configured repo/ref
#   - Verify each download succeeded (non-empty, expected shebang)
#   - Execute aws-patch.sh, forwarding any CLI arguments given to install.sh
#   - Clean up the temporary working directory on exit (success or failure)
#   - Display progress and version information
#   - Fail safely: any download or verification error aborts before
#     anything is executed
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment for forks / private mirrors / testing)
# ---------------------------------------------------------------------------
AWS_PATCH_REPO="${AWS_PATCH_REPO:-https://raw.githubusercontent.com/yousafkhamza/aws-patch}"
AWS_PATCH_REF="${AWS_PATCH_REF:-main}"
AWS_PATCH_BASE_URL="${AWS_PATCH_REPO}/${AWS_PATCH_REF}"

# Files required for a functional install, relative to repo root.
readonly REQUIRED_FILES=(
    "aws-patch.sh"
    "VERSION"
    "lib/logger.sh"
    "lib/utils.sh"
    "lib/common.sh"
    "lib/apt.sh"
    "lib/yum.sh"
    "lib/dnf.sh"
    "lib/kernel.sh"
    "lib/summary.sh"
)

INSTALL_PREFIX="${AWS_PATCH_INSTALL_PREFIX:-/opt/aws-patch}"
TMP_DIR=""

# ---------------------------------------------------------------------------
# Minimal standalone logging (the real logger.sh isn't available yet at
# this point, since we haven't downloaded anything).
# ---------------------------------------------------------------------------
_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
info()  { printf '[%s] INFO  %s\n' "$(_ts)" "$*"; }
warn()  { printf '[%s] WARN  %s\n' "$(_ts)" "$*" >&2; }
error() { printf '[%s] ERROR %s\n' "$(_ts)" "$*" >&2; }

# ---------------------------------------------------------------------------
# Cleanup: always remove the temp directory, regardless of exit reason.
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "This installer must be run as root, e.g.:"
        error "  curl -fsSL <url> | sudo bash"
        exit 77
    fi
}

require_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        error "Neither curl nor wget is available. Please install one and retry."
        exit 1
    fi
}

fetch() {
    local url="$1"
    local dest="$2"
    local attempt

    for attempt in 1 2 3; do
        if [[ "$DOWNLOADER" == "curl" ]]; then
            if curl -fsSL --retry 2 --max-time 30 -o "$dest" "$url"; then
                return 0
            fi
        else
            if wget -q --timeout=30 -O "$dest" "$url"; then
                return 0
            fi
        fi
        warn "Download attempt ${attempt} failed for ${url}; retrying..."
        sleep 2
    done

    return 1
}

# ---------------------------------------------------------------------------
# verify_file <path>
#   Confirms the file is non-empty and, for .sh files, starts with a
#   shebang. Aborts the whole install if any required file fails
#   verification -- we never execute a partially-downloaded or corrupted
#   script.
# ---------------------------------------------------------------------------
verify_file() {
    local path="$1"

    if [[ ! -s "$path" ]]; then
        error "Verification failed: $path is empty or missing"
        return 1
    fi

    if [[ "$path" == *.sh ]]; then
        local first_line
        first_line="$(head -n1 -- "$path")"
        if [[ "$first_line" != "#!"* ]]; then
            error "Verification failed: $path does not start with a shebang"
            return 1
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Main install flow
# ---------------------------------------------------------------------------
main() {
    require_root
    require_downloader

    info "aws-patch installer"
    info "Source: ${AWS_PATCH_BASE_URL}"

    TMP_DIR="$(mktemp -d /tmp/aws-patch-install.XXXXXX)"
    info "Working directory: $TMP_DIR"

    mkdir -p "${TMP_DIR}/lib"

    local file url dest total current
    total="${#REQUIRED_FILES[@]}"
    current=0

    for file in "${REQUIRED_FILES[@]}"; do
        current=$((current + 1))
        url="${AWS_PATCH_BASE_URL}/${file}"
        dest="${TMP_DIR}/${file}"

        info "[${current}/${total}] Downloading ${file} ..."

        if ! fetch "$url" "$dest"; then
            error "Failed to download ${file} from ${url}"
            error "Installation aborted; no changes were made to this system."
            exit 1
        fi

        if ! verify_file "$dest"; then
            error "Installation aborted; no changes were made to this system."
            exit 1
        fi
    done

    info "All files downloaded and verified successfully."

    local version="unknown"
    if [[ -r "${TMP_DIR}/VERSION" ]]; then
        version="$(<"${TMP_DIR}/VERSION")"
    fi
    info "Installing aws-patch v${version} to ${INSTALL_PREFIX}"

    mkdir -p "$INSTALL_PREFIX"
    cp -r "${TMP_DIR}/lib" "$INSTALL_PREFIX/"
    cp "${TMP_DIR}/aws-patch.sh" "$INSTALL_PREFIX/"
    cp "${TMP_DIR}/VERSION" "$INSTALL_PREFIX/"
    chmod +x "${INSTALL_PREFIX}/aws-patch.sh"
    ln -sf "${INSTALL_PREFIX}/aws-patch.sh" /usr/local/bin/aws-patch

    info "Installed. Executing aws-patch.sh now..."
    info "----------------------------------------"

    "${INSTALL_PREFIX}/aws-patch.sh" "$@"
}

main "$@"
