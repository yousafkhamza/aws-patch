#!/usr/bin/env bash
# lib/dnf.sh
#
# DNF-specific implementation for Amazon Linux 2023, RHEL 8/9, Rocky Linux,
# and AlmaLinux.
#
# Implements the pm_* function contract consumed by aws-patch.sh and
# lib/kernel.sh. No other module may call dnf/rpm directly.
#
# Public functions (contract):
#   pm_name
#   pm_update_repos
#   pm_upgrade
#   pm_full_upgrade
#   pm_full_upgrade_no_kernel
#   pm_security_only
#   pm_install_kernel_meta
#   pm_get_installed_kernels
#   pm_get_latest_available_kernel
#   pm_list_upgradable
#   pm_count_security_updates
#   pm_fix_broken
#   pm_check_releasever_update   (Amazon Linux 2023 only; no-op elsewhere)
#   pm_list_releasever_updates   (Amazon Linux 2023 only; no-op elsewhere)
#   pm_upgrade_releasever        (Amazon Linux 2023 only)
#   pm_upgrade_releasever_no_kernel (Amazon Linux 2023 only)

set -Eeuo pipefail

if [[ "${_AWS_PATCH_DNF_SH_LOADED:-}" == "true" ]]; then
    return 0
fi
_AWS_PATCH_DNF_SH_LOADED="true"

pm_name() {
    echo "dnf"
}

# ---------------------------------------------------------------------------
# pm_update_repos
# ---------------------------------------------------------------------------
pm_update_repos() {
    common_retry 3 5 -- dnf makecache -y
}

# ---------------------------------------------------------------------------
# pm_upgrade
# ---------------------------------------------------------------------------
pm_upgrade() {
    common_retry 2 5 -- dnf upgrade -y
}

# ---------------------------------------------------------------------------
# pm_full_upgrade
#   `dnf upgrade` already handles obsoletes by default; --best ensures the
#   highest available versions are chosen rather than partial updates.
# ---------------------------------------------------------------------------
pm_full_upgrade() {
    common_retry 2 5 -- dnf upgrade -y --best --allowerasing
}

# ---------------------------------------------------------------------------
# pm_full_upgrade_no_kernel
#   Same as pm_full_upgrade, but the kernel package itself is excluded
#   from this transaction via dnf's native --exclude -- used when
#   --kernel was NOT passed on the command line, so a patch run applies
#   every other update without also pulling in a new kernel (and the
#   reboot that would require). Read-only w.r.t. the kernel: never
#   removes or modifies an installed kernel package.
# ---------------------------------------------------------------------------
pm_full_upgrade_no_kernel() {
    common_retry 2 5 -- dnf upgrade -y --best --allowerasing --exclude='kernel*'
}

# ---------------------------------------------------------------------------
# pm_security_only
#   Native dnf security filtering (no extra plugin needed, unlike yum on
#   RHEL/CentOS 7).
# ---------------------------------------------------------------------------
pm_security_only() {
    if dnf updateinfo --security --assumeno >/dev/null 2>&1 || true; then
        common_retry 2 5 -- dnf upgrade -y --security
    else
        log_warn "dnf security metadata unavailable; falling back to full upgrade"
        pm_upgrade
    fi
}

# ---------------------------------------------------------------------------
# pm_fix_broken
#   Attempts to repair a broken package/dependency state on dnf-based
#   systems (Amazon Linux 2023, RHEL 8/9, Rocky Linux, AlmaLinux). Common
#   causes: stale/corrupt repo metadata, or a versioned kernel-related
#   package left pointing at a version no longer present after a partial
#   prior upgrade. This function only cleans caches and lets dnf's own
#   resolver retry with --allowerasing/--skip-broken; it never removes an
#   installed kernel and never touches GRUB/bootloader configuration.
#
#   Invoked automatically by aws-patch.sh when --broken-fix is passed and
#   a package operation fails after exhausting its normal retries.
# ---------------------------------------------------------------------------
pm_fix_broken() {
    log_warn "Attempting automatic repair of broken package state (dnf)"

    # Stale/corrupt repo metadata is the most common cause of spurious
    # dependency resolution failures; clear it first.
    common_retry 1 0 -- dnf clean all || true
    common_retry 1 0 -- dnf makecache -y || true

    # Retry allowing dnf to erase conflicting duplicate packages and skip
    # ones it truly cannot resolve, rather than aborting the whole
    # transaction. This is the least destructive repair path available; it
    # never force-removes packages this tool didn't already intend to touch,
    # and installonly_limit protections for kernels remain in effect
    # elsewhere (pm_install_kernel_meta), independent of this repair step.
    common_retry 2 5 -- dnf upgrade -y --best --allowerasing --skip-broken
}

