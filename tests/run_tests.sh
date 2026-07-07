#!/usr/bin/env bash
#
# tests/run_tests.sh
#
# Self-contained test suite for aws-patch. Requires no root privileges and
# no network access. Exercises:
#   - lib/utils.sh version comparison and helpers
#   - lib/common.sh OS/arch/hostname detection against the CURRENT host
#   - lib/kernel.sh comparison logic against a fake pm_get_installed_kernels
#   - CLI argument parsing behavior of aws-patch.sh (--help/--version/--check)
#
# This is a lightweight assert-style runner, not a full BATS suite, so it
# has zero external dependencies beyond bash itself.
#
# Usage:
#   ./tests/run_tests.sh
#
# Exit code 0 if all tests pass, 1 if any test fails.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR REPO_ROOT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  \033[32m✔\033[0m %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  \033[31m✖\033[0m %s\n' "$1"
}

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_success() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc (command failed: $*)"
    fi
}

assert_failure() {
    local desc="$1"
    shift
    if ! "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc (expected failure but command succeeded: $*)"
    fi
}

# ---------------------------------------------------------------------------
# Section: lib/utils.sh
# ---------------------------------------------------------------------------
echo "== lib/utils.sh =="

# shellcheck disable=SC1091 # resolves correctly at runtime; only a static-analysis path quirk
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/utils.sh"

assert_success "utils_version_ge: 5.15.0-105 >= 5.15.0-100" \
    utils_version_ge "5.15.0-105-generic" "5.15.0-100-generic"

assert_failure "utils_version_ge: 5.10.0 >= 5.15.0 is false" \
    utils_version_ge "5.10.0-generic" "5.15.0-generic"

assert_success "utils_version_gt: 6.2 > 6.1" \
    utils_version_gt "6.2" "6.1"

assert_failure "utils_version_gt: 6.1 > 6.1 is false (equal)" \
    utils_version_gt "6.1" "6.1"

assert_success "utils_is_true: 'true' is truthy" utils_is_true "true"
assert_success "utils_is_true: '1' is truthy" utils_is_true "1"
assert_failure "utils_is_true: 'false' is not truthy" utils_is_true "false"
assert_failure "utils_is_true: '' is not truthy" utils_is_true ""

result="$(utils_human_duration 125)"
assert_eq "$result" "2m 5s" "utils_human_duration(125) == '2m 5s'"

result="$(utils_human_duration 45)"
assert_eq "$result" "45s" "utils_human_duration(45) == '45s'"

assert_success "utils_command_exists: bash exists" utils_command_exists bash
assert_failure "utils_command_exists: nonexistent-cmd-xyz does not exist" \
    utils_command_exists nonexistent-cmd-xyz

# ---------------------------------------------------------------------------
# Section: lib/common.sh (detection against the actual host running tests)
# ---------------------------------------------------------------------------
echo "== lib/common.sh =="

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/common.sh"

common_detect_os
if [[ -n "${OS_ID:-}" && -n "${OS_FAMILY:-}" ]]; then
    pass "common_detect_os: OS_ID='$OS_ID' OS_FAMILY='$OS_FAMILY' populated"
else
    fail "common_detect_os: OS_ID/OS_FAMILY not populated"
fi

