#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_DNSMASQ_LEASES="${TMPDIR_TEST}/dnsmasq.leases"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    cp "${BATS_TEST_DIRNAME}/fixtures/dnsmasq-leases-sample.txt" \
       "${AMNEZIAWG_DNSMASQ_LEASES}"

    . "${BATS_TEST_DIRNAME}/fixtures/mock_iptables.sh"
    mock_iptables_install
    . "${BATS_TEST_DIRNAME}/fixtures/mock_ipset.sh"
    mock_ipset_install
    export PATH="${TMPDIR_TEST}/bin:${PATH}"

    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
case "$2" in
    lan_ipaddr) echo "192.168.1.1" ;;
    lan_netmask) echo "255.255.255.0" ;;
    *) echo "" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"

    cat > "${TMPDIR_TEST}/bin/ip" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "neigh show")
        cat <<NEIGH
192.168.1.100 dev br0 lladdr aa:bb:cc:dd:ee:01 REACHABLE
192.168.1.110 dev br0 lladdr 11:22:33:44:55:66 STALE
NEIGH
        ;;
    "rule add"|"rule del"|"route add"|"route replace"|"route del")
        printf 'ip %s\n' "$*" >> "${TMPDIR_TEST}/ip.log"
        ;;
    "rule show")
        cat "${TMPDIR_TEST}/ip-rules" 2>/dev/null || true
        ;;
esac
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/iptables_chain.sh"
    . "${BATS_TEST_DIRNAME}/../lib/dns.sh"
    . "${BATS_TEST_DIRNAME}/../lib/firewall.sh"
    . "${BATS_TEST_DIRNAME}/../lib/pbr.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

_add_device() {
    _n="$1"
    state_set "awg_dev_${_n}_ip"     "$2"
    state_set "awg_dev_${_n}_mac"    "$3"
    state_set "awg_dev_${_n}_name"   "$4"
    state_set "awg_dev_${_n}_policy" "$5"
    _cur="$(state_get awg_dev_count)"
    [ -z "${_cur}" ] && _cur=0
    _new=$(( _n + 1 ))
    if [ "${_new}" -gt "${_cur}" ]; then
        state_set "awg_dev_count" "${_new}"
    fi
}

@test "pbr_load_devices reads stored entries" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    _add_device 1 192.168.1.105 aa:bb:cc:dd:ee:02 phone  vpn_geo
    _count="$(pbr_load_devices | wc -l)"
    [ "${_count}" -eq 2 ]
}

@test "pbr_resolve_ip uses dnsmasq.leases first" {
    _ip="$(_pbr_resolve_ip aa:bb:cc:dd:ee:01)"
    [ "${_ip}" = "192.168.1.100" ]
}

@test "pbr_resolve_ip falls back to ip neigh when leases miss" {
    # Remove the lease for ee:01, so lease lookup misses;
    # ip neigh mock still returns it
    awk '$2 != "aa:bb:cc:dd:ee:01"' "${AMNEZIAWG_DNSMASQ_LEASES}" \
        > "${AMNEZIAWG_DNSMASQ_LEASES}.tmp"
    mv "${AMNEZIAWG_DNSMASQ_LEASES}.tmp" "${AMNEZIAWG_DNSMASQ_LEASES}"
    _ip="$(_pbr_resolve_ip aa:bb:cc:dd:ee:01)"
    [ "${_ip}" = "192.168.1.100" ]
}

@test "pbr_setup adds prio-99 ip rule for vpn_all device" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    pbr_setup
    grep -q 'rule add from 192.168.1.100 lookup 300 prio 99' "${TMPDIR_TEST}/ip.log"
}

@test "pbr_setup adds prio-97 ip rule for direct device" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop direct
    pbr_setup
    grep -q 'rule add from 192.168.1.100 lookup main prio 97' "${TMPDIR_TEST}/ip.log"
}

@test "pbr_setup adds global fwmark prio-98 rule" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    pbr_setup
    grep -q 'rule add fwmark 0x100/0xFF00 lookup 300 prio 98' "${TMPDIR_TEST}/ip.log"
}

@test "pbr_setup emits MARK rule for vpn_geo device" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_geo
    pbr_setup
    iptables -t mangle -S AMNEZIAWG | grep -q -- '-s 192.168.1.100 -m set --match-set awg_geo_dst dst -j MARK --set-mark 0x100/0xFF00'
}

@test "pbr_teardown removes ip rules and flushes chain" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    pbr_setup
    pbr_teardown
    grep -q 'rule del from 192.168.1.100 lookup 300 prio 99' "${TMPDIR_TEST}/ip.log"
    # AMNEZIAWG chain should be empty of -A rules
    [ -z "$(iptables -t mangle -S AMNEZIAWG 2>/dev/null | grep '^-A')" ]
}

@test "default_policy=vpn_all adds blanket MARK for LAN subnet with direct exceptions" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop direct
    state_set "awg_default_policy" "vpn_all"
    pbr_setup
    # Exception comes first
    iptables -t mangle -S AMNEZIAWG | grep -q -- '-s 192.168.1.100 -j RETURN'
    # Blanket LAN MARK (uses /24 mask computed from nvram netmask 255.255.255.0)
    iptables -t mangle -S AMNEZIAWG | grep -qE -- '-s 192.168.1.0/24 -j MARK --set-mark 0x100/0xFF00'
}

