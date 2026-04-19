#!/bin/sh
# build/ci/check_reproducible.sh — double-builds all .ipk and compares sha256.
#
# Expects `make build-all` to produce dist/<arch>/*.ipk.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

mkdir -p dist1 dist2

# First build
rm -rf dist
make build-all
cp -a dist/. dist1/

# Second build
rm -rf dist
make build-all
cp -a dist/. dist2/

fail=0
for f in $(cd dist1 && find . -name '*.ipk'); do
    if ! cmp -s "dist1/${f}" "dist2/${f}"; then
        printf 'FAIL: %s differs between builds\n' "${f}" >&2
        sha256sum "dist1/${f}" "dist2/${f}" >&2
        fail=1
    else
        printf 'OK:   %s is reproducible\n' "${f}"
    fi
done

rm -rf dist1 dist2
exit ${fail}