common_detect_pkg_manager
if [[ "$PKG_MANAGER" == "apt" || "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
    pass "common_detect_pkg_manager: resolved to '$PKG_MANAGER'"
else
    fail "common_detect_pkg_manager: unexpected value '$PKG_MANAGER'"
fi

common_detect_arch
assert_eq "$ARCH" "$(uname -m)" "common_detect_arch matches uname -m"

common_detect_hostname
if [[ -n "$HOSTNAME_FQDN" ]]; then
    pass "common_detect_hostname: populated ('$HOSTNAME_FQDN')"
else
    fail "common_detect_hostname: empty"
fi

# ---------------------------------------------------------------------------
# Regression test: common_retry must propagate the real exit code of a
# command that fails on every attempt. A prior bug captured "$?" *after*
# a bare `if cmd; then ...; fi` with no else clause, which is always 0
# per POSIX semantics when the condition is false -- silently masking
# every failure across every pm_* operation that uses common_retry.
# ---------------------------------------------------------------------------
echo "== lib/common.sh: common_retry regression =="

_regression_fake_fail() { return 100; }

set +e
common_retry 2 0 -- _regression_fake_fail >/dev/null 2>&1
retry_rc=$?
set -e
assert_eq "$retry_rc" "100" "common_retry propagates real exit code (100) after exhausting retries"

_regression_fake_succeed_on_second_try() {
    _regression_attempt_count="${_regression_attempt_count:-0}"
    _regression_attempt_count=$((_regression_attempt_count + 1))
    [[ "$_regression_attempt_count" -ge 2 ]]
}
_regression_attempt_count=0
assert_success "common_retry succeeds once the command succeeds within max_attempts" \
    common_retry 3 0 -- _regression_fake_succeed_on_second_try

# ---------------------------------------------------------------------------
# Section: lib/kernel.sh (using a fake pm_get_installed_kernels, no real pm)
# ---------------------------------------------------------------------------
echo "== lib/kernel.sh =="

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/kernel.sh"

# Fake pm module: pretend two kernels are installed, one newer than running.
# shellcheck disable=SC2317 # invoked indirectly via kernel_get_latest_installed
pm_get_installed_kernels() {
    printf '5.15.0-100-generic\n5.15.0-105-generic\n'
}

running_kernel="$(kernel_get_running)"
if [[ -n "$running_kernel" ]]; then
    pass "kernel_get_running: returned '$running_kernel'"
else
    fail "kernel_get_running: empty result"
fi

latest="$(kernel_get_latest_installed)"
assert_eq "$latest" "5.15.0-105-generic" "kernel_get_latest_installed picks highest version"

# Force a mismatch scenario: fake running kernel differs from latest installed.
# shellcheck disable=SC2317 # invoked indirectly via kernel_reboot_required
kernel_get_running() { echo "5.15.0-100-generic"; }
if kernel_reboot_required; then
    pass "kernel_reboot_required: detects mismatch as reboot-required"
else
    fail "kernel_reboot_required: failed to detect mismatch"
fi

# Force a match scenario: running == latest installed.
# shellcheck disable=SC2317 # invoked indirectly via kernel_reboot_required
kernel_get_running() { echo "5.15.0-105-generic"; }
if ! kernel_reboot_required; then
    pass "kernel_reboot_required: no reboot needed when versions match"
else
    fail "kernel_reboot_required: false positive when versions match"
fi

# ---------------------------------------------------------------------------
# Section: aws-patch.sh CLI behavior (no root required for these flags)
# ---------------------------------------------------------------------------
echo "== aws-patch.sh CLI =="

version_output="$("${REPO_ROOT}/aws-patch.sh" --version)"
if [[ "$version_output" == aws-patch\ v* ]]; then
    pass "aws-patch.sh --version prints version string ('$version_output')"
else
    fail "aws-patch.sh --version unexpected output: '$version_output'"
fi

help_output="$("${REPO_ROOT}/aws-patch.sh" --help)"
if [[ "$help_output" == *"--check"* && "$help_output" == *"--reboot"* ]]; then
    pass "aws-patch.sh --help lists expected flags"
else
    fail "aws-patch.sh --help missing expected flag documentation"
fi

if NO_COLOR=1 AWS_PATCH_LOG_FILE="/tmp/aws-patch-test-$$.log" \
    "${REPO_ROOT}/aws-patch.sh" --check >/tmp/aws-patch-check-output-$$.txt 2>&1; then
    pass "aws-patch.sh --check exits 0 without root/network"
else
    fail "aws-patch.sh --check exited non-zero"
fi

if grep -q "Patch Status:" "/tmp/aws-patch-check-output-$$.txt"; then
    pass "aws-patch.sh --check prints a summary block"
else
    fail "aws-patch.sh --check did not print a summary block"
fi
rm -f "/tmp/aws-patch-check-output-$$.txt" "/tmp/aws-patch-test-$$.log"

set +e
"${REPO_ROOT}/aws-patch.sh" --totally-not-a-real-flag >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "2" "aws-patch.sh rejects unknown flags with exit code 2"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo " Passed: $PASS_COUNT   Failed: $FAIL_COUNT"
echo "================================"

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
