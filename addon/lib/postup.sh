#!/bin/sh
# addon/lib/postup.sh — called by awg-quick from the `PostUp = …` line in
# awg0.conf, with $1 = interface name (e.g. "awg0").
#
# Module 2 stub. Module 3 will add here:
#   - ipset create + populate (per-policy)
#   - iptables FORWARD/INPUT/POSTROUTING rules
#   - ip rule add fwmark 0x100 lookup 300
#   - kill-switch drop rule
#   - DNS-leak protection (DNAT/REJECT)

INTERFACE="${1:-awg0}"

# shellcheck source=/dev/null
. /jffs/addons/amneziawg/lib/log.sh 2>/dev/null || :

if command -v log_info >/dev/null 2>&1; then
    log_info "postup: ${INTERFACE} up (M2 stub)"
fi

# M3 hook point — end
exit 0
