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

# Named distinctly from aws-patch.sh's own internal SCRIPT_DIR: aws-patch.sh
# is sourced directly (not just invoked as a subprocess) later in this file
# to unit-test its internal functions, and it declares its own `readonly
# SCRIPT_DIR`. A same-named readonly variable here would collide when
# inherited into that subshell.
TESTS_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -P "${TESTS_SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
readonly TESTS_SCRIPT_DIR REPO_ROOT

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

if help_output="$("${REPO_ROOT}/aws-patch.sh" --help)" && [[ "$help_output" == *"--broken-fix"* ]]; then
    pass "aws-patch.sh --help documents --broken-fix"
else
    fail "aws-patch.sh --help does not mention --broken-fix"
fi

# ---------------------------------------------------------------------------
# Section: pm_fix_broken contract -- every pm module must implement it
# ---------------------------------------------------------------------------
echo "== pm_fix_broken contract =="

for pm_file in apt.sh yum.sh dnf.sh; do
    if (
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/logger.sh"
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/utils.sh"
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/common.sh"
        # shellcheck disable=SC1090,SC1091
        source "${REPO_ROOT}/lib/${pm_file}"
        declare -F pm_fix_broken >/dev/null 2>&1
    ); then
        pass "lib/${pm_file}: pm_fix_broken is implemented"
    else
        fail "lib/${pm_file}: pm_fix_broken is missing"
    fi
done

# ---------------------------------------------------------------------------
# Section: Amazon Linux 2023 releasever detection (lib/dnf.sh)
#   Verifies pm_check_releasever_update against a fake `dnf` reproducing
#   the exact WARNING banner format AL2023 prints when a newer
#   point-release snapshot is available, and confirms it's a true no-op
#   on non-AL2023 systems (including plain RHEL8/9/Rocky/Alma on dnf).
# ---------------------------------------------------------------------------
echo "== lib/dnf.sh: AL2023 releasever detection =="

