#!/bin/sh
# addon/scripts/uninstall.sh — manual uninstall fallback (used when opkg is unavailable).
# Prefer: opkg remove amneziawg-merlin-addon.

set -eu

ADDON_DIR="/jffs/addons/amneziawg"
: "${AMNEZIAWG_CUSTOM_SETTINGS:=/jffs/addons/custom_settings.txt}"
PURGE="${1:-}"

if [ ! -d "${ADDON_DIR}" ]; then
    printf 'AmneziaWG addon not installed.\n'
    exit 0
fi

. "${ADDON_DIR}/lib/log.sh"
. "${ADDON_DIR}/lib/state.sh"
. "${ADDON_DIR}/lib/hooks.sh"
. "${ADDON_DIR}/lib/ui.sh"
. "${ADDON_DIR}/lib/install.sh"
. "${ADDON_DIR}/lib/firewall.sh"
. "${ADDON_DIR}/lib/pbr.sh"
. "${ADDON_DIR}/lib/geo.sh"

uninstall_run

if [ "${PURGE}" = "--purge" ]; then
    log_info "purge: wiping user state"
    # Remove awg_* keys from custom_settings.txt
    for k in $(state_list_awg_keys); do state_delete "$k"; done
    rm -rf "${ADDON_DIR}"
    rm -rf /opt/etc/amneziawg
    rm -rf /opt/var/log/amneziawg
else
    log_info "non-purge: preserving /opt/etc/amneziawg/awg0.conf and awg_ settings"
fi

printf 'Uninstall complete. Reboot recommended.\n'
