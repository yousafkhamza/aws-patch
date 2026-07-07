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
