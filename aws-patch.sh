#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/lib/logger.sh"

print_banner

info "AWS Patch Utility"

echo

info "Version: $(cat "${SCRIPT_DIR}/VERSION")"

echo

success "Bootstrap completed."

success "Ready for next modules."

exit 0