# ---------------------------------------------------------------------------
# _dnf_collect_releasever_candidates
#   Private helper (not part of the pm_* contract). Amazon Linux
#   2023-specific. AL2023 ships periodic "point release" snapshots (e.g.
#   2023.12.20260629) that bundle a coordinated set of repo metadata --
#   including, sometimes, a newer kernel. A plain `dnf upgrade` does NOT
#   cross a point-release boundary on its own; it only updates within the
#   release currently pinned via /etc/dnf/vars or the distro default,
#   which is why `dnf upgrade` can print "Nothing to do" while a newer
#   AL2023 snapshot (and a newer kernel inside it) is available and
#   announced in its own WARNING banner.
#
#   Read-only: echoes every release-version candidate found (one per
#   line, NOT deduplicated or sorted -- callers handle that), or nothing
#   if none found / not on AL2023. Collects from every source below
#   unconditionally rather than stopping at the first that returns
#   something -- different AL2023 images/dnf versions surface this
#   banner under different invocations, so the more sources checked, the
#   less likely a real update is missed:
#     1. `dnf check-update` -- read-only, safe to run anytime, and
#        confirmed to reliably trigger the release-notification plugin's
#        WARNING banner on a real AL2023 host. (`dnf upgrade --refresh
#        --assumeno` does NOT reliably trigger the same banner --
#        --assumeno appears to skip the plugin hook that prints it.)
#     2. `dnf check-update kernel` -- same mechanism, scoped to the
#        kernel package, in case a bare check-update behaves differently
#        on some images or the banner only appears when a specific
#        package is queried.
#     3. `dnf check-release-update` -- a dedicated helper some AL2023
#        images ship for exactly this check.
#
#   IMPORTANT: all three are captured with 2>&1, not 2>/dev/null. The
#   release-notification plugin's WARNING banner is emitted on stderr,
#   not stdout -- confirmed by the fact that a plain `dnf check-update
#   kernel | head` (which only pipes stdout) still displays the banner
#   on the terminal, since stderr passes through untouched. An earlier
#   version of this function used 2>/dev/null and silently discarded the
#   banner on every real host as a result, even though synthetic tests
#   (which wrote the fake banner to stdout) never caught it.
# ---------------------------------------------------------------------------
_dnf_collect_releasever_candidates() {
    if [[ "${OS_ID:-}" != "amzn" || "${OS_VERSION_ID:-}" != 2023* ]]; then
        return 0
    fi

    local candidates=""

    candidates+="$(dnf check-update 2>&1 \
        | grep -Eo 'Version 2023\.[0-9]+\.[0-9]{8}:' \
        | grep -Eo '2023\.[0-9]+\.[0-9]{8}' || true)"
    candidates+=$'\n'
    candidates+="$(dnf check-update kernel 2>&1 \
        | grep -Eo 'Version 2023\.[0-9]+\.[0-9]{8}:' \
        | grep -Eo '2023\.[0-9]+\.[0-9]{8}' || true)"

    if command -v dnf >/dev/null 2>&1 && dnf check-release-update --help >/dev/null 2>&1; then
        candidates+=$'\n'
        candidates+="$(dnf check-release-update 2>&1 \
            | grep -Eo '2023\.[0-9]+\.[0-9]{8}' || true)"
    fi

    printf '%s\n' "$candidates" | grep -E '^2023\.'
}

