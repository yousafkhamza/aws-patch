#!/usr/bin/env bash
#
# scripts/build-packages.sh
#
# Builds .deb and .rpm packages for aws-patch using fpm
# (https://github.com/jordansissel/fpm). Intended to be run in CI
# (see .github/workflows/release.yml) but works locally too, provided
# fpm and rpmbuild are installed:
#
#   sudo apt-get install -y rpm ruby ruby-dev build-essential
#   sudo gem install --no-document fpm
#   ./scripts/build-packages.sh
#
# Output: dist/aws-patch_<version>_all.deb
#         dist/aws-patch-<version>-1.noarch.rpm
#
# Installed file layout (FHS-compliant, independent of install.sh's
# /opt/aws-patch layout -- this is the package-manager-managed layout):
#   /usr/lib/aws-patch/aws-patch.sh
#   /usr/lib/aws-patch/VERSION
#   /usr/lib/aws-patch/lib/*.sh
#   /usr/bin/aws-patch                 -> symlink to the above aws-patch.sh
#   /usr/share/doc/aws-patch/{README.md,LICENSE,CHANGELOG.md}
#   /usr/share/man/man1/aws-patch.1.gz
#
# aws-patch.sh resolves its own real location by following symlinks
# (see the SCRIPT_SOURCE/SCRIPT_DIR loop near the top of aws-patch.sh),
# so invoking the installed /usr/bin/aws-patch symlink correctly finds
# /usr/lib/aws-patch/lib/*.sh regardless of this indirection.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR REPO_ROOT

if [[ ! -r "${REPO_ROOT}/VERSION" ]]; then
    echo "ERROR: VERSION file not found at ${REPO_ROOT}/VERSION" >&2
    exit 1
fi
VERSION="$(<"${REPO_ROOT}/VERSION")"
readonly VERSION

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: VERSION file '${VERSION}' is not valid semver (expected X.Y.Z)" >&2
    exit 1
fi

if ! command -v fpm >/dev/null 2>&1; then
    echo "ERROR: fpm is not installed. Install it with:" >&2
    echo "  sudo apt-get install -y rpm ruby ruby-dev build-essential" >&2
    echo "  sudo gem install --no-document fpm" >&2
    exit 1
fi

OUTPUT_DIR="${REPO_ROOT}/dist"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aws-patch-pkg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "Building aws-patch v${VERSION} packages..."
echo "Staging directory: ${STAGING_DIR}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Stage the FHS-compliant file layout
# ---------------------------------------------------------------------------
mkdir -p \
    "${STAGING_DIR}/usr/lib/aws-patch/lib" \
    "${STAGING_DIR}/usr/bin" \
    "${STAGING_DIR}/usr/share/doc/aws-patch" \
    "${STAGING_DIR}/usr/share/man/man1"

cp "${REPO_ROOT}/aws-patch.sh" "${STAGING_DIR}/usr/lib/aws-patch/aws-patch.sh"
cp "${REPO_ROOT}/VERSION" "${STAGING_DIR}/usr/lib/aws-patch/VERSION"
cp "${REPO_ROOT}"/lib/*.sh "${STAGING_DIR}/usr/lib/aws-patch/lib/"
chmod 0755 "${STAGING_DIR}/usr/lib/aws-patch/aws-patch.sh"
chmod 0644 "${STAGING_DIR}/usr/lib/aws-patch/lib/"*.sh
chmod 0644 "${STAGING_DIR}/usr/lib/aws-patch/VERSION"

ln -s /usr/lib/aws-patch/aws-patch.sh "${STAGING_DIR}/usr/bin/aws-patch"

cp "${REPO_ROOT}/README.md" "${STAGING_DIR}/usr/share/doc/aws-patch/README.md"
cp "${REPO_ROOT}/LICENSE" "${STAGING_DIR}/usr/share/doc/aws-patch/LICENSE"
cp "${REPO_ROOT}/CHANGELOG.md" "${STAGING_DIR}/usr/share/doc/aws-patch/CHANGELOG.md"

if [[ -f "${REPO_ROOT}/docs/aws-patch.1" ]]; then
    cp "${REPO_ROOT}/docs/aws-patch.1" "${STAGING_DIR}/usr/share/man/man1/aws-patch.1"
    gzip -9 -f "${STAGING_DIR}/usr/share/man/man1/aws-patch.1"
fi

# ---------------------------------------------------------------------------
# Package metadata common to both formats
# ---------------------------------------------------------------------------
COMMON_FPM_ARGS=(
    -s dir
    -C "$STAGING_DIR"
    -n aws-patch
    -v "$VERSION"
    --license MIT
    --maintainer "yousafkhamza <https://github.com/yousafkhamza>"
    --url "https://github.com/yousafkhamza/aws-patch"
    --description "Production-grade Linux patch automation for AWS EC2 (Ubuntu, Debian, Amazon Linux, RHEL family)"
    --architecture all
    --depends bash
    --category admin
    usr
)

echo ""
echo "Building .deb..."
fpm -t deb \
    -p "${OUTPUT_DIR}/aws-patch_${VERSION}_all.deb" \
    --deb-no-default-config-files \
    "${COMMON_FPM_ARGS[@]}"

echo ""
echo "Building .rpm..."
fpm -t rpm \
    -p "${OUTPUT_DIR}/aws-patch-${VERSION}-1.noarch.rpm" \
    --rpm-os linux \
    "${COMMON_FPM_ARGS[@]}"

echo ""
echo "Packages built:"
ls -la "$OUTPUT_DIR"
