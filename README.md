# aws-patch

An enterprise-grade Linux patch utility for AWS EC2 instances. `aws-patch`
detects your OS and package manager, applies updates safely, tells you
whether a reboot is needed, and never touches your bootloader or your
installed kernels.

[![ShellCheck](https://github.com/aws-patch/aws-patch/actions/workflows/shellcheck.yml/badge.svg)](.github/workflows/shellcheck.yml)
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

## Installation

### One-line install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/aws-patch/aws-patch/main/install.sh | sudo bash
```

With arguments (e.g. auto-reboot if needed):

```bash
curl -fsSL https://raw.githubusercontent.com/aws-patch/aws-patch/main/install.sh | sudo bash -s -- --reboot
```

The installer downloads every required file, verifies each one (non-empty,
valid shebang) before executing anything, installs to `/opt/aws-patch`,
symlinks `aws-patch` into `/usr/local/bin`, and cleans up its temp
directory on exit — success or failure.

### Manual install

```bash
git clone https://github.com/aws-patch/aws-patch.git
cd aws-patch
sudo ./aws-patch.sh --check
```

## Usage

```bash
sudo aws-patch.sh [OPTIONS]
```

### CLI Options

| Flag         | Description                                                       |
|--------------|--------------------------------------------------------------------|
| `--check`    | Report system/kernel/patch status only; installs nothing            |
| `--dry-run`  | Show what would be done without making any changes                  |
| `--reboot`   | Automatically reboot if a reboot is required after patching         |
| `--yes`      | Assume "yes" for prompts (non-interactive / automation-friendly)    |
| `--verbose`  | Enable debug-level console output                                   |
| `--version`  | Print version and exit                                              |
| `--help`     | Print usage and exit                                                 |

### Examples

Check current patch/kernel status without changing anything:

```bash
sudo aws-patch.sh --check
```

See what would be updated, without applying anything:

```bash
sudo aws-patch.sh --dry-run
```

Patch non-interactively (e.g. in a cron job or SSM automation document):

```bash
sudo aws-patch.sh --yes
```

Patch non-interactively and reboot automatically if the kernel changed:

```bash
sudo aws-patch.sh --yes --reboot
```

Verbose output for troubleshooting a patch run:

```bash
sudo aws-patch.sh --yes --verbose
```

### Example output

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
