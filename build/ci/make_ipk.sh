#!/bin/sh
# build/ci/make_ipk.sh — assembles a .ipk from control + data.
#
# Inputs (from runtime environment, set by Dockerfile ipk-builder stage):
#   /work                 — repo checkout
#   /in/bin/              — compiled binaries (amneziawg-go, awg, awg-quick)
#
# Usage: make_ipk.sh <package> <arch> <version> <out_dir>
#   package: amneziawg-go | amneziawg-tools | amneziawg-merlin-addon
#   arch:    aarch64-3.10 | armv7-3.2 | all
#   version: e.g. 1.0.0-1 (with revision suffix)
#   out_dir: where to place .ipk

set -eu

PKG="$1"
ARCH="$2"
VERSION="$3"
OUT_DIR="$4"

REPO_ROOT="${REPO_ROOT:-/work}"
SRC_BIN="${SRC_BIN:-/in/bin}"
EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"

mkdir -p "${OUT_DIR}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

DATA="${WORK}/data"
CONTROL="${WORK}/control"
mkdir -p "${DATA}" "${CONTROL}"

case "${PKG}" in
    amneziawg-go)
        mkdir -p "${DATA}/opt/sbin" "${DATA}/opt/share/doc/amneziawg-go"
        cp "${SRC_BIN}/amneziawg-go" "${DATA}/opt/sbin/amneziawg-go"
        chmod 755 "${DATA}/opt/sbin/amneziawg-go"
        cp "${REPO_ROOT}/LICENSE" "${DATA}/opt/share/doc/amneziawg-go/LICENSE"
        cp "${REPO_ROOT}/VERSION" "${DATA}/opt/share/doc/amneziawg-go/VERSION"
        ;;
    amneziawg-tools)
        mkdir -p "${DATA}/opt/sbin" "${DATA}/opt/share/doc/amneziawg-tools"
        cp "${SRC_BIN}/awg"       "${DATA}/opt/sbin/awg"
        cp "${SRC_BIN}/awg-quick" "${DATA}/opt/sbin/awg-quick"
        chmod 755 "${DATA}/opt/sbin/awg" "${DATA}/opt/sbin/awg-quick"
        cp "${REPO_ROOT}/tools/VERSION" "${DATA}/opt/share/doc/amneziawg-tools/VERSION"
        ;;
    amneziawg-merlin-addon)
        mkdir -p "${DATA}/jffs/addons/amneziawg" \
                 "${DATA}/opt/etc/amneziawg" \
                 "${DATA}/opt/var/log/amneziawg"
        cp -r "${REPO_ROOT}/addon/amneziawg.sh" \
              "${REPO_ROOT}/addon/lib" \
              "${REPO_ROOT}/addon/hooks" \
              "${REPO_ROOT}/addon/scripts" \
              "${REPO_ROOT}/addon/webui" \
              "${REPO_ROOT}/addon/VERSION" \
              "${DATA}/jffs/addons/amneziawg/"
        chmod 755 "${DATA}/jffs/addons/amneziawg/amneziawg.sh" \
                  "${DATA}/jffs/addons/amneziawg/scripts/uninstall.sh"
        chmod 644 "${DATA}/jffs/addons/amneziawg/lib/"*.sh
        # Minimal awg0.conf.example (real schema is user-provided)
        cat > "${DATA}/opt/etc/amneziawg/awg0.conf.example" <<'EOF'
[Interface]
PrivateKey = <generate on server>
Address = 10.0.0.2/24
DNS = 1.1.1.1

# Amnezia obfuscation parameters (server-provided)
Jc = 4
Jmin = 40
Jmax = 70

[Peer]
PublicKey = <server public key>
Endpoint = your.server.example:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
        ;;
    *)
        printf 'ERROR: unknown package %s\n' "${PKG}" >&2
        exit 1
        ;;
esac

# Compute installed size (KB)
INSTALLED_SIZE="$(du -sk "${DATA}" | awk '{print $1}')"

# Render control
"${REPO_ROOT}/build/ci/render_control.sh" \
    "${REPO_ROOT}/build/ipk/${PKG}/control.template" \
    "${VERSION}" "${ARCH}" "${INSTALLED_SIZE}" \
    "${CONTROL}/control"

# Copy maintainer scripts (these exist for all 3 packages)
for s in postinst prerm postrm conffiles; do
    if [ -f "${REPO_ROOT}/build/ipk/${PKG}/${s}" ]; then
        cp "${REPO_ROOT}/build/ipk/${PKG}/${s}" "${CONTROL}/${s}"
        [ "${s}" = "conffiles" ] || chmod 755 "${CONTROL}/${s}"
    fi
done

# Pack control.tar.gz (deterministic)
( cd "${CONTROL}" && \
  tar --mtime="@${EPOCH}" --owner=0 --group=0 --numeric-owner --sort=name \
      -cf - . | gzip -n > "${WORK}/control.tar.gz" )

# Pack data.tar.gz
( cd "${DATA}" && \
  tar --mtime="@${EPOCH}" --owner=0 --group=0 --numeric-owner --sort=name \
      -cf - . | gzip -n > "${WORK}/data.tar.gz" )

# debian-binary
printf '2.0\n' > "${WORK}/debian-binary"

# Final .ipk
IPK_NAME="${PKG}_${VERSION}_${ARCH}.ipk"
( cd "${WORK}" && \
  tar --mtime="@${EPOCH}" --owner=0 --group=0 --numeric-owner --sort=name \
      -cf - debian-binary control.tar.gz data.tar.gz | \
  gzip -n > "${OUT_DIR}/${IPK_NAME}" )

printf 'Built %s (size=%s KB)\n' "${IPK_NAME}" "${INSTALLED_SIZE}" >&2
