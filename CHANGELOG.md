# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-07-07

### Added
- Predictive kernel availability check. Previously, `Reboot Required` in
  `--check`/`--dry-run` output only compared the running kernel against
  what was already *installed* -- which is always a match before any
  patching has happened, so it couldn't reveal that a newer kernel was
  sitting in the repo waiting to be installed (e.g. visible via
  `yum list kernel --showduplicates` but invisible to `aws-patch --check`).
  Every pm module now implements an optional `pm_get_latest_available_kernel`
  (`lib/apt.sh` via `apt-cache search`, `lib/yum.sh` via
  `yum list available kernel --showduplicates`, `lib/dnf.sh` via
  `dnf list available kernel`), and `lib/kernel.sh` gained
  `kernel_get_latest_available` / `kernel_update_available` to compare it
  against what's installed. Surfaced as a new `Available Kernel:` line in
  the summary and a predictive warning ("A newer kernel is available but
  not yet installed... will then require a reboot") whenever a live patch
  run would install a newer kernel than what's currently on disk -- all
  read-only, all before any packages are touched. No flag required.

### Fixed
- **Integration bug in the new predictive check itself, caught before
  release:** `run_preflight` initially invoked kernel availability
  detection only implicitly via `log_info "$(kernel_summary_line)")`. A
  command substitution runs in a subshell, so the `KERNEL_LATEST_AVAILABLE`
  variable set inside it was silently discarded and never reached
  `summary_render` or the predictive warning, even though the console
  line itself displayed the value correctly (making the bug easy to miss
  by eyeballing output alone). Fixed by calling `kernel_update_available`
  directly in `run_preflight` before building the summary line, so the
  variable persists in the correct shell scope for the rest of the run.
  A permanent regression test now asserts the variable itself survives
  the full pre-flight sequence, not just the printed text.

## [1.2.0] - 2026-07-07

### Added
- Automatic Amazon Linux 2023 point-release handling (`lib/dnf.sh`:
  `pm_check_releasever_update`, `pm_upgrade_releasever`). AL2023
  periodically publishes point-release snapshots (e.g.
  `2023.12.20260629`) that can gate a newer kernel behind a
  `dnf upgrade --releasever=<version>` boundary a plain `dnf upgrade`
  won't cross on its own -- which is why `dnf upgrade --refresh` can
  print "Nothing to do" immediately below a WARNING banner announcing a
  newer release. `aws-patch` now detects this automatically on every run
  (no flag required) using AL2023's own `dnf check-release-update` helper
  when present, falling back to parsing the same WARNING banner `dnf`
  itself prints when it isn't. If a newer release is found, `aws-patch`
  crosses the point-release boundary via
  `dnf upgrade -y --releasever=<version>` *before* the normal full
  upgrade and kernel-metapackage step, so a kernel gated behind the newer
  release becomes reachable in the same run. Reflected in `--check`/live
  summary output as `AL Release Update: <version> available`, and in
  `--dry-run` as `Would run: pm_upgrade_releasever (to <version>)`. A
  true no-op when already on the latest release, and a no-op on every
  non-Amazon-Linux OS. Failure to cross the boundary is non-fatal (logs a
  warning and continues patching against the current release) and, when
  `--broken-fix` is also passed, gets the same repair-and-retry treatment
  as every other mutating operation.
- Regression tests for `pm_check_releasever_update` against a fake `dnf`
  reproducing the real-world multi-version WARNING banner format, the
  "already on latest release" case, and the "not Amazon Linux" no-op
  case.

## [1.1.0] - 2026-07-07

### Added
- New `--broken-fix` CLI flag. When a package operation (repository
  refresh, full upgrade, or kernel metapackage install) fails after
  exhausting its normal retries, `aws-patch` now runs a distro-appropriate
  repair routine and retries that operation once more before giving up:
  - **apt** (Ubuntu/Debian): `dpkg --configure -a` followed by
    `apt-get --fix-broken install`, addressing the common
    `E: Unmet dependencies` failure (e.g. a versioned
    `linux-headers-<version>` package left pointing at a dependency no
    longer installed after an interrupted prior upgrade).
  - **yum** (Amazon Linux 2, RHEL 7, CentOS 7): `yum clean all`,
    `yum-complete-transaction --cleanup-only` and
    `package-cleanup --cleandupes` where available, then retries with
    `--skip-broken`.
  - **dnf** (Amazon Linux 2023, RHEL 8/9, Rocky, AlmaLinux): cache cleanup
    then retries with `--best --allowerasing --skip-broken`.
  - Every `pm_fix_broken` implementation is held to the same safety
    guarantees as the rest of the tool: it only repairs/reconfigures
    existing package state, and never removes an installed kernel or
    touches GRUB/bootloader configuration. If the repair or retry still
    fails, `aws-patch` reports the failure and exits non-zero exactly as
    it would without the flag -- `--broken-fix` never masks a genuine,
    unrecoverable failure.
- Regression tests for the new `pm_fix_broken` contract (present in all
  three pm modules) and for `attempt_broken_fix_and_retry`'s three
  branches (repair disabled / repair+retry succeed / repair succeeds but
  retry still fails).
- `aws-patch.sh` can now be safely `source`d (e.g. by the test suite)
  without auto-executing `main`, via a `BASH_SOURCE` guard at the bottom
  of the file.

### Fixed
- Renamed a variable in `tests/run_tests.sh` (`SCRIPT_DIR` ->
  `TESTS_SCRIPT_DIR`) that collided with `aws-patch.sh`'s own internal
  `readonly SCRIPT_DIR` when the latter was sourced directly for unit
  testing inside a subshell that inherits the parent's readonly
  variables -- the collision caused that test subshell to abort silently
  with no visible error.

## [1.0.1] - 2026-07-07

### Fixed
- **Critical:** `common_retry` (`lib/common.sh`) always reported success
  after exhausting all retry attempts, regardless of whether the
  underlying command actually succeeded. The bug: `rc=$?` was read
  *after* a bare `if cmd; then ...; fi` with no `else` clause. Per POSIX
  semantics, such an `if` statement's own exit status is `0` when the
  condition is false and no branch runs -- so `rc` was silently always
  `0` on the final failing attempt, and `common_retry` (and therefore
  every `pm_update_repos`, `pm_upgrade`, `pm_full_upgrade`,
  `pm_security_only`, and `pm_install_kernel_meta` call across
  apt/yum/dnf) would return success even after real, exhausted failures.
  In practice this meant a genuinely failed `apt-get full-upgrade` (e.g.
  due to unmet kernel package dependencies) could still be reported as
  `Patch Status: completed`. Fixed by capturing the exit code inside an
  `else` clause, where it is still valid. A permanent regression test
  (`tests/run_tests.sh`) now asserts `common_retry` propagates the real
  exit code after exhausting retries.
- Command output from retried operations (e.g. `apt-get`'s own progress
  and error output) is now captured to a temp file and appended to the
  log instead of streaming directly to the terminal, which previously
  interleaved with the `\r`-based spinner and produced garbled console
  output. On final failure, the captured output is printed to the
  console in a clearly delimited block so the operator can immediately
  see the real underlying error without opening the log file.

## [1.0.0] - 2026-07-07

### Added
- Initial public release of `aws-patch`.
- Remote installer (`install.sh`) supporting `curl -fsSL <url> | sudo bash`
  and argument forwarding (`... | sudo bash -s -- --reboot`).
- OS and package manager auto-detection: Ubuntu 20.04/22.04/24.04, Debian
  11/12, Amazon Linux 2/2023, RHEL 7/8/9, Rocky Linux, AlmaLinux, CentOS 7.
- APT support: repository refresh, standard upgrade, full-upgrade, security-
  only updates, kernel metapackage detection for Generic/AWS/Virtual/Cloud
  flavors.
- YUM support (Amazon Linux 2, RHEL 7, CentOS 7): update, full update with
  obsoletes handling, security-only updates via yum-plugin-security,
  `installonly_limit` override to guarantee old kernels are never pruned.
- DNF support (Amazon Linux 2023, RHEL 8/9, Rocky, AlmaLinux): upgrade,
  full upgrade with `--best --allowerasing`, native security filtering,
  `installonly_limit` override for the same kernel-preservation guarantee.
- Kernel comparison engine (`lib/kernel.sh`): compares running kernel vs.
  latest installed kernel, cross-checked against distro-native reboot
  indicators (`needs-restarting -r`, `/var/run/reboot-required`).
- Reboot handling: interactive prompt by default, `--reboot` for automatic
  reboot, always skippable; aws-patch never forces a reboot on its own.
- CLI flags: `--check`, `--dry-run`, `--reboot`, `--yes`, `--verbose`,
  `--version`, `--help`.
- Colorized console output with spinner + elapsed time, and a final
  structured summary (hostname, OS, package manager, architecture, kernel
  state, security update count, patch status, log file path).
- Timestamped logging to `/var/log/aws-patch.log` (with automatic fallback
  to a per-user temp file if that path isn't writable).
- AWS-specific recovery guidance (AMI/EBS snapshot recommendations) printed
  before any patching occurs; aws-patch never calls the AWS CLI itself.
- Strict-mode error handling (`set -Eeuo pipefail`) with retry logic for
  transient network/repository failures.
- GitHub Actions workflow running `bash -n` and ShellCheck on every push
  and pull request.
- Full documentation: README, troubleshooting guide, recovery guide,
  example usage.

### Safety guarantees (by design, not configuration)
- Never removes an installed kernel package.
- Never modifies GRUB or any bootloader configuration.
- Never changes the default boot entry.
- Never calls `grub2-set-default` or `grub2-reboot`.
- Never reboots unless `--reboot` is explicitly passed or the administrator
  interactively confirms.

[1.3.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.3.0
[1.2.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.2.0
[1.1.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.1.0
[1.0.1]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.0.1
[1.0.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.0.0
