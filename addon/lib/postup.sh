#!/bin/sh
# addon/lib/postup.sh — called by awg-quick from the PostUp = ... line in
# awg0.conf. Runs after interface and daemon are up. Applies firewall and
# PBR state from current custom_settings.

INTERFACE="${1:-awg0}"

ADDON_DIR="/jffs/addons/amneziawg"
# shellcheck source=/dev/null
. "${ADDON_DIR}/lib/log.sh"             2>/dev/null || exit 0
. "${ADDON_DIR}/lib/state.sh"           2>/dev/null || exit 0
. "${ADDON_DIR}/lib/iptables_chain.sh"  2>/dev/null || exit 0
. "${ADDON_DIR}/lib/dns.sh"             2>/dev/null || exit 0
. "${ADDON_DIR}/lib/firewall.sh"        2>/dev/null || exit 0
. "${ADDON_DIR}/lib/pbr.sh"             2>/dev/null || exit 0

log_info "postup: ${INTERFACE} up, applying firewall + pbr"

firewall_setup   || log_error "postup: firewall_setup failed"
pbr_geo_apply    || log_warn  "postup: pbr_geo_apply failed (ipset may be unavailable)"
pbr_setup        || log_error "postup: pbr_setup failed"

# Add default route to VPN table (awg-quick adds main-table routes; we also
# ensure table 300 has default via the interface).
ip route replace default dev "${INTERFACE}" table 300 2>/dev/null || true

# Per-device DNS hijack
pbr_load_devices | while IFS="$(printf '\t')" read -r _n _ip _mac _name _policy; do
    case "${_policy}" in
        vpn_all|vpn_geo)
            dns_hijack_add_device "${_ip}"
            dns_doh_blocklist_apply "${_ip}"
            ;;
    esac
done

log_info "postup: done"
exit 0
