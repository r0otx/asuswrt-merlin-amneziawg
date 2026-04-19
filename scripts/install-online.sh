#!/bin/sh
# scripts/install-online.sh — fetch, verify, and install AmneziaWG on a Merlin router.
#
# Requires: Entware (/opt/bin/opkg), curl, sha256sum, Merlin with am_addons support.
#
# Flags:
#   --yes            non-interactive (auto-confirm prompts, including v1 migration)
#   --no-migrate     skip v1 migration detection
#   --add-feed       append our opkg feed to /opt/etc/opkg.conf
#   --uninstall      remove all three packages, preserve user state
#   --purge          remove + wipe state (/opt/etc/amneziawg, awg_* keys)
#   --version <v>    install specific version (default: latest)
#   --channel <c>    stable|rc|beta (default: stable)
#   --dry-run        print actions, do not execute

set -eu

GH_USER="r0otx"
GH_REPO="asuswrt-merlin-amneziawg"
FEED_BASE="https://${GH_USER}.github.io/${GH_REPO}"

YES=0
NO_MIGRATE=0
ADD_FEED=0
UNINSTALL=0
PURGE=0
DRY=0
CHANNEL="stable"
REQ_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1 ;;
        --no-migrate) NO_MIGRATE=1 ;;
        --add-feed) ADD_FEED=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --purge) UNINSTALL=1; PURGE=1 ;;
        --dry-run) DRY=1 ;;
        --version) shift; REQ_VERSION="$1" ;;
        --channel) shift; CHANNEL="$1" ;;
        -h|--help)
            cat <<USAGE
Usage: $0 [flags]

Flags:
  --yes              Non-interactive. Auto-confirm prompts.
  --no-migrate       Skip v1 detection.
  --add-feed         Append opkg feed URL to /opt/etc/opkg.conf.
  --uninstall        Remove packages (preserve user state).
  --purge            Remove packages and wipe user state.
  --version X.Y.Z    Install specific version (default: latest GitHub release).
  --channel stable|rc|beta
                     Release channel (default: stable).
  --dry-run          Print actions without executing.
USAGE
            exit 0
            ;;
        *)
            printf 'unknown flag: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2294  # eval is intentional: POSIX sh / busybox, no arrays
run() { if [ "${DRY}" -eq 1 ]; then printf '+ %s\n' "$*"; else eval "$@"; fi; }

# ---------- preflight ----------
[ -x /opt/bin/opkg ] || die "Entware not installed (missing /opt/bin/opkg)"
nvram get rc_support 2>/dev/null | grep -q am_addons \
    || die "Asuswrt-Merlin addon support (am_addons) missing"

uname_m="$(uname -m)"
case "${uname_m}" in
    aarch64)  ARCH_PKG="aarch64-3.10";  ARCH_FEED="aarch64-k3.10" ;;
    armv7l|armv7)
              ARCH_PKG="armv7-3.2";     ARCH_FEED="armv7sf-k2.6" ;;
    *)        die "unsupported CPU arch: ${uname_m}" ;;
esac

# ---------- uninstall path ----------
if [ "${UNINSTALL}" -eq 1 ]; then
    run "opkg remove amneziawg-merlin-addon amneziawg-tools amneziawg-go"
    if [ "${PURGE}" -eq 1 ]; then
        run "rm -rf /opt/etc/amneziawg /opt/var/log/amneziawg /jffs/addons/amneziawg"
        # Strip awg_ keys from custom_settings.txt
        CS="/jffs/addons/custom_settings.txt"
        if [ -f "${CS}" ]; then
            run "awk '/^awg_/ { next } { print }' '${CS}' > '${CS}.tmp' && mv '${CS}.tmp' '${CS}'"
        fi
    fi
    printf 'Uninstall complete. Reboot recommended.\n'
    exit 0
fi

# ---------- v1 detection ----------
if [ "${NO_MIGRATE}" -eq 0 ] && [ -d /jffs/addons/amneziawg ] \
     && [ ! -d /jffs/addons/amneziawg/lib ]; then
    printf 'Detected v1 installation (no /jffs/addons/amneziawg/lib/ present).\n'
    if [ "${YES}" -eq 0 ]; then
        printf 'Migrate to v2? [y/N]: '
        read -r _ans
        case "${_ans}" in
            y|Y|yes|YES) : ;;
            *) die "aborted by user" ;;
        esac
    fi
fi

# ---------- resolve version ----------
if [ -z "${REQ_VERSION}" ]; then
    latest="$(curl -fsSL "https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/latest" \
              | awk -F'"' '/"tag_name":/ { print $4 }')"
    [ -n "${latest}" ] || die "failed to query latest release"
    REQ_VERSION="${latest#v}"
fi

TMPD="$(mktemp -d -t awg.install.XXXXXX)"
trap 'rm -rf "${TMPD}"' EXIT INT TERM

# ---------- download ----------
BASE="https://github.com/${GH_USER}/${GH_REPO}/releases/download/v${REQ_VERSION}"
run "curl -fsSL -o '${TMPD}/SHA256SUMS' '${BASE}/SHA256SUMS'"

for pkg in amneziawg-go amneziawg-tools; do
    ipk="${pkg}_${REQ_VERSION}-1_${ARCH_PKG}.ipk"
    run "curl -fsSL -o '${TMPD}/${ipk}' '${BASE}/${ipk}'"
done
run "curl -fsSL -o '${TMPD}/amneziawg-merlin-addon_${REQ_VERSION}-1_all.ipk' \
         '${BASE}/amneziawg-merlin-addon_${REQ_VERSION}-1_all.ipk'"

# ---------- verify ----------
cd "${TMPD}"
awk -v a="${ARCH_PKG}" '
    / all\.ipk$/  { print }
    $2 ~ a        { print }
    $2 ~ /_all\.ipk$/ { print }
' SHA256SUMS > SHA256SUMS.filtered
run "sha256sum -c SHA256SUMS.filtered"

# ---------- install in correct dep order ----------
run "opkg install --force-depends=no \
     amneziawg-go_${REQ_VERSION}-1_${ARCH_PKG}.ipk \
     amneziawg-tools_${REQ_VERSION}-1_${ARCH_PKG}.ipk \
     amneziawg-merlin-addon_${REQ_VERSION}-1_all.ipk"

# ---------- optional feed ----------
if [ "${ADD_FEED}" -eq 1 ]; then
    conf=/opt/etc/opkg.conf
    line="src/gz amneziawg-${CHANNEL} ${FEED_BASE}/${CHANNEL}/${ARCH_FEED}"
    if ! grep -qF "${line}" "${conf}"; then
        printf '\n%s\n' "${line}" | (if [ "${DRY}" -eq 1 ]; then cat; else tee -a "${conf}" >/dev/null; fi)
        run "opkg update"
    fi
fi

printf 'AmneziaWG v%s installed on %s.\n' "${REQ_VERSION}" "${ARCH_PKG}"
