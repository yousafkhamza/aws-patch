# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.10.3] - 2026-07-28

### Added
- **GRUB default boot entry mismatch detection (RHEL-family, where
  `grubby` is available).** A kernel can be genuinely, correctly
  installed -- real boot files present, not a stale database entry --
  and still not be what a reboot would actually load, if GRUB's own
  default boot entry was never updated to point at it (normally
  automatic via the kernel package's own post-install scriptlets, but
  can fail to complete after an interrupted transaction). Previously
  `aws-patch` had no way to detect this before rebooting; a `--reboot`
  run would silently restart into the exact same kernel that was already
  running, with nothing in the summary to reveal why.
  - `lib/kernel.sh`: new `_kernel_grub_default_matches()` -- read-only
    (`grubby --default-kernel`) comparison against the kernel version a
    reboot is expected to load. Sets `KERNEL_BOOT_DEFAULT_MISMATCH`.
    Unverifiable systems (no `grubby` -- most Debian/Ubuntu installs)
    are left unflagged rather than guessed at by parsing `grub.cfg`,
    which would risk false positives blocking legitimate reboots.
  - `lib/summary.sh`: reports `Reboot Required: GRUB DEFAULT MISMATCH`
    distinctly from both a plain `YES` and a `STALE ENTRY`.
  - `aws-patch.sh`: `handle_reboot()` skips the no-op reboot (even with
    `--reboot`/`--yes`) and logs the exact `grubby --set-default`
    command needed, instead of rebooting into nothing changing.
  - `docs/troubleshooting.md`: new "GRUB default not updated to the new
    kernel" section with the full fix.
  - This is read-only inspection only -- `lib/kernel.sh` still never
    writes to GRUB or changes the default boot entry itself; the file's
    header comment was clarified to make that distinction explicit.
- New test coverage in `tests/run_tests.sh` (`== GRUB default boot entry
  mismatch ==`): mismatch detected, correct-default not falsely
  flagged, and grubby-unavailable never blocks a reboot.

## [1.10.2] - 2026-07-28

### Added
- **Stale kernel database entry detection.** A package manager's own
  database can end up recording a kernel as "installed" when its actual
  boot files were never written -- almost always caused by a kernel
  transaction interrupted partway through (Ctrl+C/Ctrl+Z, a dropped SSH
  session, an OOM kill). Previously, `aws-patch` trusted that database
  entry the same way any tool would and recommended a reboot that could
  never actually help, since GRUB has nothing new to boot into --
  rebooting just restarts into the exact same running kernel, with no
  way for the administrator to tell that from the summary alone.
  - `lib/kernel.sh`: new `_kernel_boot_files_present()` sanity-checks
    that `/boot/vmlinuz-<version>` actually exists for the "latest
    installed" kernel before trusting it. `kernel_reboot_required()` now
    sets `KERNEL_INSTALL_INCOMPLETE` when it doesn't. OS-agnostic --
    `/boot/vmlinuz-<version>` is the same naming convention on
    Debian/Ubuntu and every RPM-based family.
  - `lib/summary.sh`: reports `Reboot Required: STALE ENTRY` instead of
    a misleading plain `YES`, with the real cause and fix logged.
  - `aws-patch.sh`: `handle_reboot()` now skips the no-op reboot
    entirely when this is detected (even with `--reboot`/`--yes`) and
    logs the actual remediation instead.
  - `docs/troubleshooting.md`: new "Stale kernel database entry" section
    with full recovery steps for both Debian/Ubuntu and RHEL-family
    systems (Amazon Linux, RHEL, Rocky, AlmaLinux).
  - `AWS_PATCH_BOOT_DIR` env var (defaults to `/boot`) makes the check
    testable without touching the real filesystem.
- New test coverage in `tests/run_tests.sh` reproducing the exact
  real-world scenario (`== stale kernel database entry (missing /boot
  files) ==`), plus a false-positive guard confirming a real installed
  kernel with genuine boot files is never flagged.

## [1.10.1] - 2026-07-28

