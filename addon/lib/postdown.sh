#!/bin/sh
# addon/lib/postdown.sh — called by awg-quick from the `PostDown = …` line in
# awg0.conf, with $1 = interface name. Reverse of postup.sh.
#
# Module 2 stub. Module 3 will undo what postup.sh set up: ip rule del,
# iptables -D, ipset destroy, etc.

INTERFACE="${1:-awg0}"

# shellcheck source=/dev/null
. /jffs/addons/amneziawg/lib/log.sh 2>/dev/null || :

if command -v log_info >/dev/null 2>&1; then
    log_info "postdown: ${INTERFACE} down (M2 stub)"
fi

# M3 hook point — end
exit 0
