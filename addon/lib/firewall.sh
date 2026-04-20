#!/bin/sh
# addon/lib/firewall.sh — custom chains + IPv6 gate + teardown.
# Public:
#   firewall_setup
#   firewall_teardown
#
# Integrates dns.sh for the DNS layer. PBR-specific rules live in pbr.sh.

if ! command -v log_info       >/dev/null 2>&1; then echo "firewall.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v chain_ensure   >/dev/null 2>&1; then echo "firewall.sh: iptables_chain.sh first" >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v dns_hijack_setup >/dev/null 2>&1; then echo "firewall.sh: dns.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_CONF:=/opt/etc/amneziawg/awg0.conf}"

_firewall_ipv6_should_block() {
    # Decision: block IPv6 forwarding if no ::/0 in AllowedIPs and bypass not enabled.
    if [ "$(state_get awg_ipv6_allow_bypass 2>/dev/null)" = "1" ]; then
        return 1
    fi
    if [ -f "${AMNEZIAWG_CONF}" ] && grep -qE '^AllowedIPs[^=]*=.*::/0' "${AMNEZIAWG_CONF}"; then
        return 1
    fi
    return 0
}

firewall_setup() {
    # Mangle: AMNEZIAWG (populated by pbr_apply)
    chain_ensure mangle AMNEZIAWG
    chain_flush  mangle AMNEZIAWG
    rule_del_if_exists mangle PREROUTING -j AMNEZIAWG
    iptables -t mangle -I PREROUTING -j AMNEZIAWG

    # Filter: AMNEZIAWG_KILL (empty until kill-switch armed)
    chain_ensure filter AMNEZIAWG_KILL
    chain_flush  filter AMNEZIAWG_KILL
    rule_del_if_exists filter FORWARD -j AMNEZIAWG_KILL
    iptables -I FORWARD -j AMNEZIAWG_KILL

    # Nat: DNS chain via dns.sh
    dns_hijack_setup
    dns_dnsmasq_postconf_generate

    # IPv6
    if _firewall_ipv6_should_block; then
        ip6tables -D FORWARD -j DROP 2>/dev/null || true
        ip6tables -I FORWARD -j DROP
        log_info "firewall: ipv6 forwarding DROPped"
    else
        ip6tables -D FORWARD -j DROP 2>/dev/null || true
        log_info "firewall: ipv6 passthrough (tunnel or bypass enabled)"
    fi
}

firewall_teardown() {
    # Mangle
    rule_del_if_exists mangle PREROUTING -j AMNEZIAWG
    chain_delete mangle AMNEZIAWG

    # Kill chain
    rule_del_if_exists filter FORWARD -j AMNEZIAWG_KILL
    chain_delete filter AMNEZIAWG_KILL

    # DNS
    dns_hijack_teardown
    dns_dnsmasq_postconf_remove

    # IPv6
    ip6tables -D FORWARD -j DROP 2>/dev/null || true

    log_info "firewall: teardown complete"
}
