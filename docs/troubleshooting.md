# Troubleshooting

## Connectivity check failed

**Symptom:**
```
⚠ Connectivity check failed (no route to common public endpoints)
```

**Cause:** `aws-patch` attempts an outbound HTTPS connection to a couple of
well-known public endpoints as a quick sanity check before touching
package repositories. This can fail because of:

- Missing outbound internet access (e.g. private subnet with no NAT
  gateway/instance and no VPC endpoint for the package repos you need)
- A restrictive security group or NACL blocking outbound 443
- A corporate proxy that isn't configured in the shell environment

**Resolution:**
- If your instance uses private package mirrors (e.g. an internal APT/YUM
  repo, or VPC endpoints for Amazon Linux repos), this warning is
  expected and can be safely acknowledged when prompted.
- If you expect public internet access, verify NAT gateway/route table
  configuration and security group egress rules.
- `aws-patch --check` and `--dry-run` never block on this; only a live
  patch run will ask for confirmation before continuing.

## `--check` says "Reboot Required: NO" but I know a newer kernel exists

**Symptom:** `yum list kernel --showduplicates` (or `apt-cache policy`,
`dnf list available kernel`) shows a newer kernel build than
`uname -r`, but `aws-patch --check` reports `Reboot Required: NO`.

**This is expected, and not a conflict.** `Reboot Required` answers "is
the running kernel different from what's currently *installed*?" Since
`--check` never installs anything, that comparison will always say NO
until a real patch run actually installs the newer kernel.

To see whether patching *would* pull in a newer kernel -- before running
it -- look at the `Available Kernel` line instead, which compares the
running/installed kernel against what the **repo** currently offers:

```
== aws-patch Summary ==
  Installed Kernel:      4.14.355-282.729.amzn2.x86_64
  Available Kernel:      4.14.355-284.737.amzn2.x86_64 (not yet installed)
  Reboot Required:       NO
```

If `Available Kernel` is present, a live `aws-patch --yes` run will
install it and will then require a reboot, even though `--check` alone
correctly reports NO beforehand.

## Amazon Linux 2023: "Nothing to do" but a newer release/kernel is announced

**Symptom:**
```
WARNING:
  A newer release of "Amazon Linux" is available.

  Available Versions:

  Version 2023.12.20260629:
    Run the following command to upgrade to 2023.12.20260629:
      dnf upgrade --releasever=2023.12.20260629
...
Dependencies resolved.
Nothing to do.
Complete!
```

**Cause:** Amazon Linux 2023 ships periodic point-release snapshots (e.g.
`2023.12.20260629`) that bundle a coordinated set of repo metadata --
sometimes including a newer kernel. A plain `dnf upgrade` only updates
packages *within* the release currently pinned; it does not cross a
point-release boundary on its own, which is why it can report "Nothing to
do" even while the WARNING banner above it announces a newer snapshot.
This mechanism is implemented by dnf's own `release-notification` plugin
(visible in `dnf upgrade -v`'s plugin list), which is specific to Amazon
Linux 2023's dnf-based tooling.

**A note on why this was tricky to detect reliably:** the WARNING banner
is printed on **stderr**, not stdout. A command like
`dnf check-update kernel | head` still shows it because piping only
redirects stdout -- stderr passes straight through to the terminal. Any
automation that captures dnf's output with stderr discarded (e.g.
`$(dnf check-update 2>/dev/null)`) will silently miss the banner
entirely. `aws-patch` captures with `2>&1` specifically to avoid this.

**Automatic resolution:** `aws-patch` detects this automatically on every
run (no flag needed), collecting candidates from `dnf check-update`,
`dnf check-update kernel`, and `dnf check-release-update` (when present),
and crosses the point-release boundary via
`dnf upgrade -y --releasever=<version>` *before* running the normal full
upgrade and kernel-metapackage step -- so a kernel gated behind a newer
release becomes reachable in the same run. You'll see this reflected in
the summary output:

```
== aws-patch Summary ==
  ...
  AL Release Update:     2023.12.20260629 available
  ...
```

