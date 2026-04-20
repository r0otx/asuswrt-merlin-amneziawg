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
