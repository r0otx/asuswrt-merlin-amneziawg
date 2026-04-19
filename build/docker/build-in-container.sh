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

# Build each .ipk. The merlin-addon is arch-independent (all shell/asp/js),
# the go daemon and tools binaries are per-arch.
for pkg in amneziawg-go amneziawg-tools amneziawg-merlin-addon; do
    case "${pkg}" in
        amneziawg-merlin-addon) _arch="all" ;;
        *) _arch="${TARGET_ARCH}" ;;
    esac
    "${REPO_ROOT}/build/ci/make_ipk.sh" "${pkg}" "${_arch}" \
        "${VERSION}-${IPK_REVISION}" "${OUT_DIR}"
done

printf 'Produced in %s:\n' "${OUT_DIR}" >&2
ls -la "${OUT_DIR}" >&2
