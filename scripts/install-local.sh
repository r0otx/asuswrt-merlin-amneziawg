#!/bin/sh
# scripts/install-local.sh — install locally-built ipks onto a Merlin router
# via scp + ssh. For dev iteration; for end-users use install-online.sh.
#
# Flags:
#   --router USER@HOST  Router SSH target (default: admin@192.168.1.1)
#   --arch ARCH         Force aarch64 or armv7 (default: detect via ssh uname -m)
#   --build             Run `make build-all` first
#   --uninstall         Remove packages on the router (preserve user state)
#   --purge             Remove + wipe state
#   --dry-run           Print actions, do not execute

set -eu

ROUTER="admin@192.168.1.1"
ARCH=""
DO_BUILD=0
UNINSTALL=0
PURGE=0
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --router)    shift; ROUTER="$1" ;;
        --arch)      shift; ARCH="$1" ;;
        --build)     DO_BUILD=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --purge)     UNINSTALL=1; PURGE=1 ;;
        --dry-run)   DRY=1 ;;
        -h|--help)
            cat <<USAGE
Usage: $0 [--router USER@HOST] [--arch aarch64|armv7] [--build] [--uninstall|--purge] [--dry-run]

Examples:
  # Build then install
  $0 --build --router admin@router.lan

  # Install pre-built dist/aarch64/*.ipk
  $0 --router admin@192.168.50.1 --arch aarch64

  # Remove packages (keep state)
  $0 --router admin@router.lan --uninstall

  # Remove + wipe state
  $0 --router admin@router.lan --purge
USAGE
            exit 0
            ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

# shellcheck disable=SC2294  # POSIX sh / busybox — no arrays available
run() { if [ "${DRY}" -eq 1 ]; then printf '+ %s\n' "$*"; else eval "$@"; fi; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

# ---------- uninstall path ----------
if [ "${UNINSTALL}" -eq 1 ]; then
    if [ "${PURGE}" -eq 1 ]; then
        run "ssh '${ROUTER}' 'opkg remove amneziawg-merlin-addon amneziawg-tools amneziawg-go; rm -rf /opt/etc/amneziawg /jffs/addons/amneziawg'"
    else
        run "ssh '${ROUTER}' 'opkg remove amneziawg-merlin-addon amneziawg-tools amneziawg-go'"
    fi
    printf 'Uninstall complete on %s.\n' "${ROUTER}"
    exit 0
fi

# ---------- detect arch ----------
if [ -z "${ARCH}" ]; then
    printf 'Detecting router arch via ssh %s ...\n' "${ROUTER}"
    uname_m="$(ssh -o BatchMode=yes "${ROUTER}" 'uname -m' 2>/dev/null || true)"
    case "${uname_m}" in
        aarch64)        ARCH="aarch64" ;;
        armv7l|armv7)   ARCH="armv7" ;;
        *) die "could not detect router arch (got: '${uname_m}'). Pass --arch explicitly." ;;
    esac
    printf 'Detected arch: %s\n' "${ARCH}"
fi

# ---------- build (optional) ----------
if [ "${DO_BUILD}" -eq 1 ]; then
    if [ "${ARCH}" = "aarch64" ]; then
        run "make build-docker-aarch64"
    else
        run "make build-docker-armv7"
    fi
fi

# ---------- locate ipks ----------
DIST="${REPO_ROOT}/dist/${ARCH}"
[ -d "${DIST}" ] || die "no dist/${ARCH}/ — run with --build, or run 'make build-all' first"

GO_IPK="$(ls "${DIST}"/amneziawg-go_*.ipk 2>/dev/null | head -1)"
TOOLS_IPK="$(ls "${DIST}"/amneziawg-tools_*.ipk 2>/dev/null | head -1)"
ADDON_IPK="$(ls "${DIST}"/amneziawg-merlin-addon_*.ipk 2>/dev/null | head -1)"
[ -f "${GO_IPK}" ] && [ -f "${TOOLS_IPK}" ] && [ -f "${ADDON_IPK}" ] \
    || die "missing one or more ipks under ${DIST} — re-run with --build"

# ---------- copy + install ----------
printf 'Copying ipks to %s:/tmp/...\n' "${ROUTER}"
run "scp '${GO_IPK}' '${TOOLS_IPK}' '${ADDON_IPK}' '${ROUTER}:/tmp/'"

GO_NAME="$(basename "${GO_IPK}")"
TOOLS_NAME="$(basename "${TOOLS_IPK}")"
ADDON_NAME="$(basename "${ADDON_IPK}")"

printf 'Installing on %s ...\n' "${ROUTER}"
run "ssh '${ROUTER}' 'cd /tmp && opkg install \"${GO_NAME}\" \"${TOOLS_NAME}\" \"${ADDON_NAME}\"'"

printf 'Done. Browse to https://router/Advanced_AmneziaWG.asp to configure.\n'