@test "default_policy=direct adds no blanket MARK" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    state_set "awg_default_policy" "direct"
    pbr_setup
    ! iptables -t mangle -S AMNEZIAWG | grep -qE -- '-s 192.168.1.0/24 -j MARK'
}

@test "default_policy unset behaves as direct" {
    state_delete "awg_default_policy"
    pbr_setup
    ! iptables -t mangle -S AMNEZIAWG | grep -qE -- '-s 192.168.1.0/24 -j MARK'
}

@test "pbr_kill_switch_arm adds DROPs for mark + vpn devices" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    _add_device 1 192.168.1.105 aa:bb:cc:dd:ee:02 phone  vpn_geo
    pbr_setup
    pbr_kill_switch_arm
    iptables -S AMNEZIAWG_KILL | grep -q -- '-m mark --mark 0x100/0xFF00 -j DROP'
    iptables -S AMNEZIAWG_KILL | grep -q -- '-s 192.168.1.100 -j DROP'
    iptables -S AMNEZIAWG_KILL | grep -q -- '-s 192.168.1.105 -j DROP'
    [ -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ]
}

@test "pbr_kill_switch_disarm empties chain and removes flag" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    pbr_setup
    pbr_kill_switch_arm
    pbr_kill_switch_disarm
    ! iptables -S AMNEZIAWG_KILL | grep -q '^-A'
    [ ! -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ]
}

@test "pbr_kill_switch_arm does nothing when killswitch_strict=0" {
    state_set "awg_killswitch_strict" "0"
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    pbr_setup
    pbr_kill_switch_arm
    ! iptables -S AMNEZIAWG_KILL | grep -q -- '-j DROP'
    [ ! -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ]
}

@test "pbr_reapply_incremental skips when state unchanged" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    pbr_setup
    : > "${TMPDIR_TEST}/ip.log"
    pbr_reapply_incremental
    ! grep -q 'rule add' "${TMPDIR_TEST}/ip.log"
}

@test "pbr_reapply_incremental re-applies when device added" {
    _add_device 0 192.168.1.100 aa:bb:cc:dd:ee:01 laptop vpn_all
    pbr_setup
    : > "${TMPDIR_TEST}/ip.log"
    _add_device 1 192.168.1.105 aa:bb:cc:dd:ee:02 phone  vpn_all
    pbr_reapply_incremental
    grep -q 'rule add from 192.168.1.105 lookup 300 prio 99' "${TMPDIR_TEST}/ip.log"
}

@test "pbr_geo_add appends to awg_geo_entries" {
    pbr_geo_add "1.2.3.0/24"
    pbr_geo_add "5.6.7.8/32"
    run state_get "awg_geo_entries"
    [ "$output" = "1.2.3.0/24,5.6.7.8/32" ]
}

@test "pbr_geo_remove deletes a CIDR from the list" {
    state_set "awg_geo_entries" "1.2.3.0/24,5.6.7.8/32,9.9.9.9/32"
    pbr_geo_remove "5.6.7.8/32"
    run state_get "awg_geo_entries"
    [ "$output" = "1.2.3.0/24,9.9.9.9/32" ]
}

@test "pbr_geo_apply populates ipset via ipset-restore batch" {
    state_set "awg_geo_entries" "10.0.0.0/8,192.168.100.0/24"
    pbr_geo_apply
    ipset test awg_geo_dst 10.0.0.0/8
    ipset test awg_geo_dst 192.168.100.0/24
}

@test "pbr_device_set appends new device entry" {
    pbr_device_set 192.168.1.100 vpn_all laptop aa:bb:cc:dd:ee:01
    run state_get "awg_dev_count"
    [ "$output" = "1" ]
    run state_get "awg_dev_0_ip"
    [ "$output" = "192.168.1.100" ]
    run state_get "awg_dev_0_policy"
    [ "$output" = "vpn_all" ]
}

@test "pbr_device_set updates existing entry by IP" {
    pbr_device_set 192.168.1.100 vpn_all laptop aa:bb:cc:dd:ee:01
    pbr_device_set 192.168.1.100 direct laptop aa:bb:cc:dd:ee:01
    run state_get "awg_dev_count"
    [ "$output" = "1" ]
    run state_get "awg_dev_0_policy"
    [ "$output" = "direct" ]
}

@test "pbr_device_remove decrements count and shifts entries" {
    pbr_device_set 192.168.1.100 vpn_all laptop aa:bb:cc:dd:ee:01
    pbr_device_set 192.168.1.105 vpn_geo phone  aa:bb:cc:dd:ee:02
    pbr_device_remove 192.168.1.100
    run state_get "awg_dev_count"
    [ "$output" = "1" ]
    run state_get "awg_dev_0_ip"
    [ "$output" = "192.168.1.105" ]
}

