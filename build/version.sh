#!/bin/sh
# build/version.sh — renders /VERSION into derived files.
# Exits non-zero if /VERSION is missing or malformed.
#
# Derived outputs:
#   addon/VERSION                     (plain version string)
#   addon/amneziawg.sh AWG_VERSION   (sed-replaced in place)
#   build/ipk/*/control              (rendered from *.template by render_control.sh)
#
# This script is idempotent.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

if [ ! -f "${VERSION_FILE}" ]; then
  printf 'ERROR: %s not found\n' "${VERSION_FILE}" >&2
  exit 1
fi

VERSION="$(cat "${VERSION_FILE}" | tr -d '[:space:]')"

# SemVer validation: X.Y.Z, optionally with -prerelease suffix.
case "${VERSION}" in
  [0-9]*.[0-9]*.[0-9]*)
    : # ok
    ;;
  *)
    printf 'ERROR: version %s does not match SemVer X.Y.Z[-suffix]\n' "${VERSION}" >&2
    exit 1
    ;;
esac

# Render addon/VERSION
printf '%s\n' "${VERSION}" > "${REPO_ROOT}/addon/VERSION"

# Render addon/amneziawg.sh AWG_VERSION line
if [ -f "${REPO_ROOT}/addon/amneziawg.sh" ]; then
  awk -v v="${VERSION}" '
    /^AWG_VERSION=/ { printf "AWG_VERSION=\"%s\"\n", v; next }
    { print }
  ' "${REPO_ROOT}/addon/amneziawg.sh" > "${REPO_ROOT}/addon/amneziawg.sh.tmp"
  mv "${REPO_ROOT}/addon/amneziawg.sh.tmp" "${REPO_ROOT}/addon/amneziawg.sh"
  chmod 755 "${REPO_ROOT}/addon/amneziawg.sh"
fi

# Render asp meta tag (sed in place)
if [ -f "${REPO_ROOT}/addon/webui/amneziawg_page.asp" ]; then
  sed -i.bak -E \
    "s#<meta name=\"version\" content=\"[^\"]*\">#<meta name=\"version\" content=\"${VERSION}\">#" \
    "${REPO_ROOT}/addon/webui/amneziawg_page.asp"
  rm -f "${REPO_ROOT}/addon/webui/amneziawg_page.asp.bak"
fi

printf 'Rendered VERSION=%s into derived files.\n' "${VERSION}"