and, during a live run:

```
⚠ Newer Amazon Linux release available (2023.12.20260629); upgrading release metadata before patching
```

If nothing is announced (already on the latest point release), this step
is a silent no-op -- and it's a no-op on every non-Amazon-Linux OS too.

**Choosing which release to upgrade to:** if more than one point release
is available, an interactive run (no `--yes`) lists all of them and asks
which to use:

```
== Amazon Linux release update available ==
ℹ Multiple Amazon Linux 2023 point releases are available:
  1) 2023.8.20250707
  2) 2023.10.20260105
  3) 2023.11.20260526
  4) 2023.12.20260629 (latest)
Which release would you like to upgrade to? [1-4] (default: 4, 2023.12.20260629):
```

Press Enter to accept the default (the highest/latest). `--yes` always
takes the highest automatically with no prompt.

> **Note:** this prompt requires a real interactive terminal. Running
> `aws-patch` via the one-line installer (`curl -fsSL <url> | sudo bash`)
> feeds the pipe from `curl` into stdin for the whole script, so it isn't
> a real terminal there -- the picker silently falls back to the highest
> version in that invocation style, the same way the existing "Proceed
> with patching?" confirmation already does. To get the interactive
> picker, install first, then run the installed binary directly:
> `sudo aws-patch` (no `--yes`).

After a release upgrade is applied, `aws-patch` prints a reminder to run
it again, since crossing a release boundary can newly expose packages
(including a kernel) that weren't visible under the previous release:

```
== Amazon Linux release upgrade applied ==
ℹ This run upgraded the Amazon Linux release to 2023.12.20260629.
ℹ Run aws-patch again to pick up any kernel or package now available under this release
ℹ that wasn't visible under the previous one.
```

**Manual resolution** (if you want to cross the boundary yourself first):

```bash
sudo dnf upgrade --releasever=2023.12.20260629 -y
sudo aws-patch --yes
```

## Amazon Linux 2 (yum): is there an equivalent release-notification mechanism?

**Short answer: no.** This was researched specifically, not assumed. The
point-release/release-notification system described above is implemented
by a dnf plugin (`release-notification`, part of `dnf-plugins-core`) that
ships with Amazon Linux 2023's dnf-based tooling. Amazon Linux 2 uses
yum, which has a different plugin architecture and does not ship this
plugin -- and more fundamentally, AL2's package model is a single
continuously-updated repository rather than AL2023's dated point-release
snapshots, so there's no equivalent "newer snapshot available" concept
for yum to announce in the first place. A plain `sudo yum update` (or
`aws-patch` itself) already picks up everything AL2's repos currently
offer, including new kernel builds -- there's no separate
release-crossing step needed the way there is on AL2023. This is why
`aws-patch` only implements `pm_check_releasever_update`/
`pm_upgrade_releasever` for `lib/dnf.sh` and not `lib/yum.sh`; adding a
fake equivalent for yum would just be generating output with no real
mechanism behind it.