# ---------------------------------------------------------------------------
# _dnf_current_releasever_snapshot
#   Private helper. AL2023-specific. OS_VERSION_ID (from common_detect_os)
#   is only ever the generic major version ("2023") -- it never contains
#   the dated point-release snapshot (e.g. "2023.12.20260727"), so it
#   cannot be used on its own to tell whether a scraped candidate is
#   actually newer than what's currently running. The dated snapshot
#   only appears in PRETTY_NAME (captured as OS_NAME by common_detect_os,
#   e.g. "Amazon Linux 2023.12.20260727"), so extract it from there.
#   Echoes the dated snapshot if found, or the generic OS_VERSION_ID
#   otherwise (e.g. a freshly-launched AMI that hasn't crossed a point
#   release yet) -- either way, always something safe to compare against.
# ---------------------------------------------------------------------------
_dnf_current_releasever_snapshot() {
    local dated
    dated="$(printf '%s' "${OS_NAME:-}" | grep -Eo '2023\.[0-9]+\.[0-9]{8}' | head -n1 || true)"
    if [[ -n "$dated" ]]; then
        printf '%s' "$dated"
    else
        printf '%s' "${OS_VERSION_ID:-0}"
    fi
}

# ---------------------------------------------------------------------------
# _dnf_releasever_has_real_changes <candidate>
#   Private helper. Read-only, safe: `--assumeno` auto-declines the
#   transaction confirmation prompt, so nothing is ever installed or
#   changed -- the same trusted pattern already used elsewhere in this
#   file (pm_security_only's `dnf updateinfo --security --assumeno`).
#
#   Asks dnf directly whether upgrading to $candidate would actually
#   have any real package changes to make, rather than trusting
#   /etc/os-release's PRETTY_NAME. This exists because that file can
#   drift from dnf's actual resolved package state -- most notably after
#   a kernel/release-upgrade transaction that was interrupted partway
#   through: PRETTY_NAME can end up updated to the target release's
#   dated snapshot even though the release's real package set (e.g. its
#   kernel build) was never actually installed. A host in that state
#   would otherwise report itself as "already current" forever, even
#   though `dnf upgrade --releasever=<that exact version>` still finds
#   real content to install.
#
#   Returns 0 if dnf reports real work to do, 1 if genuinely
#   "Nothing to do" (truly already current).
# ---------------------------------------------------------------------------
_dnf_releasever_has_real_changes() {
    local candidate="$1"
    local output
    output="$(dnf upgrade --releasever="$candidate" --assumeno 2>&1 || true)"
    if printf '%s' "$output" | grep -qi 'Nothing to do'; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# pm_check_releasever_update
#   This function is read-only: it only detects whether a newer release
#   is available and echoes its version string (e.g. "2023.12.20260629"),
#   or prints nothing if already on the latest release. No-op (prints
#   nothing) on every other OS.
#
#   IMPORTANT: the release-notification banner scraped by
#   _dnf_collect_releasever_candidates lists the latest known AL2023
#   release unconditionally -- including when it's the exact release
#   you're already running. A candidate that is genuinely
#   version-greater than _dnf_current_releasever_snapshot (the common,
#   healthy case) is reported immediately, no extra check needed.
#
#   But when the candidate is NOT textually newer -- i.e. PRETTY_NAME
#   already claims that exact dated release -- this function does NOT
#   simply trust that and stay silent. PRETTY_NAME can drift from dnf's
#   actual resolved package state (see _dnf_releasever_has_real_changes
#   above for the real-world scenario this covers), so this ambiguous
#   case is confirmed authoritatively via a safe, read-only
#   `--assumeno` dry-run before deciding. This keeps both fixed bugs
#   fixed at once: no perpetual "newer release" loop when genuinely
#   current, and no false "up to date" when PRETTY_NAME is lying.
# ---------------------------------------------------------------------------
pm_check_releasever_update() {
    local latest current
    latest="$(_dnf_collect_releasever_candidates | sort -V | tail -n1 || true)"
    [[ -z "$latest" ]] && return 0

    current="$(_dnf_current_releasever_snapshot)"

    if utils_version_gt "$latest" "$current"; then
        printf '%s' "$latest"
        return 0
    fi

    # Textually "already current" -- confirm that's actually true before
    # trusting it.
    if _dnf_releasever_has_real_changes "$latest"; then
        printf '%s' "$latest"
    fi
}

# ---------------------------------------------------------------------------
# pm_list_releasever_updates
#   Read-only: echoes every distinct release-version candidate found that
#   is genuinely newer than the currently running release, one per line,
#   sorted ascending (lowest to highest). Empty output if none found /
#   not on AL2023 / already on the latest release. Used to present a
#   full list of available point releases (e.g. for interactive
#   selection) rather than just the single highest version
#   pm_check_releasever_update reports.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# pm_list_releasever_updates
#   Read-only: echoes every distinct release-version candidate found that
#   is genuinely newer than the currently running release, one per line,
#   sorted ascending (lowest to highest). Empty output if none found /
#   not on AL2023 / already on the latest release. Used to present a
#   full list of available point releases (e.g. for interactive
#   selection) rather than just the single highest version
#   pm_check_releasever_update reports.
#
#   Kept consistent with pm_check_releasever_update's drift-confirmation
#   logic (see there): the highest candidate is included if it's either
#   textually newer than the current dated snapshot, or confirmed via
#   pm_check_releasever_update to have real content despite looking
#   textually equal (PRETTY_NAME drift). Without this, an interactive
#   run could set AL_RELEASEVER_UPDATE to a confirmed-real version yet
#   present an empty selection list for it.
# ---------------------------------------------------------------------------
pm_list_releasever_updates() {
    local current confirmed_latest candidate
    current="$(_dnf_current_releasever_snapshot)"
    confirmed_latest="$(pm_check_releasever_update)"

    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if utils_version_gt "$candidate" "$current" || [[ -n "$confirmed_latest" && "$candidate" == "$confirmed_latest" ]]; then
            printf '%s\n' "$candidate"
        fi
    done < <(_dnf_collect_releasever_candidates | sort -Vu)
}

# ---------------------------------------------------------------------------
# pm_upgrade_releasever <version>
#   Moves Amazon Linux 2023 to a newer point-release snapshot, e.g.:
#     dnf upgrade -y --releasever=2023.12.20260629
#   This can change which kernel version is "latest available" for
#   pm_install_kernel_meta to pick up afterward, but this function itself
#   only updates repo metadata/package versions like any other dnf
#   upgrade -- it never removes an installed kernel and never touches
#   GRUB/bootloader configuration.
# ---------------------------------------------------------------------------
pm_upgrade_releasever() {
    local target_releasever="${1:?target releasever required}"
    log_warn "Newer Amazon Linux release available (${target_releasever}); upgrading release metadata before patching (kernel included)"
    common_retry 2 5 -- dnf upgrade -y --releasever="${target_releasever}"
}

# ---------------------------------------------------------------------------
# pm_upgrade_releasever_no_kernel <version>
#   Same as pm_upgrade_releasever, but the kernel package is excluded
#   from THIS transaction too via dnf's native --exclude -- used when
#   --kernel was NOT passed. Without this, crossing an AL2023 point
#   release would silently pull in whatever kernel that release bundles
#   regardless of --kernel, defeating the whole point of the flag: a
#   release snapshot's package set very often includes a kernel bump
#   alongside everything else. Never removes or modifies an installed
#   kernel; same guarantee as pm_full_upgrade_no_kernel.
# ---------------------------------------------------------------------------
pm_upgrade_releasever_no_kernel() {
    local target_releasever="${1:?target releasever required}"
    log_warn "Newer Amazon Linux release available (${target_releasever}); upgrading release metadata before patching (kernel excluded; pass --kernel to include)"
    common_retry 2 5 -- dnf upgrade -y --releasever="${target_releasever}" --exclude='kernel*'
}

# ---------------------------------------------------------------------------
# pm_install_kernel_meta
#   Ensures the latest kernel package is installed. installonly_limit is
#   explicitly overridden to 0 (unlimited) for this invocation so old
#   kernels are never pruned as a side effect, preserving rollback
#   capability per this project's safety requirements.
# ---------------------------------------------------------------------------
pm_install_kernel_meta() {
    log_debug "Ensuring latest kernel package is installed (installonly_limit preserved, no pruning)"

    local kernel_pkg="kernel"
    if [[ "$OS_ID" == "amzn" ]]; then
        kernel_pkg="kernel"
    fi

    common_retry 2 5 -- dnf install -y --setopt=installonly_limit=0 "$kernel_pkg"
}

# ---------------------------------------------------------------------------
# pm_get_installed_kernels
#   Read-only: lists installed kernel package versions.
# ---------------------------------------------------------------------------
pm_get_installed_kernels() {
    rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V
}

# ---------------------------------------------------------------------------
# pm_get_latest_available_kernel
#   Read-only, predictive: echoes the newest kernel version currently
#   known to dnf, whether or not it's installed yet. Lets
#   --check/--dry-run reveal that a live patch run WILL require a reboot
#   before any packages are touched. Never installs or removes anything.
#
#   Collects kernel version candidates from every source below
#   unconditionally, then picks the true highest across all of them --
#   different dnf configurations/repo setups surface available kernel
#   builds differently, so the more sources checked, the less likely a
#   real update is missed:
#     - `dnf list available kernel`
#     - `dnf list kernel` (installed + available, unfiltered)
#     - `dnf check-update kernel` (explicit update-check output)
#   Output is normalized to match pm_get_installed_kernels' format
#   ("<version>-<release>.<arch>") so the two are directly comparable.
#   The RPM epoch prefix (e.g. "1:") is stripped from each candidate
#   before comparison: `dnf`/`yum list` includes it when a package has
#   a non-zero epoch, but `rpm -q --qf '%{VERSION}-%{RELEASE}...'` in
#   pm_get_installed_kernels never does. Left in, the bare "1:" prefix
#   sorts as version-greater under `sort -V` than a plain version
#   string, so an installed kernel would be misreported as a newer
#   "available" one every single run, even with nothing to update.
# ---------------------------------------------------------------------------
pm_get_latest_available_kernel() {
    local candidates ver kernel_arch

    # Only accept lines whose package field is exactly "kernel.<ARCH>".
    # `dnf list` can also surface "kernel.src" (source RPM, not
    # installable) and, on multilib-capable configurations, other
    # architectures' builds -- either of which would be an invalid
    # candidate that could win the `sort -V | tail -n1` pick and never
    # actually match the running kernel. Anchoring to the detected $ARCH
    # keeps only real, installable candidates for this host.
    kernel_arch="${ARCH:-$(uname -m)}"

    candidates="$(dnf list available kernel -q 2>/dev/null \
        | awk -v arch="$kernel_arch" '$0 ~ "^kernel\\." arch "([[:space:]]|$)" {print $2}' | sed -E 's/^[0-9]+://' || true)"
    candidates+=$'\n'
    candidates+="$(dnf list kernel -q 2>/dev/null \
        | awk -v arch="$kernel_arch" '$0 ~ "^kernel\\." arch "([[:space:]]|$)" {print $2}' | sed -E 's/^[0-9]+://' || true)"
    candidates+=$'\n'
    candidates+="$(dnf check-update kernel -q 2>&1 \
        | awk -v arch="$kernel_arch" '$0 ~ "^kernel\\." arch "([[:space:]]|$)" {print $2}' | sed -E 's/^[0-9]+://' || true)"

    ver="$(printf '%s\n' "$candidates" | grep -E '.' | sort -V | tail -n1 || true)"

    if [[ -n "$ver" ]]; then
        printf '%s.%s' "$ver" "${ARCH:-$(uname -m)}"
    fi
}

# ---------------------------------------------------------------------------
# pm_list_upgradable
# ---------------------------------------------------------------------------
pm_list_upgradable() {
    dnf check-update -q 2>/dev/null | grep -Ev '^(Last metadata|$)' || true
}

# ---------------------------------------------------------------------------
# pm_count_security_updates
# ---------------------------------------------------------------------------
pm_count_security_updates() {
    local count
    count="$(dnf updateinfo list security 2>/dev/null | grep -c '.' || true)"
    echo "${count:-0}"
}
