# Examples

## Cron job: weekly security-only patching with logging

```cron
# Every Sunday at 03:00, patch and log; never auto-reboots (admin decides)
0 3 * * 0 root /usr/local/bin/aws-patch --yes >> /var/log/aws-patch-cron.log 2>&1
```

## AWS Systems Manager (SSM) Run Command document

A minimal SSM `AWS-RunShellScript` document parameter set:

```json
{
  "commands": [
    "curl -fsSL https://raw.githubusercontent.com/aws-patch/aws-patch/main/install.sh | sudo bash -s -- --yes"
  ]
}
```

For a fleet-wide rolling patch with automatic reboot where required, target
a subset of instances at a time via SSM's rate control, e.g.
`--max-concurrency 10% --max-errors 5%`, and pass `--yes --reboot`.

## Check-only status report across a fleet (no changes made)

```bash
for host in $(cat hosts.txt); do
  echo "== $host =="
  ssh "$host" 'sudo aws-patch --check' 2>&1
done
```

## Pre-patch AMI + snapshot, then patch (manual pipeline sketch)

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTANCE_ID="i-0123456789abcdef0"

aws ec2 create-image --instance-id "$INSTANCE_ID" \
  --name "pre-patch-$(date +%F)" --no-reboot

ssh "ec2-user@$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)" \
  'sudo aws-patch --yes --reboot'
```

This mirrors the recovery guidance in `docs/recovery.md`: snapshot first,
patch second, and you always have a rollback path.

## Dry-run before a maintenance window

```bash
sudo aws-patch --dry-run --verbose | tee /tmp/aws-patch-preview.log
```

Review the preview output with your change-management process before the
actual maintenance window, then run `sudo aws-patch --yes --reboot` during
the window itself.
