# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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

[1.0.1]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.0.1
[1.0.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.0.0