@test "pbr_geo_apply creates awg_geo_dst as hash:net" {
    state_set "awg_geo_entries" "10.0.0.0/8,192.168.1.0/24"
    pbr_geo_apply
    grep -qE '^SET:awg_geo_dst hash:net' "${TMPDIR_TEST}/ipset-state"
    ipset test awg_geo_dst 10.0.0.0/8
    ipset test awg_geo_dst 192.168.1.0/24
}

@test "pbr_geo_direct_apply creates awg_geo_direct as hash:net" {
    state_set "awg_geo_entries_direct" "172.16.0.0/12"
    pbr_geo_direct_apply
    grep -qE '^SET:awg_geo_direct hash:net' "${TMPDIR_TEST}/ipset-state"
    ipset test awg_geo_direct 172.16.0.0/12
}

@test "pbr_geo_direct_add appends to awg_geo_entries_direct" {
    pbr_geo_direct_add "10.0.0.0/8"
    pbr_geo_direct_add "192.168.0.0/16"
    run state_get "awg_geo_entries_direct"
    [ "$output" = "10.0.0.0/8,192.168.0.0/16" ]
}

@test "pbr_geo_direct_remove drops a CIDR" {
    state_set "awg_geo_entries_direct" "10.0.0.0/8,172.16.0.0/12"
    pbr_geo_direct_remove "10.0.0.0/8"
    run state_get "awg_geo_entries_direct"
    [ "$output" = "172.16.0.0/12" ]
}

@test "pbr_geo_direct_clear empties awg_geo_entries_direct" {
    state_set "awg_geo_entries_direct" "10.0.0.0/8"
    pbr_geo_direct_clear
    run state_get "awg_geo_entries_direct"
    [ "$output" = "" ]
}

@test "pbr_geo_direct_add/remove normalize whitespace in CIDR argument" {
    pbr_geo_direct_add " 10.0.0.0/8"
    run state_get "awg_geo_entries_direct"
    [ "$output" = "10.0.0.0/8" ]
    pbr_geo_direct_add "192.168.0.0/16 "
    run state_get "awg_geo_entries_direct"
    [ "$output" = "10.0.0.0/8,192.168.0.0/16" ]
    pbr_geo_direct_remove " 10.0.0.0/8"
    run state_get "awg_geo_entries_direct"
    [ "$output" = "192.168.0.0/16" ]
}

@test "pbr_setup emits RETURN-before-MARK for vpn_except_geo device" {
    # Use a MAC not in dnsmasq-leases or ip-neigh fixtures so _pbr_resolve_ip
    # returns nothing and the stored IP 192.168.1.50 is used as-is.
    _add_device 0 192.168.1.50 ff:ff:ff:ff:ff:01 laptop vpn_except_geo
    pbr_setup
    # Both rules must exist for this source IP
    iptables -t mangle -S AMNEZIAWG | grep -q -- '-s 192.168.1.50 -m set --match-set awg_geo_direct dst -j RETURN'
    iptables -t mangle -S AMNEZIAWG | grep -q -- '-s 192.168.1.50 -j MARK --set-mark 0x100/0xFF00'
    # RETURN must precede MARK in chain order
    _return_line="$(iptables -t mangle -S AMNEZIAWG | grep -n -- '-s 192.168.1.50 .*-j RETURN' | head -1 | cut -d: -f1)"
    _mark_line="$(iptables -t mangle -S AMNEZIAWG | grep -n -- '-s 192.168.1.50 -j MARK' | head -1 | cut -d: -f1)"
    [ -n "${_return_line}" ] && [ -n "${_mark_line}" ] && [ "${_return_line}" -lt "${_mark_line}" ]
}

@test "pbr_setup does NOT add per-source ip rule for vpn_except_geo device (mangle-only)" {
    _add_device 0 192.168.1.50 ff:ff:ff:ff:ff:01 laptop vpn_except_geo
    pbr_setup
    ! grep -q 'rule add from 192.168.1.50 lookup 300' "${TMPDIR_TEST}/ip.log"
    # But the global fwmark rule must still be present
    grep -q 'rule add fwmark 0x100/0xFF00 lookup 300 prio 98' "${TMPDIR_TEST}/ip.log"
}

@test "pbr_teardown for vpn_except_geo leaves no iptables rules and no per-source ip rule to del" {
    _add_device 0 192.168.1.50 ff:ff:ff:ff:ff:01 laptop vpn_except_geo
    pbr_setup
    pbr_teardown
    # No per-source ip rule was ever added, and none should be deleted either
    ! grep -q 'rule del from 192.168.1.50 lookup 300' "${TMPDIR_TEST}/ip.log"
    # AMNEZIAWG chain is flushed
    [ -z "$(iptables -t mangle -S AMNEZIAWG 2>/dev/null | grep '^-A')" ]
}

@test "pbr_kill_switch_arm includes vpn_except_geo devices in DROP set" {
    _add_device 0 192.168.1.50 ff:ff:ff:ff:ff:01 laptop vpn_except_geo
    pbr_kill_switch_arm
    iptables -S AMNEZIAWG_KILL | grep -q -- '-s 192.168.1.50 -j DROP'
}
