# AWS Recovery Guide

`aws-patch` never automates AWS API calls, AMI creation, snapshots, or
bootloader changes. This guide documents the manual recovery workflow that
`aws-patch` recommends (and prints) before every live patch run.

## Before patching: create a safety net

**1. Create an AMI of the instance** (no reboot required for the image
capture itself, using `--no-reboot`; note this trades a small risk of
filesystem inconsistency for zero downtime — for critical systems, allow
the reboot):

```bash
aws ec2 create-image \
  --instance-id i-0123456789abcdef0 \
  --name "pre-patch-$(date +%F)" \
  --no-reboot
```

**2. Snapshot attached EBS volumes** as an additional, faster-to-restore
safety net:

```bash
aws ec2 create-snapshot \
  --volume-id vol-0123456789abcdef0 \
  --description "pre-patch-$(date +%F)"
```

Do this for every EBS volume attached to the instance, not just the root
volume, if your application stores state elsewhere.

## If the instance becomes unreachable after a reboot

### Option A: EC2 Serial Console (fastest, if enabled)

If the EC2 Serial Console is enabled for your account/instance:

```bash
aws ec2-instance-connect send-serial-console-ssh-public-key \
  --instance-id i-0123456789abcdef0 \
  --serial-port 0 \
  --ssh-public-key file://my-key.pub
```

Then connect via the serial console to see boot messages and get an
emergency shell if the instance drops to a rescue prompt.

### Option B: Attach the root volume to a rescue instance

1. Stop the affected instance (do not terminate it).
2. Detach its root EBS volume.
3. Attach that volume as a secondary (non-root) volume to a healthy
   "rescue" instance of the same OS family.
4. Mount it, inspect `/var/log`, `/etc/fstab`, and boot configuration for
   the actual failure cause.
5. Fix the issue on the mounted volume, unmount, detach, reattach to the
   original instance as the root volume, and start it.

This is the standard EC2 troubleshooting pattern and does not require
`aws-patch` or any bootloader automation — you're working directly with
the filesystem.

### Option C: Roll back to the pre-patch AMI

If the rescue-volume approach isn't fast enough for your situation, launch
a new instance from the AMI created before patching:

```bash
aws ec2 run-instances \
  --image-id ami-0123456789abcdef0 \
  --instance-type <same-type> \
  --subnet-id <same-subnet> \
  --security-group-ids <same-sgs> \
  --key-name <same-key>
```

Redirect traffic (Elastic IP re-association, load balancer target group
update, or DNS change) to the rolled-back instance, then investigate the
original instance offline at your own pace.

## Why aws-patch doesn't automate any of this

Automating AMI creation, snapshotting, or rollback inside a patch script
means the script itself becomes a single point of failure for your
recovery path, and it needs IAM permissions far beyond "install
packages." `aws-patch` deliberately stays out of that business: it patches
packages and reports state; you (or your existing infrastructure
automation, e.g. Systems Manager Automation documents, Terraform, or your
CI/CD pipeline) own backup and recovery orchestration.