(
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/logger.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/utils.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/common.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/dnf.sh"

    # Case 1: newer release available -- fake dnf reproduces the REAL
    # AL2023 banner as reported from a live host: 20 versions spanning
    # months 8, 10, 11, and 12, deliberately out of chronological order
    # in the listing (dnf lists 10/11/12 before 8) to verify sort -V
    # picks the true highest rather than the last-listed entry.
    OS_ID="amzn"
    OS_VERSION_ID="2023"
    # shellcheck disable=SC2317 # invoked indirectly via pm_check_releasever_update
    dnf() {
        case "$*" in
            *"check-update"*)
                cat <<'BANNER'
WARNING:
  A newer release of "Amazon Linux" is available.

  Available Versions:

  Version 2023.10.20260105:
    Run the following command to upgrade to 2023.10.20260105:

  Version 2023.10.20260120:
    Run the following command to upgrade to 2023.10.20260120:

  Version 2023.10.20260202:
    Run the following command to upgrade to 2023.10.20260202:

  Version 2023.10.20260216:
    Run the following command to upgrade to 2023.10.20260216:

  Version 2023.10.20260302:
    Run the following command to upgrade to 2023.10.20260302:

  Version 2023.10.20260325:
    Run the following command to upgrade to 2023.10.20260325:

  Version 2023.10.20260330:
    Run the following command to upgrade to 2023.10.20260330:

  Version 2023.11.20260406:
    Run the following command to upgrade to 2023.11.20260406:

  Version 2023.11.20260413:
    Run the following command to upgrade to 2023.11.20260413:

  Version 2023.11.20260427:
    Run the following command to upgrade to 2023.11.20260427:

  Version 2023.11.20260505:
    Run the following command to upgrade to 2023.11.20260505:

  Version 2023.11.20260509:
    Run the following command to upgrade to 2023.11.20260509:

  Version 2023.11.20260511:
    Run the following command to upgrade to 2023.11.20260511:

  Version 2023.11.20260514:
    Run the following command to upgrade to 2023.11.20260514:

  Version 2023.11.20260526:
    Run the following command to upgrade to 2023.11.20260526:

  Version 2023.12.20260608:
    Run the following command to upgrade to 2023.12.20260608:

  Version 2023.12.20260611:
    Run the following command to upgrade to 2023.12.20260611:

  Version 2023.12.20260622:
    Run the following command to upgrade to 2023.12.20260622:

  Version 2023.12.20260629:
    Run the following command to upgrade to 2023.12.20260629:

  Version 2023.8.20250707:
    Run the following command to upgrade to 2023.8.20250707:

  Version 2023.8.20250715:
    Run the following command to upgrade to 2023.8.20250715:
BANNER
                return 100
                ;;
            *"check-release-update --help"*) return 1 ;;
            *) return 0 ;;
        esac
    }
    export -f dnf

    result="$(pm_check_releasever_update)"
    if [[ "$result" == "2023.12.20260629" ]]; then
        echo "PASS: picks the true highest (2023.12.20260629) among 20 real-world versions via dnf check-update"
    else
        echo "FAIL: expected 2023.12.20260629, got '${result}'"
    fi

    # Case 2: already on the latest release -- no version banner printed.
    # shellcheck disable=SC2317 # invoked indirectly via pm_check_releasever_update
    dnf() {
        case "$*" in
            *"check-update"*)
                echo "Nothing to do."
                return 0
                ;;
            *"check-release-update --help"*) return 1 ;;
            *) return 0 ;;
        esac
    }
    export -f dnf
    result="$(pm_check_releasever_update)"
    if [[ -z "$result" ]]; then
        echo "PASS: no update available -> empty result"
    else
        echo "FAIL: expected empty result, got '${result}'"
    fi

    # Case: "collect from anywhere" -- a bare `dnf check-update` prints
    # nothing useful, but `dnf check-update kernel` still carries the
    # banner. Must still be found, since both sources (plus
    # check-release-update) are collected unconditionally rather than
    # stopping at the first that responds.
    # shellcheck disable=SC2317 # invoked indirectly via pm_check_releasever_update
    dnf() {
        case "$*" in
            *"check-update kernel"*)
                echo "  Version 2023.12.20260629:"
                return 100
                ;;
            *"check-update"*)
                echo "Nothing to do."
                return 0
                ;;
            *"check-release-update --help"*) return 1 ;;
            *) return 0 ;;
        esac
    }
    export -f dnf
    result="$(pm_check_releasever_update)"
    if [[ "$result" == "2023.12.20260629" ]]; then
        echo "PASS: pm_check_releasever_update finds data from check-update kernel when bare check-update has none"
    else
        echo "FAIL: expected 2023.12.20260629, got '${result}'"
    fi

    # Case 3: not Amazon Linux at all -> must be a true no-op regardless
    # of what dnf would print (function should return before calling it).
    OS_ID="rhel"
    OS_VERSION_ID="9"
    # shellcheck disable=SC2317 # invoked indirectly via pm_check_releasever_update
    dnf() { echo "SHOULD NOT BE CALLED"; return 0; }
    export -f dnf
    result="$(pm_check_releasever_update)"
    if [[ -z "$result" ]]; then
        echo "PASS: non-Amazon-Linux OS -> no-op, dnf not queried"
    else
        echo "FAIL: expected no-op on non-AL2023, got '${result}'"
    fi
) > /tmp/aws-patch-al2023-test-$$.txt 2>&1

while IFS= read -r line; do
    case "$line" in
        PASS:*) pass "${line#PASS: }" ;;
        FAIL:*) fail "${line#FAIL: }" ;;
    esac
done < "/tmp/aws-patch-al2023-test-$$.txt"
rm -f "/tmp/aws-patch-al2023-test-$$.txt"

# ---------------------------------------------------------------------------
# Section: predictive kernel availability (kernel_update_available)
#   Verifies that a newer kernel sitting in the repo -- but not yet
#   installed -- is correctly detected via each pm module's
#   pm_get_latest_available_kernel, and that kernel_update_available
#   reports it as an available update ahead of any actual patching.
# ---------------------------------------------------------------------------
echo "== kernel_update_available (predictive, pre-patch) =="

