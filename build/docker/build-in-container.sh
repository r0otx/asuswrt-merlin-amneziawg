#!/bin/sh
# build/docker/build-in-container.sh — assembles .ipk files inside the builder
# image. Invoked by Dockerfile CMD.

set -eu

REPO_ROOT="/work"
OUT_DIR="${OUT_DIR:-/out}"
mkdir -p "${OUT_DIR}"

# shellcheck source=/dev/null
. "${REPO_ROOT}/build/versions.env"
VERSION="$(cat "${REPO_ROOT}/VERSION" | tr -d '[:space:]')"

# Build each .ipk
for pkg in amneziawg-go amneziawg-tools amneziawg-merlin-addon; do
    "${REPO_ROOT}/build/ci/make_ipk.sh" "${pkg}" "${TARGET_ARCH}" \
        "${VERSION}-${IPK_REVISION}" "${OUT_DIR}"
done

printf 'Produced in %s:\n' "${OUT_DIR}" >&2
ls -la "${OUT_DIR}" >&2
