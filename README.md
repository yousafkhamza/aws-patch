# aws-patch

An enterprise-grade Linux patch utility for AWS EC2 instances. `aws-patch`
detects your OS and package manager, applies updates safely, tells you
whether a reboot is needed, and never touches your bootloader or your
installed kernels.

[![ShellCheck](https://github.com/yousafkhamza/aws-patch/actions/workflows/shellcheck.yml/badge.svg)](.github/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Website](https://img.shields.io/badge/site-yousafkhamza.github.io%2Faws--patch-ff9900)](https://yousafkhamza.github.io/aws-patch/)

## Why aws-patch

Patch automation scripts have a bad habit of doing too much: pruning old
kernels, rewriting GRUB, force-rebooting production instances. `aws-patch`
deliberately does none of that. It patches packages, tells you the truth
about kernel/reboot state, and leaves bootloader and reboot decisions to
you.

## Supported Operating Systems

| Distribution   | Versions              | Package Manager |
|----------------|------------------------|------------------|
| Ubuntu         | 20.04, 22.04, 24.04    | APT              |
| Debian         | 11, 12                 | APT              |
| Amazon Linux   | 2                      | YUM              |
| Amazon Linux   | 2023                   | DNF              |
| RHEL           | 7                      | YUM              |
| RHEL           | 8, 9                   | DNF              |
| Rocky Linux    | 8, 9                   | DNF              |
| AlmaLinux      | 8, 9                   | DNF              |
| CentOS         | 7                      | YUM              |

Ubuntu kernel flavor detection (Generic / AWS / Virtual / Cloud) is
automatic.

**Amazon Linux 2023 point releases:** AL2023 periodically publishes
point-release snapshots (e.g. `2023.12.20260629`) that can gate a newer
kernel behind a `dnf upgrade --releasever=<version>` boundary that a
plain `dnf upgrade` won't cross on its own. `aws-patch` detects this
automatically on every run and crosses the boundary first when needed --
see [docs/troubleshooting.md](docs/troubleshooting.md#amazon-linux-2023-nothing-to-do-but-a-newer-releasekernel-is-announced)
for details. No flag required; it's a no-op when already on the latest
release, and a no-op on every other OS. `--kernel` governs this step too
(since 1.10.5): crossing a release boundary very often bundles a kernel
bump alongside everything else, so without `--kernel` the kernel is
excluded from the release-crossing transaction the same way it's
excluded from a normal patch run. Every pending point release is also
listed with its exact command in the log, not just the one that'll be
used:

```
ℹ Available Amazon Linux point releases:
ℹ   - 2023.12.20260720  ->  dnf upgrade --releasever=2023.12.20260720
ℹ   - 2023.12.20260724  ->  dnf upgrade --releasever=2023.12.20260724
ℹ   - 2023.12.20260727 (latest)  ->  dnf upgrade --releasever=2023.12.20260727
ℹ This run will cross to 2023.12.20260727 with the kernel excluded (pass --kernel to include it).
```

**Predicting a reboot before patching:** `--check` and `--dry-run` also
report whether a newer kernel is already sitting in the repo -- not just
whether one has already been installed. This means you can know a live
patch run *will* require a reboot before you run it, not just after:

```
== aws-patch Summary ==
  ...
  Installed Kernel:      4.14.355-282.729.amzn2.x86_64
  Available Kernel:      4.14.355-284.737.amzn2.x86_64 (not yet installed)
  Reboot Required:       NO
  ...
```

## Installation

### One-line install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/yousafkhamza/aws-patch/main/install.sh | sudo bash
```

By itself this runs an **interactive** session: it detects your
environment, shows pre-flight checks and AWS recovery guidance, then asks
for confirmation before installing anything. If there's no TTY attached
(e.g. run over `curl | sudo bash` in a non-interactive shell), it safely
defaults to "no" rather than guessing — see [`--yes`](#--yes) below to run
unattended.

With arguments (e.g. non-interactive with auto-reboot if needed):

```bash
curl -fsSL https://raw.githubusercontent.com/yousafkhamza/aws-patch/main/install.sh | sudo bash -s -- --yes --reboot
```

Everything after `-s --` is forwarded verbatim to `aws-patch.sh`, so any
flag documented in [CLI Options](#cli-options) below works here too.

The installer:
- Downloads every required file (`aws-patch.sh`, `VERSION`, all of `lib/`)
  from the pinned branch/ref
- Verifies each file (non-empty, valid shebang) **before** executing
  anything — a corrupted or partial download aborts the whole install
  with no changes made
- Installs to `/opt/aws-patch` and symlinks `aws-patch` into
  `/usr/local/bin` so it's on `PATH` for future runs
- Cleans up its temporary working directory on exit, success or failure
- Executes `aws-patch.sh` immediately after install, forwarding your
  arguments

#### Pinning to a specific version

By default (`AWS_PATCH_REF=main`), the one-liner always installs whatever
is currently on `main` — so an existing command you already have saved,
e.g.:

```bash
curl -fsSL https://raw.githubusercontent.com/yousafkhamza/aws-patch/main/install.sh | sudo bash -s -- --yes --reboot
```

automatically picks up every new release (like the kernel-filtering fix
in `1.9.0` below) the next time it runs — there's nothing to change on
your end for that command specifically.

If you'd rather pin to a known-good, reproducible version instead of
always tracking `main` (recommended for production/fleet automation),
set `AWS_PATCH_REF` to a release tag:

```bash
curl -fsSL "https://raw.githubusercontent.com/yousafkhamza/aws-patch/v1.9.0/install.sh" \
  | sudo AWS_PATCH_REF=v1.9.0 bash -s -- --yes --reboot
```

Both the URL *and* the `AWS_PATCH_REF` env var need to reference the tag:
the URL controls which copy of `install.sh` you fetch first, and
`AWS_PATCH_REF` controls which ref *that copy* then downloads
`aws-patch.sh`/`lib/*` from. Check `aws-patch --version` after install to
confirm which one landed.

### Package install (.deb / .rpm)

Every [GitHub Release](https://github.com/yousafkhamza/aws-patch/releases)
includes a `.deb` and a `.rpm`, built and published automatically by CI
when a version tag is pushed.

**Debian/Ubuntu:**

```bash
curl -fsSLO https://github.com/yousafkhamza/aws-patch/releases/latest/download/aws-patch_1.5.0_all.deb
sudo dpkg -i aws-patch_1.5.0_all.deb
```

**RHEL/Amazon Linux/Rocky/AlmaLinux/CentOS:**

```bash
curl -fsSLO https://github.com/yousafkhamza/aws-patch/releases/latest/download/aws-patch-1.5.0-1.noarch.rpm
sudo rpm -i aws-patch-1.5.0-1.noarch.rpm
```

(Check the [releases page](https://github.com/yousafkhamza/aws-patch/releases)
for the exact current filename/version.) Every release also publishes a
`SHA256SUMS` file — verify with `sha256sum -c SHA256SUMS` before
installing if you want to confirm integrity.

Once installed, `aws-patch` is on `PATH` and `man aws-patch` works.
Upgrading to a new version means downloading and installing the new
package the same way; there's no repository/`apt update` integration
(see the FAQ below for why).

### Manual install

```bash
git clone https://github.com/yousafkhamza/aws-patch.git
cd aws-patch
sudo ./aws-patch.sh --check
```

Useful if you want to review the code before running it, pin to a specific
commit/tag, or run it from a private mirror (see `AWS_PATCH_REPO` /
`AWS_PATCH_REF` environment variables in `install.sh` for mirroring the
one-line installer itself).

## Usage

```bash
sudo aws-patch.sh [OPTIONS]
```

Once installed via the one-line installer, the same binary is available
as just `aws-patch` (symlinked to `/usr/local/bin/aws-patch`):

```bash
sudo aws-patch [OPTIONS]
```

### CLI Options

| Flag         | Description                                                       |
|--------------|--------------------------------------------------------------------|
| `--check`    | Report system/kernel/patch status only; installs nothing            |
| `--dry-run`  | Show what would be done without making any changes                  |
| `--kernel`   | Also install a newer kernel package if one's available (default: kernel is excluded from the run) |
| `--reboot`   | Automatically reboot if a reboot is required after patching         |
| `--yes`      | Assume "yes" for prompts (non-interactive / automation-friendly)    |
| `--broken-fix` | Automatically repair broken/unmet-dependency package state and retry once on failure |
| `--verbose`  | Enable debug-level console output                                   |
| `--version`  | Print version and exit                                              |
| `--help`     | Print usage and exit                                                 |

Each option is covered in detail below.

---

#### `--check`

Runs full detection (OS, package manager, architecture, hostname,
connectivity, disk space, kernel state) and prints the summary block —
**without installing, upgrading, or touching anything on disk.** No root
privileges are even required for this mode.

```bash
sudo aws-patch --check
```

```
== aws-patch v1.0.0 ==
== Detecting environment ==
ℹ Hostname:        ip-10-0-1-42
ℹ OS:              Ubuntu 22.04.5 LTS
ℹ Package Manager: apt
ℹ Architecture:    x86_64
== Pre-flight checks ==
✔ Internet connectivity: OK
✔ Disk space: OK
ℹ Running: 6.8.0-1060-aws | Latest installed: 6.8.0-1060-aws | Reboot required: NO | Available: 6.8.0-1063-aws (patching would require a reboot)
== aws-patch Summary ==
  ...
  Available Kernel:      6.8.0-1063-aws (not yet installed)
  Patch Status:          check_only
```

Use this for fleet-wide status reporting (see
[examples/README.md](examples/README.md#check-only-status-report-across-a-fleet-no-changes-made))
or as a pre-maintenance-window sanity check.

---

#### `--dry-run`

Runs the same detection and pre-flight checks as a live run, then prints
**exactly which package operations would execute** (`pm_update_repos`,
`pm_full_upgrade_no_kernel` by default, or `pm_full_upgrade` +
`pm_install_kernel_meta` if `--kernel` is also passed) and lists
currently-upgradable packages — again, without changing anything.

```bash
sudo aws-patch --dry-run
```

```
== Applying patches (pm=apt) ==
ℹ [dry-run] Would run: pm_update_repos
ℹ [dry-run] Would run: pm_full_upgrade_no_kernel (kernel excluded; pass --kernel to include)
ℹ [dry-run] Would list upgradable packages:
libssl3/jammy-updates 3.0.2-0ubuntu1.15 amd64 [upgradable from: 3.0.2-0ubuntu1.14]
...
```

Unlike `--check`, `--dry-run` still requires root (it needs to query the
package manager's own upgrade simulation, which several package managers
restrict to root). Combine with `--verbose` to see full command-level
detail. Ideal for change-management review before a scheduled maintenance
window — see
[examples/README.md](examples/README.md#dry-run-before-a-maintenance-window).

---

#### `--kernel`

By default, `aws-patch` excludes the kernel package from a run's upgrade
entirely — every other package patches normally, but the kernel is left
exactly as it was, so routine patching never forces a reboot decision on
you. Pass `--kernel` to also install a newer kernel if one's available:

```bash
sudo aws-patch --yes --kernel --reboot
```

This is the split most teams actually want day-to-day: patch everything
on a regular cadence without `--kernel` (no reboot risk, ever), then run
periodically with `--yes --kernel --reboot` on its own schedule — or
during an actual maintenance window — for the kernel/reboot piece.

Under the hood: on Debian/Ubuntu, the currently-installed kernel/headers/
modules packages are `apt-mark hold`-ed for the duration of the upgrade
and unheld immediately after (success or failure); on RHEL-family systems
(yum/dnf), the transaction is run with `--exclude='kernel*'` natively.
Either way, nothing is ever removed and GRUB is never touched — same
guarantees as always.

If a newer kernel is available and `--kernel` wasn't passed, the summary
says so explicitly:

```
Kernel Update:         excluded this run (pass --kernel to include)
```

`--kernel` has no effect on its own if no newer kernel is available, and
under `--check`/`--dry-run` it only affects what's reported, not what's
installed.

---

#### `--reboot`

If, after patching, the running kernel no longer matches the newest
installed kernel, `aws-patch` reboots the instance automatically instead
of just recommending it.

```bash
sudo aws-patch --yes --reboot
```

Without `--reboot`, a required reboot is always just reported and left to
you — `aws-patch` prompts interactively (or, with `--yes`, logs a warning
and skips it silently) rather than ever rebooting on its own initiative.
This flag is the **only** way `aws-patch` will reboot a machine; there is
no configuration path that causes an automatic reboot without it.

`--reboot` has no effect if no reboot is actually required, and it is
ignored entirely under `--check` or `--dry-run` (both of which only report
what *would* happen).

> **Production tip:** pair `--reboot` with a maintenance window or an SSM
> Automation document with rate control, so a fleet doesn't reboot all at
> once. See [examples/README.md](examples/README.md#aws-systems-manager-ssm-run-command-document).

---

#### `--yes`

Assumes "yes" for every interactive confirmation `aws-patch` would
otherwise ask for: the initial "proceed with patching this host?" prompt,
and (unless `--reboot` is also given) it causes a required-reboot notice
to be logged rather than prompted for. This is what makes `aws-patch`
safe to run from cron, SSM Run Command, Ansible, or any other
non-interactive context.

```bash
sudo aws-patch --yes
```

Without `--yes`, running `aws-patch` from a non-interactive shell (e.g.
piped through `curl | sudo bash`) causes every prompt to safely default to
**no** rather than silently guessing — this is exactly what happens if
you run the plain one-liner with no flags in a non-interactive shell and
it stops at "Aborted by administrator." `--yes` is how you tell it that's
intentional.

`--yes` does **not** silently skip the connectivity or disk-space
warnings — it just answers "continue anyway" on your behalf for those
specific advisory prompts, and still logs every warning it encountered.

---

#### `--broken-fix`

If a package operation (repository refresh, full upgrade, or kernel
metapackage install) fails after exhausting its normal retries,
`--broken-fix` triggers a distro-appropriate repair routine and then
retries that one operation exactly once more before giving up.

```bash
sudo aws-patch --yes --broken-fix
```

The repair routine differs by package manager, but the safety guarantees
are identical everywhere: it only repairs and reconfigures **existing**
package state — it never removes an installed kernel and never touches
GRUB or bootloader configuration.

| Package Manager | Repair routine |
|------------------|------------------|
| **apt** (Ubuntu/Debian) | `dpkg --configure -a` to finish any interrupted install, then `apt-get --fix-broken install` to resolve unmet dependencies |
| **yum** (Amazon Linux 2, RHEL 7, CentOS 7) | `yum clean all`, completes any interrupted transaction via `yum-complete-transaction --cleanup-only` (if available), deduplicates via `package-cleanup --cleandupes` (if available), then retries with `yum update -y --skip-broken` |
| **dnf** (Amazon Linux 2023, RHEL 8/9, Rocky, AlmaLinux) | `dnf clean all` + `dnf makecache`, then retries with `dnf upgrade -y --best --allowerasing --skip-broken` |

This is exactly the class of failure covered in
[docs/troubleshooting.md](docs/troubleshooting.md#unmet-dependencies--e-unmet-dependencies):
a versioned kernel-related package (e.g. `linux-headers-<version>`) left
pointing at a dependency no longer available after an interrupted or
partial prior upgrade.

If the repair itself fails, or the retried operation still fails
afterward, `aws-patch` reports the failure and exits non-zero exactly as
it would without `--broken-fix` — this flag makes recovery from a common,
narrow class of failure automatic; it does not mask or suppress genuine
failures. Full output from every attempt (including the repair step) is
always in `/var/log/aws-patch.log` for review.

---

#### `--verbose`

Enables debug-level (`log_debug`) output on the console, in addition to
what's already logged to `/var/log/aws-patch.log` regardless of this flag.
Useful for troubleshooting exactly what `aws-patch` detected and decided
at each step.

```bash
sudo aws-patch --yes --verbose
```

```
• Detected OS: Ubuntu 22.04.5 LTS (id=ubuntu version=22.04 family=debian)
• Detected package manager: apt
• Detected architecture: x86_64
• Connectivity check passed
• Disk space check passed for / (18432MB available)
...
```

This flag only affects what's printed to your terminal — the log file
always contains the full debug trail whether or not `--verbose` is set.

---

#### `--version`

Prints the installed version and exits immediately; does nothing else
(no detection, no root check).

```bash
$ aws-patch --version
aws-patch v1.0.0
```

Useful for confirming which version is installed across a fleet, or in a
CI pipeline that pins a minimum required version.

---

#### `--help`

Prints full usage information (all flags, examples, safety notes, and the
configured log file path) and exits immediately.

```bash
$ aws-patch --help
```

```
aws-patch v1.0.0
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
...
```

---

### Combining flags

Flags compose freely. A few common combinations:

| Goal                                                        | Command                                |
|---------------------------------------------------------------|------------------------------------------|
| Status report only, safe on any host                          | `sudo aws-patch --check`                  |
| Preview changes before a maintenance window                   | `sudo aws-patch --dry-run --verbose`      |
| Unattended patch, leave reboot decision to a human             | `sudo aws-patch --yes`                    |
| Fully unattended patch, including reboot if needed              | `sudo aws-patch --yes --reboot`           |
| Also install a newer kernel and reboot into it                 | `sudo aws-patch --yes --kernel --reboot`  |
| Unattended patch that auto-repairs broken dependency state       | `sudo aws-patch --yes --broken-fix`       |
| Debug a failing patch run                                      | `sudo aws-patch --yes --verbose`          |

An unrecognized flag (e.g. a typo) causes `aws-patch` to print an error
and exit with code `2` rather than silently ignoring it or guessing your
intent.

### Example output (full live run, with `--kernel`)

```
== aws-patch v1.0.0 ==

== Detecting environment ==
ℹ Hostname:        ip-10-0-1-42
ℹ OS:              Ubuntu 22.04.4 LTS
ℹ Package Manager: apt
ℹ Architecture:    x86_64

== Pre-flight checks ==
✔ Internet connectivity: OK
✔ Disk space: OK
ℹ Running: 5.15.0-100-generic | Latest installed: 5.15.0-100-generic | Reboot required: NO

== AWS Recovery Recommendations ==
  ...

== Applying patches (pm=apt) ==
✔ Refreshing package repositories (2s)
✔ Applying package upgrades (kernel included) (48s)
✔ Ensuring latest kernel package is installed (3s)

== aws-patch Summary ==
  Hostname:              ip-10-0-1-42
  Operating System:      Ubuntu 22.04.4 LTS
  Package Manager:       apt
  Architecture:          x86_64
  Running Kernel:        5.15.0-100-generic
  Installed Kernel:      5.15.0-105-generic
  Reboot Required:       YES
  Security Updates:      7
  Patch Status:          completed
  Log File:              /var/log/aws-patch.log
```

### Example output (default run, no `--kernel`)

Same host, same available kernel update, but `--kernel` wasn't passed:
everything else patches normally, the kernel is left alone, and the
summary says so explicitly instead of silently doing nothing about it.

```
== Applying patches (pm=apt) ==
✔ Refreshing package repositories (2s)
✔ Applying package upgrades (kernel excluded) (46s)
⚠ Skipped installing kernel 5.15.0-105-generic (--kernel not passed). Re-run with --kernel to install it.

== aws-patch Summary ==
  ...
  Running Kernel:        5.15.0-100-generic
  Installed Kernel:      5.15.0-100-generic
  Available Kernel:      5.15.0-105-generic (not yet installed)
  Kernel Update:         excluded this run (pass --kernel to include)
  Reboot Required:       NO
  Security Updates:      7
  Patch Status:          completed
```

## Safety guarantees

These are structural, not configurable:

- **Never removes an installed kernel.** `installonly_limit` is explicitly
  overridden to unlimited on every yum/dnf run so a system-wide config
  can't prune kernels as a side effect.
- **Never installs a new kernel unless you ask.** By default the kernel
  package is excluded from a run's upgrade entirely; pass `--kernel` to
  include it.
- **Never modifies GRUB.** No `update-grub`, `grub2-mkconfig`, or config
  file edits, ever.
- **Never changes the default boot entry.** No `grub2-set-default`,
  `grub2-reboot`, or equivalent is called anywhere in this codebase.
- **Never force-reboots.** A reboot happens only if you pass `--reboot`,
  or you interactively confirm it. Otherwise `aws-patch` tells you a
  reboot is recommended and stops there.

## Kernel & reboot logic

`aws-patch` compares the currently running kernel (`uname -r`) against the
newest kernel package installed on disk, cross-checked against the
distro-native reboot indicator where available (`needs-restarting -r` on
RHEL-family systems, `/var/run/reboot-required` on Debian-family systems).
If they differ, a reboot is recommended in the summary. Nothing more
happens unless you asked for `--reboot`.

**Valid candidates only (since 1.9.0):** before picking a "latest"
kernel version, `aws-patch` filters out anything that merely *looks* like
a kernel version string but isn't a real, bootable, current-architecture
build:

- Debian/Ubuntu: `-dbgsym`, `-dbg`, and `-unsigned` packages (e.g.
  `linux-image-6.8.0-31-generic-dbgsym` ships no bootable kernel, but its
  name would otherwise sort as a valid — sometimes higher — version).
- RHEL-family (yum/dnf): candidates are anchored to the host's detected
  architecture, excluding `kernel.src` (a source RPM, not installable)
  and any other architecture's build that a multilib-capable
  configuration might otherwise surface.

This is automatic and requires no flag; it just means the
`Installed Kernel` / `Available Kernel` fields in `--check`/`--dry-run`
output and the final summary can no longer be thrown off by a
non-bootable package that happened to sort highest.

**Stale database entry detection (since 1.10.2):** a package manager's
own database can end up recording a kernel as "installed" when its
actual boot files were never written -- almost always caused by a
kernel transaction that got interrupted partway through. Before ever
recommending a reboot, `aws-patch` now checks that the "latest
installed" kernel actually has a `/boot/vmlinuz-<version>` file on
disk. If it doesn't, the summary reports `Reboot Required: STALE ENTRY`
instead of a misleading plain `YES`, `--reboot` is skipped entirely
(rebooting can't load a kernel whose files don't exist), and the exact
remediation is logged.

**GRUB default mismatch detection (since 1.10.3, RHEL-family only):** a
kernel can be genuinely, correctly installed and still not be what a
reboot would actually load, if GRUB's own default boot entry was never
updated to point at it (normally automatic via the kernel package's own
scriptlets, but can fail to complete after an interrupted transaction).
Where `grubby` is available, `aws-patch` checks the current default
before recommending a reboot; a mismatch reports
`Reboot Required: GRUB DEFAULT MISMATCH`, skips `--reboot` (it would
just restart into the same kernel), and logs the exact `grubby
--set-default` command to run first. Unverifiable on systems without
`grubby` (most Debian/Ubuntu installs) -- there it's simply not checked,
never blocked.

See
[docs/troubleshooting.md#stale-kernel-database-entry](docs/troubleshooting.md#stale-kernel-database-entry)
and
[docs/troubleshooting.md#grub-default-not-updated-to-the-new-kernel](docs/troubleshooting.md#grub-default-not-updated-to-the-new-kernel)
for the full recovery steps.

## AWS recovery guidance

Before patching, `aws-patch` prints (but never executes) recommended AWS
CLI commands for creating a pre-patch AMI and EBS snapshots, plus recovery
steps if a reboot leaves an instance unreachable (attach the root volume
to a rescue instance, use the EC2 Serial Console, or roll back to the
pre-patch AMI). See [docs/recovery.md](docs/recovery.md) for the full
guide.

## Logging

Every run is logged with timestamps to `/var/log/aws-patch.log` (falls
back to `/tmp/aws-patch-<uid>.log` if that path isn't writable). Use
`--verbose` to also see debug-level detail on the console.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues:
connectivity failures, low disk space, security-plugin errors on
RHEL/CentOS 7, and package manager lock conflicts.

## Testing

```bash
./tests/run_tests.sh
```

Runs a self-contained suite (no root, no network required) covering
version-comparison logic, OS/architecture detection, kernel-comparison
logic (against fake installed-kernel data), and CLI argument handling.
Also validated in CI via `bash -n` and ShellCheck on every push
(see `.github/workflows/shellcheck.yml`).

## FAQ

**Does aws-patch reboot my instance automatically?**
Only if you pass `--reboot`, or you say yes to the interactive prompt.
Never otherwise.

**Does aws-patch install a new kernel automatically?**
No, not by default. A run excludes the kernel package from its upgrade
entirely unless you pass `--kernel` (see [`--kernel`](#--kernel)).
Everything else still patches normally.

**Why did my `curl | sudo bash` install stop with "Aborted by administrator"?**
Because no flag was passed to authorize the patch, and piping through
`curl | sudo bash` gives `aws-patch` no interactive terminal to prompt on
— so it safely defaults to "no". Add `--yes` (see [`--yes`](#--yes)) to
run unattended.

**Does aws-patch delete old kernels to save disk space?**
No, never. Kernel pruning is explicitly disabled on every run.

**What if the package manager thinks a kernel is installed but it isn't really there?**
`aws-patch` verifies the "latest installed" kernel actually has boot
files on disk, and (where `grubby` is available) that GRUB's default
actually points at it, before ever recommending a reboot. If either
check fails, the summary reports `STALE ENTRY` or `GRUB DEFAULT
MISMATCH` instead of a plain `YES`, `--reboot` is skipped, and the fix
is logged — see
[docs/troubleshooting.md#stale-kernel-database-entry](docs/troubleshooting.md#stale-kernel-database-entry)
and
[docs/troubleshooting.md#grub-default-not-updated-to-the-new-kernel](docs/troubleshooting.md#grub-default-not-updated-to-the-new-kernel).

**Can I run this outside of AWS?**
Yes. Detection and patching logic work on any matching OS. Only the
recovery-guidance section is AWS-specific, and it's purely informational.

**Does it call the AWS CLI?**
No. `aws-patch` never invokes `aws ec2 ...` itself; it only prints the
commands you may want to run yourself, or wire into your own pipeline.

**What if my package manager is locked by another process?**
`aws-patch` retries transient failures (repository refresh, upgrade
commands) with a short backoff. See
[docs/troubleshooting.md](docs/troubleshooting.md#package-manager-locks)
for manual resolution steps.

**On Amazon Linux 2023, `dnf upgrade` shows a newer release is available but says "Nothing to do" -- does aws-patch handle that?**
Yes, automatically, every run — every pending point release is logged
with its exact command, not just the one that'll be used. If multiple
point releases are available and you're running interactively (no
`--yes`), you'll be asked which one to upgrade to. This step respects
`--kernel` too: without it, the kernel is excluded from the
release-crossing transaction the same way it's excluded from a normal
patch run. See
[docs/troubleshooting.md](docs/troubleshooting.md#amazon-linux-2023-nothing-to-do-but-a-newer-releasekernel-is-announced).

**Does Amazon Linux 2 have the same point-release mechanism?**
No -- researched and confirmed, not assumed. AL2023's point-release
system is implemented by a dnf-specific plugin that AL2's yum doesn't
ship, and AL2's package model doesn't have discrete dated snapshots the
way AL2023 does. A plain patch run on AL2 already picks up everything
available, including new kernels -- see
[docs/troubleshooting.md](docs/troubleshooting.md#amazon-linux-2-yum-is-there-an-equivalent-release-notification-mechanism)
for the full explanation.

**Why isn't there a real `apt`/`yum` repository (`apt install aws-patch` with auto-updates)?**
That needs signed packages (a GPG key and its whole trust/rotation
story) plus hosted, generated repo metadata (`Packages.gz`/`Release` for
APT, `createrepo` output for DNF/YUM) -- meaningfully more moving parts
than downloading a `.deb`/`.rpm` from a release. The current model
(build both formats in CI, attach to each GitHub Release, verify with
`SHA256SUMS`) covers "install a specific version with one command" without
that overhead. A full repo is a reasonable future step if there's demand.

## Contributing

Contributions are welcome. Please:

1. Keep package-manager-specific logic inside `lib/apt.sh`, `lib/yum.sh`,
   or `lib/dnf.sh` — never in `lib/common.sh`.
2. Keep kernel-comparison logic inside `lib/kernel.sh` only.
3. Run `./tests/run_tests.sh` and `shellcheck -x aws-patch.sh install.sh lib/*.sh tests/*.sh`
   before opening a PR — both must pass cleanly.
4. Never introduce GRUB/bootloader automation, kernel deletion, or
   automatic reboots outside the existing `--reboot` flag.

See [CHANGELOG.md](CHANGELOG.md) for release history.

### Release process (maintainers)

1. Bump the `VERSION` file (semver: `X.Y.Z`) and add a matching entry at
   the top of `CHANGELOG.md` (`## [X.Y.Z] - YYYY-MM-DD`) — the release
   notes are generated directly from this section.
2. Commit, then tag and push:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
3. Pushing the tag triggers `.github/workflows/release.yml`, which:
   - Re-runs the full lint/test suite (`bash -n`, ShellCheck,
     `tests/run_tests.sh`) as a hard gate
   - Verifies the `VERSION` file matches the pushed tag (fails the
     release if they've drifted)
   - Builds `.deb` and `.rpm` packages via `scripts/build-packages.sh`
     (uses [fpm](https://github.com/jordansissel/fpm))
   - Builds a source tarball and `SHA256SUMS`
   - Publishes a GitHub Release with all of the above attached and
     release notes pulled from `CHANGELOG.md`
   - Deploys `docs/` to GitHub Pages (via `.github/workflows/pages.yml`,
     called as a job) in parallel with the package build

To build packages locally without pushing a tag (e.g. to sanity-check
before a release):

```bash
sudo apt-get install -y rpm ruby ruby-dev build-essential
sudo gem install --no-document fpm
./scripts/build-packages.sh
# outputs to dist/
```

### Project site (GitHub Pages)

[yousafkhamza.github.io/aws-patch](https://yousafkhamza.github.io/aws-patch/)
is a static landing page at `docs/index.html`. It fetches the latest
release directly from the GitHub API at load time (`GET
/repos/yousafkhamza/aws-patch/releases/latest`), so it always reflects
whatever was most recently published — nothing to update by hand when a
new version ships.

Deployment is fully automated via GitHub Actions
(`.github/workflows/pages.yml`, using the official
`actions/configure-pages` → `upload-pages-artifact` →
`deploy-pages` flow) and runs two ways:

- **On every push to `main` that touches `docs/**`** — so the site
  stays current the moment you tweak `index.html`, styling, or copy,
  independent of cutting a release.
- **As part of the release pipeline** — `.github/workflows/release.yml`
  calls `pages.yml` as a job (running in parallel with the package
  build, both gated behind the lint/test suite passing first), so a
  single `git push origin vX.Y.Z` handles tests, `.deb`/`.rpm`
  packages, the GitHub Release, *and* the Pages deploy together.

**One-time setup** (repository owner, via the GitHub web UI): go to
**Settings → Pages** and set **Source** to **GitHub Actions** (not
"Deploy from a branch"). If this repo previously had "Deploy from a
branch" selected, switch it — the two mechanisms don't share state, and
only one can be active. GitHub also switches this automatically to
"GitHub Actions" the first time `pages.yml` deploys successfully, so
this step is a safety net more than a hard requirement.

After that, pushing to `main` (with a `docs/` change) or pushing a
release tag is all it takes — check the **Actions** tab for the "Deploy
Pages" run, and the **Environments** tab (or the Actions run summary)
for the live URL once it completes.

If the page's client-side API call fails (e.g. hourly rate limit from
an unauthenticated client), it falls back to a direct link to the
[Releases page](https://github.com/yousafkhamza/aws-patch/releases)
rather than showing a broken UI.

## License

[MIT](LICENSE)