What `aws-patch` **does** provide for Amazon Linux 2 (and every other
supported OS) is the predictive kernel-availability check described
below -- which answers a related but different question ("is there a
newer kernel sitting in the repo, whether or not there's a whole release
boundary involved") and works the same way on yum as it does on dnf.

## Unmet dependencies (`E: Unmet dependencies`, broken package state)

**Symptom (apt):**
```
E: Unmet dependencies. Try 'apt --fix-broken install' with no packages (or specify a solution).
 linux-headers-6.17.0-1017-aws : Depends: linux-aws-6.17-headers-6.17.0-1017 but it is not installed
```

**Cause:** A versioned kernel-related metapackage (headers, image, or the
`linux-aws`/`linux-generic` bundle) is left pointing at a dependency that
isn't installed — typically from an interrupted prior upgrade, or a repo
sync that rotated out an intermediate kernel version before the local
package database caught up.

**Automatic resolution:** pass `--broken-fix`. When any package operation
fails after exhausting its normal retries, `aws-patch` runs a
distro-appropriate repair routine and retries that operation once more:

```bash
sudo aws-patch --yes --broken-fix
```

- **apt** (Ubuntu/Debian): `dpkg --configure -a` followed by
  `apt-get --fix-broken install`
- **yum** (Amazon Linux 2, RHEL 7, CentOS 7): cache cleanup,
  `yum-complete-transaction --cleanup-only` and `package-cleanup --cleandupes`
  where available, then retry with `--skip-broken`
- **dnf** (Amazon Linux 2023, RHEL 8/9, Rocky, AlmaLinux): cache cleanup
  then retry with `--best --allowerasing --skip-broken`

None of these repair routines remove an installed kernel or touch
GRUB/bootloader configuration — see [Safety guarantees](../README.md#safety-guarantees).

**Manual resolution** (if `--broken-fix` doesn't resolve it, or you want
to fix it before running `aws-patch` again):

```bash
# 1. See exactly what apt thinks is broken
sudo apt-get check

# 2. Try apt's own dependency repair
sudo apt --fix-broken install -y

# 3. If that doesn't resolve it, refresh repos and try installing the
#    missing package directly
sudo apt-get update
sudo apt-get install -y <missing-package-from-the-error>

# 4. If the exact version is no longer in the repo (common after repo
#    rotation), remove the orphaned headers package instead -- you don't
#    need headers for a kernel you're not actively building modules against
sudo apt-get remove -y <orphaned-headers-package>

# 5. Confirm clean state
sudo apt-get check && sudo apt list --upgradable
```

## Low disk space warning

**Symptom:**
```
⚠ Low disk space on /: ...MB available, 1024MB recommended
```

**Resolution:**
- Free up space (`journalctl --vacuum-size=200M`, clear old logs, remove
  unused packages you control) before patching, especially before a
  kernel upgrade which needs room for both old and new kernel images.
- If you're confident there's enough room for this specific run, you can
  continue past the prompt (or pass `--yes` in automation, understanding
  the risk).

## Package manager locks / "could not get lock" errors

**Symptom (Debian/Ubuntu):**
```
Could not get lock /var/lib/dpkg/lock-frontend
```

**Symptom (RHEL-family):**
```
Existing lock /var/run/yum.pid: another copy is running as pid ...
```

**Resolution:**
- `aws-patch` automatically retries transient failures on `pm_update_repos`
  and `pm_upgrade`/`pm_full_upgrade` (up to the configured retry count with
  a short delay). If the lock persists past retries, another process
  (unattended-upgrades, cloud-init, a competing cron job) is genuinely
  holding it.
- Check for and wait out `unattended-upgr` / `packagekit` / `dnf-automatic`
  processes rather than force-killing the lock holder.

## RHEL/CentOS 7: security-only updates fail

**Symptom:**
```
⚠ yum-plugin-security not installed; attempting install for security-only updates
```

**Cause:** `yum update --security` requires `yum-plugin-security` on
RHEL/CentOS 7 (Amazon Linux 2 ships equivalent support natively).

**Resolution:**
- `aws-patch` attempts to install the plugin automatically. If that also
  fails (e.g. no repo access), it falls back to a full update instead of
  security-only, and logs the fallback clearly.
- You can pre-install the plugin yourself: `sudo yum install -y yum-plugin-security`.

## Reboot required but instance became unreachable after rebooting

See [docs/recovery.md](recovery.md) for the full AWS recovery workflow
(AMI/snapshot-based rollback, EC2 Serial Console access, rescue-volume
attachment).

## "aws-patch must be run as root"

`aws-patch.sh` requires root for any operation other than `--check` and
`--dry-run`, since package installation and (optionally) rebooting require
elevated privileges. Run with `sudo`.

## ShellCheck or bash -n failures after modifying the code

If you've customized `aws-patch` locally, re-run before committing:

```bash
bash -n aws-patch.sh install.sh lib/*.sh tests/*.sh
shellcheck -x aws-patch.sh install.sh lib/*.sh tests/*.sh
./tests/run_tests.sh
```

All three must pass cleanly — this is enforced in CI on every push and PR.
