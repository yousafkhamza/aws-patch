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

**Automatic resolution:** `aws-patch` detects this automatically on every
run (no flag needed) by parsing the same banner `dnf` itself prints, and
crosses the point-release boundary via `dnf upgrade -y --releasever=<version>`
*before* running the normal full upgrade and kernel-metapackage step --
so a kernel gated behind a newer release becomes reachable in the same
run. You'll see this reflected in the summary output:

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

**Manual resolution** (if you want to cross the boundary yourself first):

```bash
sudo dnf upgrade --releasever=2023.12.20260629 -y
sudo aws-patch --yes
```

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
