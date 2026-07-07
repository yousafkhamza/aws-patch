# aws-patch

An enterprise-grade Linux patch utility for AWS EC2 instances. `aws-patch`
detects your OS and package manager, applies updates safely, tells you
whether a reboot is needed, and never touches your bootloader or your
installed kernels.

[![ShellCheck](https://github.com/yousafkhamza/aws-patch/actions/workflows/shellcheck.yml/badge.svg)](.github/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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
release, and a no-op on every other OS.

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
`pm_full_upgrade`, `pm_install_kernel_meta`) and lists currently-upgradable
packages — again, without changing anything.

```bash
sudo aws-patch --dry-run
```

```
== Applying patches (pm=apt) ==
ℹ [dry-run] Would run: pm_update_repos
ℹ [dry-run] Would run: pm_full_upgrade
ℹ [dry-run] Would run: pm_install_kernel_meta
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
| Unattended patch that auto-repairs broken dependency state       | `sudo aws-patch --yes --broken-fix`       |
| Debug a failing patch run                                      | `sudo aws-patch --yes --verbose`          |

An unrecognized flag (e.g. a typo) causes `aws-patch` to print an error
and exit with code `2` rather than silently ignoring it or guessing your
intent.

### Example output (full live run)

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
✔ Applying package upgrades (48s)
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

## Safety guarantees

These are structural, not configurable:

- **Never removes an installed kernel.** `installonly_limit` is explicitly
  overridden to unlimited on every yum/dnf run so a system-wide config
  can't prune kernels as a side effect.
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

**Why did my `curl | sudo bash` install stop with "Aborted by administrator"?**
Because no flag was passed to authorize the patch, and piping through
`curl | sudo bash` gives `aws-patch` no interactive terminal to prompt on
— so it safely defaults to "no". Add `--yes` (see [`--yes`](#--yes)) to
run unattended.

**Does aws-patch delete old kernels to save disk space?**
No, never. Kernel pruning is explicitly disabled on every run.

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
Yes, automatically, every run. If multiple point releases are available
and you're running interactively (no `--yes`), you'll be asked which one
to upgrade to. See
[docs/troubleshooting.md](docs/troubleshooting.md#amazon-linux-2023-nothing-to-do-but-a-newer-releasekernel-is-announced).

**Does Amazon Linux 2 have the same point-release mechanism?**
No -- researched and confirmed, not assumed. AL2023's point-release
system is implemented by a dnf-specific plugin that AL2's yum doesn't
ship, and AL2's package model doesn't have discrete dated snapshots the
way AL2023 does. A plain patch run on AL2 already picks up everything
available, including new kernels -- see
[docs/troubleshooting.md](docs/troubleshooting.md#amazon-linux-2-yum-is-there-an-equivalent-release-notification-mechanism)
for the full explanation.

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

## License

[MIT](LICENSE)
