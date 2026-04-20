#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_CONF="${TMPDIR_TEST}/awg0.conf"
    export AMNEZIAWG_DNSMASQ_CONF="${TMPDIR_TEST}/dnsmasq.conf.add"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"

    . "${BATS_TEST_DIRNAME}/fixtures/mock_iptables.sh"
    mock_iptables_install
    export PATH="${TMPDIR_TEST}/bin:${PATH}"

    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
case "$2" in
    lan_ipaddr) echo "192.168.1.1" ;;
    lan_ipaddr_rt) echo "192.168.1.1" ;;
    lan_netmask) echo "255.255.255.0" ;;
    *) echo "" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/iptables_chain.sh"
    . "${BATS_TEST_DIRNAME}/../lib/dns.sh"
    . "${BATS_TEST_DIRNAME}/../lib/firewall.sh"

    # Default awg0.conf — IPv4-only tunnel
    cat > "${AMNEZIAWG_CONF}" <<EOF
[Interface]
PrivateKey = x
Address = 10.8.0.2/24

[Peer]
PublicKey = y
Endpoint = a.b:1
AllowedIPs = 0.0.0.0/0
EOF
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "firewall_setup creates AMNEZIAWG chain in mangle" {
    firewall_setup
    iptables -t mangle -S AMNEZIAWG | grep -q '^:AMNEZIAWG '
}

@test "firewall_setup hooks AMNEZIAWG from mangle PREROUTING" {
    firewall_setup
    iptables -t mangle -S PREROUTING | grep -q -- '-j AMNEZIAWG'
}

@test "firewall_setup creates AMNEZIAWG_KILL chain in filter" {
    firewall_setup
    iptables -S AMNEZIAWG_KILL | grep -q '^:AMNEZIAWG_KILL '
}

@test "firewall_setup invokes dns_hijack_setup" {
    firewall_setup
    iptables -t nat -S AMNEZIAWG_DNS | grep -q '^:AMNEZIAWG_DNS '
    iptables -t nat -S PREROUTING | grep -q -- '-j AMNEZIAWG_DNS'
}

@test "firewall_setup generates dnsmasq.postconf file" {
    firewall_setup
    [ -f "${AMNEZIAWG_DNSMASQ_CONF}" ]
}

@test "firewall_setup applies IPv6 FORWARD DROP when no ::/0 in AllowedIPs" {
    firewall_setup
    ip6tables -S FORWARD | grep -q -- '-j DROP'
}

@test "firewall_setup does NOT apply IPv6 DROP when ::/0 in AllowedIPs" {
    sed -i.bak 's|AllowedIPs = 0.0.0.0/0|AllowedIPs = 0.0.0.0/0,::/0|' "${AMNEZIAWG_CONF}"
    rm -f "${AMNEZIAWG_CONF}.bak"
    firewall_setup
    ! ip6tables -S FORWARD | grep -q -- '-j DROP'
}

@test "firewall_setup does NOT apply IPv6 DROP when awg_ipv6_allow_bypass=1" {
    state_set "awg_ipv6_allow_bypass" "1"
    firewall_setup
    ! ip6tables -S FORWARD | grep -q -- '-j DROP'
}

@test "firewall_teardown removes custom chains" {
    firewall_setup
    firewall_teardown
    ! iptables -t mangle -S AMNEZIAWG | grep -q '^:AMNEZIAWG '
    ! iptables -t nat -S AMNEZIAWG_DNS | grep -q '^:AMNEZIAWG_DNS '
    ! iptables -S AMNEZIAWG_KILL | grep -q '^:AMNEZIAWG_KILL '
}

@test "firewall_teardown removes IPv6 DROP" {
    firewall_setup
    firewall_teardown
    ! ip6tables -S FORWARD | grep -q -- '-j DROP'
}

@test "firewall_teardown removes dnsmasq.postconf file" {
    firewall_setup
    firewall_teardown
    [ ! -f "${AMNEZIAWG_DNSMASQ_CONF}" ]
}

@test "firewall_setup is idempotent (double call — one jump entry each)" {
    firewall_setup
    firewall_setup
    [ "$(iptables -t mangle -S PREROUTING | grep -c -- '-j AMNEZIAWG$')" -eq 1 ]
    [ "$(iptables -t nat -S PREROUTING    | grep -c -- '-j AMNEZIAWG_DNS$')" -eq 1 ]
}