(
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/logger.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/utils.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/common.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/yum.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/kernel.sh"

    ARCH="x86_64"

    # Reproduces the real-world scenario: `yum list kernel
    # --showduplicates` offers several newer builds than what's installed.
    # shellcheck disable=SC2317 # invoked indirectly via pm_get_latest_available_kernel
    yum() {
        case "$*" in
            *"list kernel --showduplicates"*)
                cat <<'BANNER'
Available Packages
kernel.x86_64    4.14.355-282.731.amzn2   amzn2-core
kernel.x86_64    4.14.355-282.733.amzn2   amzn2-core
kernel.x86_64    4.14.355-284.735.amzn2   amzn2-core
kernel.x86_64    4.14.355-284.737.amzn2   amzn2-core
BANNER
                ;;
        esac
    }
    export -f yum

    # shellcheck disable=SC2317 # invoked indirectly via pm_get_installed_kernels
    rpm() {
        if [[ "$*" == *"-q kernel"* ]]; then
            echo "4.14.355-282.729.amzn2.x86_64"
        fi
    }
    export -f rpm

    result="$(pm_get_latest_available_kernel)"
    if [[ "$result" == "4.14.355-284.737.amzn2.x86_64" ]]; then
        echo "PASS: pm_get_latest_available_kernel (yum) picks the highest of several available builds"
    else
        echo "FAIL: expected 4.14.355-284.737.amzn2.x86_64, got '${result}'"
    fi

    if kernel_update_available; then
        if [[ "$KERNEL_LATEST_AVAILABLE" == "4.14.355-284.737.amzn2.x86_64" ]]; then
            echo "PASS: kernel_update_available detects newer kernel ahead of any patching"
        else
            echo "FAIL: KERNEL_LATEST_AVAILABLE unexpected value '${KERNEL_LATEST_AVAILABLE}'"
        fi
    else
        echo "FAIL: expected kernel_update_available to report an update"
    fi

    # Case: repo offers nothing newer than what's already installed ->
    # must NOT report an update.
    # shellcheck disable=SC2317 # invoked indirectly via pm_get_latest_available_kernel
    yum() {
        case "$*" in
            *"list kernel --showduplicates"*)
                echo "kernel.x86_64    4.14.355-282.729.amzn2   amzn2-core"
                ;;
        esac
    }
    export -f yum
    if kernel_update_available; then
        echo "FAIL: reported an update when the available kernel matches installed"
    else
        echo "PASS: no update reported when available kernel matches installed"
    fi

    # Case: "collect from anywhere" -- `yum list kernel --showduplicates`
    # returns nothing (e.g. blocked/misconfigured on some hosts) but
    # `yum check-update kernel` still has the data. Must still be found,
    # since both sources are collected unconditionally rather than
    # stopping at the first that responds.
    # shellcheck disable=SC2317 # invoked indirectly via pm_get_latest_available_kernel
    yum() {
        case "$*" in
            *"list kernel --showduplicates"*)
                return 0
                ;;
            *"check-update kernel"*)
                echo "kernel.x86_64    4.14.355-284.737.amzn2   amzn2-core"
                return 100
                ;;
        esac
    }
    export -f yum
    result="$(pm_get_latest_available_kernel)"
    if [[ "$result" == "4.14.355-284.737.amzn2.x86_64" ]]; then
        echo "PASS: pm_get_latest_available_kernel finds data from check-update when list returns nothing"
    else
        echo "FAIL: expected 4.14.355-284.737.amzn2.x86_64, got '${result}'"
    fi
) > /tmp/aws-patch-kernel-avail-test-$$.txt 2>&1

while IFS= read -r line; do
    case "$line" in
        PASS:*) pass "${line#PASS: }" ;;
        FAIL:*) fail "${line#FAIL: }" ;;
    esac
done < "/tmp/aws-patch-kernel-avail-test-$$.txt"
rm -f "/tmp/aws-patch-kernel-avail-test-$$.txt"

for pm_file in apt.sh yum.sh dnf.sh; do
    if (
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/logger.sh"
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/utils.sh"
        # shellcheck disable=SC1091
        source "${REPO_ROOT}/lib/common.sh"
        # shellcheck disable=SC1090,SC1091
        source "${REPO_ROOT}/lib/${pm_file}"
        declare -F pm_get_latest_available_kernel >/dev/null 2>&1
    ); then
        pass "lib/${pm_file}: pm_get_latest_available_kernel is implemented"
    else
        fail "lib/${pm_file}: pm_get_latest_available_kernel is missing"
    fi
done

# ---------------------------------------------------------------------------
# Regression test: KERNEL_LATEST_AVAILABLE must survive as a real shell
# variable after the pre-flight sequence, not just appear in the printed
# kernel_summary_line text. A prior integration bug called
# kernel_update_available only implicitly inside
# `log_info "$(kernel_summary_line)")` -- a command substitution, which
# runs in a subshell -- so the variable it set was silently discarded and
# never reached summary_render, even though the console line displayed it
# correctly. This asserts the variable itself, not just the printed text.
# ---------------------------------------------------------------------------
echo "== Regression: KERNEL_LATEST_AVAILABLE survives outside a subshell =="

