#!/bin/sh
# tools/fetch.sh — download and verify pinned amneziawg-tools source.
# Idempotent: does nothing if src/ already unpacked with matching VERSION.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${REPO_ROOT}/tools"
. "${TOOLS_DIR}/pin.env"

TARBALL="${TOOLS_DIR}/cache/amneziawg-tools-${AMNEZIAWG_TOOLS_TAG}.tar.gz"
SRC_DIR="${TOOLS_DIR}/src"
VERSION_MARKER="${SRC_DIR}/.version"

mkdir -p "${TOOLS_DIR}/cache"

# Short-circuit: already unpacked at matching version
if [ -f "${VERSION_MARKER}" ] && [ "$(cat "${VERSION_MARKER}")" = "${AMNEZIAWG_TOOLS_TAG}" ]; then
    printf 'tools/src already at %s — skipping\n' "${AMNEZIAWG_TOOLS_TAG}"
    exit 0
fi

# Download tarball if absent
if [ ! -f "${TARBALL}" ]; then
    curl -fsSL --retry 3 -o "${TARBALL}" \
        "https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/tags/${AMNEZIAWG_TOOLS_TAG}.tar.gz"
fi

# Verify SHA256
actual="$(sha256sum "${TARBALL}" | awk '{print $1}')"
if [ "${actual}" != "${AMNEZIAWG_TOOLS_SHA256}" ]; then
    printf 'ERROR: SHA256 mismatch for %s\n  expected %s\n  actual   %s\n' \
        "${TARBALL}" "${AMNEZIAWG_TOOLS_SHA256}" "${actual}" >&2
    exit 1
fi

# Unpack
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${SRC_DIR}" --strip-components=1

printf '%s\n' "${AMNEZIAWG_TOOLS_TAG}" > "${VERSION_MARKER}"
printf 'Unpacked amneziawg-tools %s into %s\n' "${AMNEZIAWG_TOOLS_TAG}" "${SRC_DIR}"
