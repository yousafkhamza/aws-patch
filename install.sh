#!/usr/bin/env bash

set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/yousafkhamza/aws-patch/main"

TMP_DIR="$(mktemp -d)"

cleanup() {

rm -rf "$TMP_DIR"

}

trap cleanup EXIT

if [[ $EUID -ne 0 ]]
then

echo

echo "Run using sudo."

echo

echo "curl -fsSL ${BASE_URL}/install.sh | sudo bash"

exit 1

fi

download() {

local file="$1"

mkdir -p "$(dirname "${TMP_DIR}/${file}")"

curl -fsSL \
"${BASE_URL}/${file}" \
-o "${TMP_DIR}/${file}"

}

FILES=(

VERSION

aws-patch.sh

lib/logger.sh

)

echo

echo "Downloading AWS Patch Utility..."

echo

for f in "${FILES[@]}"

do

printf "Downloading %-25s" "$f"

download "$f"

echo " ✔"

done

chmod +x "${TMP_DIR}/aws-patch.sh"

exec bash "${TMP_DIR}/aws-patch.sh" "$@"