### Fixed
- **Amazon Linux 2023 "newer release available" reported forever, even
  immediately after successfully upgrading to that exact release.**
  `dnf`'s release-notification banner lists the latest known AL2023
  point-release snapshot unconditionally -- including when it's the
  exact one the host is already running. `pm_check_releasever_update`
  (`lib/dnf.sh`) was reporting that scraped value as "available" with no
  comparison against the currently running release, so every run
  re-triggered the expensive `pm_upgrade_releasever` step
  (`dnf upgrade --releasever=...`, often 30s-plus, sometimes much longer
  under load) for a release the host was already on -- with nothing to
  actually upgrade. Fixed by extracting the currently-running dated
  snapshot from `OS_NAME`/`PRETTY_NAME` (the generic `OS_VERSION_ID` is
  only ever `"2023"` and can't be used for this comparison) and only
  reporting a candidate that is genuinely newer. `pm_list_releasever_updates`
  received the same fix. New regression tests reproduce the exact
  scenario from a live host (banner lists `2023.12.20260727`while
  already running `2023.12.20260727`) alongside a "genuinely behind"
  case to confirm real updates are still detected correctly.

## [1.10.0] - 2026-07-28

### Added
- **`--kernel` flag.** By default, `aws-patch` now excludes the kernel
  package from a run's upgrade entirely: every other package still
  patches normally, but the kernel is left exactly as it was, so routine
  patching never forces a reboot decision. Pass `--kernel` to also
  install a newer kernel if one's available (pairs naturally with
  `--reboot`: `sudo aws-patch --yes --kernel --reboot`).
  - `lib/apt.sh`: new `pm_full_upgrade_no_kernel()` — holds the
    currently-installed `linux-image-*`/`linux-headers-*`/
    `linux-modules-*` packages via `apt-mark hold` for the duration of
    the upgrade and always unholds them after, success or failure.
  - `lib/yum.sh` / `lib/dnf.sh`: new `pm_full_upgrade_no_kernel()` —
    runs the upgrade transaction with native `--exclude='kernel*'`.
  - `aws-patch.sh`: `run_patch()` now branches on `--kernel`; when
    excluded, a clear summary line and warning report that a kernel
    update was available but skipped, and how to include it next run.
  - `lib/summary.sh`: new `Kernel Update:` field, and the final warning
    now distinguishes "will install" from "excluded this run (pass
    --kernel to include)".
  - This never changes what happens to a kernel that's already
    installed -- no package is ever removed and GRUB is never touched,
    same guarantees as always.
- New test coverage in `tests/run_tests.sh` for `--kernel` flag parsing/
  help documentation and `pm_full_upgrade_no_kernel` behavior on all
  three package managers (`== pm_full_upgrade_no_kernel (--kernel
  gating) ==`).

## [1.9.1] - 2026-07-28

### Fixed
- **False "kernel available but not installed" report on RHEL-family
  systems (yum/dnf), most visibly on Amazon Linux 2023.** When a kernel
  package carries a non-zero RPM epoch, `yum`/`dnf list` reports its
  version with an `epoch:` prefix (e.g. `1:6.1.176-221.367.amzn2023`),
  but `rpm -q --qf '%{VERSION}-%{RELEASE}...'` (used to determine what's
  actually installed) never includes the epoch. Left unstripped, that
  bare `1:` prefix sorted as version-*greater* than the plain version
  string under `sort -V`, so the exact same installed/running kernel
  was misreported as a newer "available" kernel on every single run --
  even immediately after patching, with nothing left to update.
  `lib/yum.sh` and `lib/dnf.sh` now strip the epoch prefix from every
  kernel version candidate before comparison. New regression tests added
  reproducing the exact scenario (installed == running == available,
  differing only by epoch prefix).

## [1.9.0] - 2026-07-28

### Added
- `utils_filter_valid_kernel_lines` in `lib/utils.sh`: a shared filter
  that every pm module now runs candidate kernel package lines through
  before picking a "latest" version with `sort -V`. This closes a gap
  where a package that merely *looks* like a kernel version string could
  win that comparison and be misreported as an installed or available
  kernel:
  - `lib/apt.sh` (`pm_get_installed_kernels`,
    `pm_get_latest_available_kernel`): now excludes `-dbgsym`, `-dbg`,
    and `-unsigned` packages (e.g. `linux-image-6.8.0-31-generic-dbgsym`
    ships no bootable kernel at all, but its name sorts as a valid, and
    sometimes higher, version).
  - `lib/yum.sh` and `lib/dnf.sh` (`pm_get_latest_available_kernel`):
    candidates are now anchored to the detected `$ARCH`, excluding
    `kernel.src` (source RPM, not installable) and any other
    architecture's build that a multilib-capable `yum`/`dnf`
    configuration might otherwise surface.
