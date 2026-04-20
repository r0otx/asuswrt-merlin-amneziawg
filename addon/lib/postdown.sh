#!/bin/sh
# addon/lib/postdown.sh — called by awg-quick from PostDown = ... in awg0.conf.
# Removes PBR rules and firewall chains. Teardown is the reverse of postup.

INTERFACE="${1:-awg0}"

ADDON_DIR="/jffs/addons/amneziawg"
# shellcheck source=/dev/null
. "${ADDON_DIR}/lib/log.sh"             2>/dev/null || exit 0
. "${ADDON_DIR}/lib/state.sh"           2>/dev/null || exit 0
. "${ADDON_DIR}/lib/iptables_chain.sh"  2>/dev/null || exit 0
. "${ADDON_DIR}/lib/dns.sh"             2>/dev/null || exit 0
. "${ADDON_DIR}/lib/firewall.sh"        2>/dev/null || exit 0
. "${ADDON_DIR}/lib/pbr.sh"             2>/dev/null || exit 0

log_info "postdown: ${INTERFACE} down, tearing down firewall + pbr"

pbr_teardown      || log_warn "postdown: pbr_teardown had issues"
firewall_teardown || log_warn "postdown: firewall_teardown had issues"
ip route del default dev "${INTERFACE}" table 300 2>/dev/null || true

log_info "postdown: done"
exit 0