(
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/logger.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/utils.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/common.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/yum.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/kernel.sh"

    ARCH="x86_64"
    # shellcheck disable=SC2317 # invoked indirectly via pm_get_latest_available_kernel
    yum() {
        case "$*" in
            *"list kernel --showduplicates"*)
                echo "kernel.x86_64    4.14.355-284.737.amzn2   amzn2-core"
                ;;
        esac
    }
    export -f yum
    # shellcheck disable=SC2317 # invoked indirectly via pm_get_installed_kernels
    rpm() {
        if [[ "$*" == *"-q kernel"* ]]; then
            echo "4.14.355-282.729.amzn2.x86_64"
        fi
    }
    export -f rpm

    # Mirrors the real run_preflight sequence exactly.
    kernel_reboot_required || true
    kernel_update_available || true
    _discard="$(kernel_summary_line)"

    if [[ "${KERNEL_LATEST_AVAILABLE:-}" == "4.14.355-284.737.amzn2.x86_64" ]]; then
        echo "PASS: KERNEL_LATEST_AVAILABLE persists after the pre-flight sequence"
    else
        echo "FAIL: KERNEL_LATEST_AVAILABLE was lost (got '${KERNEL_LATEST_AVAILABLE:-<unset>}')"
    fi
) > /tmp/aws-patch-subshell-regression-$$.txt 2>&1

while IFS= read -r line; do
    case "$line" in
        PASS:*) pass "${line#PASS: }" ;;
        FAIL:*) fail "${line#FAIL: }" ;;
    esac
done < "/tmp/aws-patch-subshell-regression-$$.txt"
rm -f "/tmp/aws-patch-subshell-regression-$$.txt"

# ---------------------------------------------------------------------------
# Section: attempt_broken_fix_and_retry (sourced from aws-patch.sh in
# isolation -- main() does not auto-run because aws-patch.sh guards it
# with a BASH_SOURCE check when sourced rather than executed directly)
# ---------------------------------------------------------------------------
echo "== attempt_broken_fix_and_retry =="

(
    source "${REPO_ROOT}/aws-patch.sh"

    PKG_MANAGER="apt"

    # Case 1: --broken-fix not set -> should be a no-op (return 1) and
    # must NOT call pm_fix_broken at all.
    FLAG_BROKEN_FIX="false"
    _fix_called="false"
    pm_fix_broken() { _fix_called="true"; return 0; }
    # shellcheck disable=SC2317 # invoked indirectly via attempt_broken_fix_and_retry
    dummy_retry_fn() { return 1; }

    if ! attempt_broken_fix_and_retry "test op" dummy_retry_fn >/dev/null 2>&1; then
        if [[ "$_fix_called" == "false" ]]; then
            echo "PASS: broken-fix disabled -> no-op, pm_fix_broken not called"
        else
            echo "FAIL: pm_fix_broken was called despite --broken-fix being disabled"
        fi
    else
        echo "FAIL: expected failure (no-op) when --broken-fix is disabled"
    fi

    # Case 2: --broken-fix set, repair succeeds, retry succeeds -> overall success
    FLAG_BROKEN_FIX="true"
    pm_fix_broken() { return 0; }
    # shellcheck disable=SC2317 # invoked indirectly via attempt_broken_fix_and_retry
    retry_fn_succeeds() { return 0; }
    if attempt_broken_fix_and_retry "test op" retry_fn_succeeds >/dev/null 2>&1; then
        echo "PASS: repair succeeds + retry succeeds -> overall success"
    else
        echo "FAIL: expected success when repair and retry both succeed"
    fi

    # Case 3: --broken-fix set, repair succeeds, retry still fails -> overall failure
    # shellcheck disable=SC2317 # invoked indirectly via attempt_broken_fix_and_retry
    retry_fn_fails() { return 1; }
    if ! attempt_broken_fix_and_retry "test op" retry_fn_fails >/dev/null 2>&1; then
        echo "PASS: repair succeeds but retry still fails -> overall failure"
    else
        echo "FAIL: expected failure when retry still fails after repair"
    fi
) > /tmp/aws-patch-broken-fix-test-$$.txt 2>&1

while IFS= read -r line; do
    case "$line" in
        PASS:*) pass "${line#PASS: }" ;;
        FAIL:*) fail "${line#FAIL: }" ;;
    esac
done < "/tmp/aws-patch-broken-fix-test-$$.txt"
rm -f "/tmp/aws-patch-broken-fix-test-$$.txt"

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