- New test coverage in `tests/run_tests.sh` for all of the above
  (`== invalid kernel candidate filtering ==`).

## [1.8.1] - 2026-07-09

### Fixed
- `release.yml`'s "Create GitHub Release" step failed with `a release
  with the same tag name already exists` on any re-run where the
  release had already been created in a prior attempt (e.g. the `pages`
  job failing on GitHub's auto-created `github-pages` environment
  protection rules, which rejects tag refs by default -- a separate,
  one-time Settings fix -- while the independent `release` job, which
  only depends on `build`, had already succeeded and created the
  release). Made the step idempotent: it now checks whether a release
  for the tag already exists via `gh release view` and deletes it
  first (keeping the underlying git tag intact) before recreating it,
  so re-running the workflow always produces a clean, current release
  instead of failing on a duplicate.

## [1.8.0] - 2026-07-09

### Added
- Automated GitHub Pages deployment via a new reusable workflow,
  `.github/workflows/pages.yml`, using the official Actions-based flow
  (`actions/configure-pages` → `actions/upload-pages-artifact` →
  `actions/deploy-pages`) instead of the manual "Deploy from a branch"
  setting. Runs two ways:
  - Standalone, on every push to `main` that touches `docs/**` — the
    site updates the moment `index.html`/styling/copy changes, with no
    need to cut a release.
  - As a job inside `.github/workflows/release.yml` (invoked via
    `uses: ./.github/workflows/pages.yml`), running in parallel with
    the package build once the lint/test gate passes -- so a single
    `git push origin vX.Y.Z` now handles tests, `.deb`/`.rpm` packages,
    the GitHub Release, *and* the Pages deploy together, as one
    pipeline.
- README: rewrote the "Project site (GitHub Pages)" section to describe
  the automated flow (including the one-time "Settings → Pages → Source:
  GitHub Actions" switch, since the branch-based and Actions-based
  deployment mechanisms don't share state) in place of the old manual
  branch/folder setup steps.

## [1.7.1] - 2026-07-09

### Changed
- `docs/index.html` footer restyled to: `Built by Yousaf Hamza · ©
  <year> aws-patch. All rights reserved. · Source on GitHub`, with the
  copyright year set client-side via JavaScript so it never goes stale,
  and the "Source on GitHub" link pointing at the actual repo URL.

## [1.7.0] - 2026-07-08

### Added
- Project landing page at `docs/index.html`, served via GitHub Pages at
  https://yousafkhamza.github.io/aws-patch/ once enabled (Settings →
  Pages → Deploy from a branch → `main` / `/docs` — see README for full
  steps). Fetches the latest release directly from the GitHub API
  (`GET /repos/yousafkhamza/aws-patch/releases/latest`) client-side on
  load, so the version number, publish date, and download links for
  every release asset (`.deb`, `.rpm`, tarball, `SHA256SUMS`) always
  reflect whatever was most recently published -- nothing to update by
  hand when a new version ships. Also renders exact `dpkg`/`rpm` install
  commands with the real asset filenames filled in once the API response
  arrives. Falls back to a direct link to the Releases page if the API
  call fails (e.g. hourly rate limit from an unauthenticated client)
  rather than showing a broken UI. Dark terminal-styled design (amber/
  green accents on near-black) matching the project's own console
  output aesthetic; includes an "Open Source" / "MIT License" badge
  pair and an author credit.
- `docs/.nojekyll` so GitHub Pages serves `docs/` as-is (needed since
  the directory also holds plain Markdown troubleshooting/recovery docs
  and the man page source, none of which are meant to be Jekyll-built).
- README: "Project site (GitHub Pages)" section with one-time setup
  steps, and a site badge/link at the top of the README.

## [1.6.1] - 2026-07-08

### Fixed
- `.github/workflows/release.yml`'s "Run test suite" and "Build .deb and
  .rpm packages" steps invoked `./tests/run_tests.sh` and
  `./scripts/build-packages.sh` directly, which depend on the
  executable bit surviving into the GitHub Actions checkout. On the
  first real run this failed with `Permission denied` (exit 126) --
  the bit hadn't survived however the repository's history was
  populated. Fixed by invoking both via explicit `bash <script>` instead
  of direct execution, which only requires the file to be readable, plus
  an added `chmod +x` step as defense in depth. Also hardened
  `tests/run_tests.sh` itself: it previously invoked `aws-patch.sh`
  directly in several places (`"${REPO_ROOT}/aws-patch.sh" --version`,
  etc.), which would hit the identical failure mode in any checkout
  missing the bit; switched to `bash "${REPO_ROOT}/aws-patch.sh"`
  throughout. Verified by stripping every executable bit in the repo
  and confirming `bash tests/run_tests.sh` still passes all 51 tests.

## [1.6.0] - 2026-07-07

### Added
- `.deb` and `.rpm` packaging via `scripts/build-packages.sh` (built with
  [fpm](https://github.com/jordansissel/fpm)). Installs to an
  FHS-compliant layout (`/usr/lib/aws-patch/`, symlinked from
  `/usr/bin/aws-patch`) independent of `install.sh`'s `/opt/aws-patch`
  layout; `aws-patch.sh`'s existing symlink-resolution logic was verified
  to correctly locate `lib/*.sh` either way.
- `docs/aws-patch.1` man page, installed as part of both packages
  (`man aws-patch` after installing via `.deb`/`.rpm`).
- New GitHub Actions release pipeline
  (`.github/workflows/release.yml`), triggered on pushing a `vX.Y.Z` tag
  (or manually via `workflow_dispatch`):
  1. Re-runs the full lint/test suite (`bash -n`, ShellCheck,
     `tests/run_tests.sh`) as a hard gate before anything is built.
  2. Verifies the `VERSION` file matches the pushed tag; fails the
     release rather than publishing a mismatched version.
  3. Builds `.deb` and `.rpm` packages, a source tarball, and a
     `SHA256SUMS` checksum file.
  4. Publishes a GitHub Release with all artifacts attached and release
     notes extracted directly from the matching `CHANGELOG.md` section,
     plus generated install-command snippets for both package formats
     and the existing one-line installer.
- `.github/workflows/shellcheck.yml` (the existing push/PR lint
  workflow) now also covers `scripts/*.sh`.
- README: new "Package install (.deb / .rpm)" section, a "Release
  process (maintainers)" section documenting the tag-to-release flow,
  and an FAQ entry explaining the deliberate choice of downloadable
  packages over a full signed `apt`/`yum` repository (and what that
  larger step would require, if ever pursued).

## [1.5.0] - 2026-07-07

### Fixed
- **Critical: AL2023 release detection was discarding stderr, where the
  banner actually lives.** `pm_check_releasever_update` captured `dnf
  check-update`/`dnf check-update kernel`/`dnf check-release-update` with
  `2>/dev/null`. The release-notification plugin's WARNING banner is
  emitted on **stderr**, not stdout -- confirmed by the fact that
  `dnf check-update kernel | head` (which only redirects stdout) still
  displayed the banner on a real host, because stderr passed straight
  through to the terminal. `2>/dev/null` was silently discarding it on
  every single detection attempt, on every real AL2023 host, regardless
  of which command variant was tried -- which is why v1.4.0's
  "collect from every source" fix still produced no output. Fixed by
  capturing with `2>&1` instead. Applied the same fix to the kernel
  availability checks (`pm_get_latest_available_kernel` in both
  `lib/yum.sh` and `lib/dnf.sh`) for consistency. Test fixtures updated
  to emit their fake banners on stderr specifically, since the previous
  stdout-based fakes could not have caught this class of bug.

### Added
- Interactive AL2023 release selection. When more than one point-release
  version is detected and the run is interactive (no `--yes`, a real
  terminal attached), `aws-patch` now lists every available version and
  prompts the administrator to choose which one to upgrade to, instead
  of always silently picking the highest:
  ```
  == Amazon Linux release update available ==
  Multiple Amazon Linux 2023 point releases are available:
    1) 2023.8.20250707
    2) 2023.10.20260105
    3) 2023.11.20260526
    4) 2023.12.20260629 (latest)
  Which release would you like to upgrade to? [1-4] (default: 4, ...):
  ```
  Falls back automatically to the highest version when: fewer than two
  candidates exist, no interactive terminal is attached (including when
  run via `curl | sudo bash`, since stdin is the installer's pipe in
  that invocation style), the administrator presses Enter, or an invalid
  selection is entered. `--yes` always takes the highest with no prompt.
  New `pm_list_releasever_updates` (`lib/dnf.sh`) exposes the full
  candidate list; the selection logic itself
  (`_releasever_resolve_choice`) is factored out as pure, tty-independent
  logic and covered by dedicated unit tests.
- Closing reminder after a live release upgrade: `aws-patch` now prints
  an explicit note to run it again, since crossing a release boundary can
  expose packages (including a newer kernel) that weren't visible under
  the previous release.
- Documented, research-backed answer (not assumed) on whether Amazon
  Linux 2 has an equivalent release-notification mechanism: it does not.
  AL2023's point-release system is implemented by a dnf-specific
  `release-notification` plugin that AL2's yum doesn't ship, and AL2's
  package model doesn't have discrete dated snapshots the way AL2023
  does -- a plain patch run on AL2 already surfaces everything available,
  including new kernels, with no separate release-crossing step needed.
  See `docs/troubleshooting.md` for the full explanation.

## [1.4.0] - 2026-07-07

### Changed
- Both the AL2023 release-update check (`pm_check_releasever_update`,
  `lib/dnf.sh`) and the predictive kernel-availability check
  (`pm_get_latest_available_kernel`, `lib/yum.sh` + `lib/dnf.sh`) now
  collect candidates from every available detection source
  unconditionally, then pick the true highest across all of them --
  rather than stopping at the first source that returns something.
  Different dnf/yum configurations, repo setups, and AL2023 images
  surface this information under different commands, so checking more
  sources reduces the chance of missing a real update:
  - `pm_check_releasever_update`: merges results from `dnf check-update`,
    `dnf check-update kernel`, and `dnf check-release-update` (when
    present).
  - `pm_get_latest_available_kernel` (yum): merges results from
    `yum list kernel --showduplicates` and `yum check-update kernel`.
  - `pm_get_latest_available_kernel` (dnf): merges results from
    `dnf list available kernel`, `dnf list kernel`, and
    `dnf check-update kernel`.
- Added regression tests proving this "collect from anywhere" behavior:
  a case for each function where one source returns nothing but another
  still has the data, confirming the update is still correctly detected.

## [1.3.1] - 2026-07-07

### Fixed
- **AL2023 release detection produced no output on a real host.**
  `pm_check_releasever_update` (`lib/dnf.sh`) previously used
  `dnf upgrade --refresh --assumeno` to trigger and capture AL2023's
  release-notification WARNING banner. Verified against a real AL2023
  instance: that combination does not reliably trigger the banner (likely
  because `--assumeno` causes dnf to abort before reaching the plugin
  hook that prints it), so `--check`/live runs silently reported nothing,
  even when 20+ newer point releases were available. Switched primary
  detection to `dnf check-update` (and `dnf check-update kernel` as a
  secondary attempt), which is what was confirmed to actually trigger the
  banner in practice. `dnf check-release-update` remains as a final
  fallback for images that ship it.
- **Kernel-availability check used an unverified `yum`/`dnf` invocation.**
  `pm_get_latest_available_kernel` (`lib/yum.sh`) used
  `yum list available kernel --showduplicates`; switched to plain
  `yum list kernel --showduplicates` (no `available` filter), matching
  the exact command confirmed to return real data on a live Amazon Linux
  2 host. The `dnf` equivalent (`lib/dnf.sh`) now falls back to plain
  `dnf list kernel` if the `available`-filtered query returns nothing,
  for the same reason.
- Regression tests updated to reproduce the real, full AL2023 banner
  reported from a live host (20 versions spanning four different months,
  deliberately out of chronological order in the listing) rather than a
  small synthetic sample, and to invoke the corrected `dnf check-update`
  / `yum list kernel --showduplicates` commands.

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

[1.8.1]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.8.1
[1.8.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.8.0
[1.7.1]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.7.1
[1.7.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.7.0
[1.6.1]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.6.1
[1.6.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.6.0
[1.5.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.5.0
[1.4.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.4.0
[1.3.1]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.3.1
[1.3.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.3.0
[1.2.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.2.0
[1.1.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.1.0
[1.0.1]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.0.1
[1.0.0]: https://github.com/yousafkhamza/aws-patch/releases/tag/v1.0.0
