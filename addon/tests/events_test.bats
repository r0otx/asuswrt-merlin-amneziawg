#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    export AMNEZIAWG_CONF="${TMPDIR_TEST}/awg0.conf"
    export AMNEZIAWG_WWW_USER="${TMPDIR_TEST}/www_user"
    export AMNEZIAWG_INTERFACE="awg0"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    mkdir -p "${AMNEZIAWG_RUNTIME}" "${AMNEZIAWG_WWW_USER}"

    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_LOG="${TMPDIR_TEST}/mock.log"
    : > "${MOCK_LOG}"

    cat > "${TMPDIR_TEST}/bin/awg-quick" <<EOF
#!/bin/sh
printf 'awg-quick %s\n' "\$*" >> "${MOCK_LOG}"
case "\$1" in up) touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;; down) rm -f "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;; esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg-quick"
    cat > "${TMPDIR_TEST}/bin/ip" <<EOF
#!/bin/sh
[ "\$1" = "link" ] && [ "\$2" = "show" ] && { [ -f "${TMPDIR_TEST}/link-up" ] && exit 0 || exit 1; }
case "\$1 \$2" in
    "neigh show") echo "" ;;
    "rule add"|"rule del"|"route add"|"route replace"|"route del")
        printf 'ip %s\n' "\$*" >> "${TMPDIR_TEST}/ip.log" ;;
esac
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
    cat > "${TMPDIR_TEST}/bin/pidof" <<EOF
#!/bin/sh
if [ "\$1" = "-x" ]; then shift; fi
[ "\$1" = "amneziawg-go" ] && { [ -f "${TMPDIR_TEST}/daemon-pid" ] && echo 1234 || exit 1; }
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"
    cat > "${TMPDIR_TEST}/bin/pkill" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/pkill"
    cat > "${TMPDIR_TEST}/bin/timeout" <<EOF
#!/bin/sh
shift
exec "\$@"
EOF
    chmod +x "${TMPDIR_TEST}/bin/timeout"
    cat > "${TMPDIR_TEST}/bin/flock" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -x|-s|-u|-n) shift ;; -c) shift; exec sh -c "$1" ;; *) shift ;; esac; done
EOF
    chmod +x "${TMPDIR_TEST}/bin/flock"
    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
case "$2" in
    lan_ipaddr)  echo "192.168.1.1" ;;
    lan_netmask) echo "255.255.255.0" ;;
    *) echo "" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"
    cat > "${TMPDIR_TEST}/bin/awg" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"
    cat > "${TMPDIR_TEST}/bin/cru" <<EOF
#!/bin/sh
printf 'cru %s\n' "\$*" >> "${MOCK_LOG}"
EOF
    chmod +x "${TMPDIR_TEST}/bin/cru"

    . "${BATS_TEST_DIRNAME}/fixtures/mock_iptables.sh"; mock_iptables_install
    . "${BATS_TEST_DIRNAME}/fixtures/mock_ipset.sh";    mock_ipset_install

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/hooks.sh"
    . "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"
    . "${BATS_TEST_DIRNAME}/../lib/status.sh"
    . "${BATS_TEST_DIRNAME}/../lib/iptables_chain.sh"
    . "${BATS_TEST_DIRNAME}/../lib/dns.sh"
    . "${BATS_TEST_DIRNAME}/../lib/firewall.sh"
    . "${BATS_TEST_DIRNAME}/../lib/pbr.sh"
    . "${BATS_TEST_DIRNAME}/../lib/events.sh"

    state_set "awg_enabled"           "1"
    state_set "awg_privatekey"        "aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"           "10.8.0.2/24"
    state_set "awg_jc"                "4"
    state_set "awg_jmin"              "40"
    state_set "awg_jmax"              "70"
    state_set "awg_h1"                "1"
    state_set "awg_h2"                "2"
    state_set "awg_h3"                "3"
    state_set "awg_h4"                "4"
    state_set "awg_peer_publickey"    "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3E="
    state_set "awg_peer_endpoint"     "example.com:51820"
    state_set "awg_peer_allowed_ips"  "0.0.0.0/0"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "event_wan ignores unit=1" {
    event_wan 1 connected
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan ignores init/connecting types" {
    event_wan 0 init
    event_wan 0 connecting
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan connected triggers tunnel_restart" {
    event_wan 0 connected
    grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan disconnected triggers tunnel_stop" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    event_wan 0 disconnected
    grep -q "^awg-quick down" "${MOCK_LOG}"
}

@test "event_wan debounce: second call within 5s is noop" {
    event_wan 0 connected
    : > "${MOCK_LOG}"
    event_wan 0 connected
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan debounce: second call after 6s is honored" {
    event_wan 0 connected
    printf '%s\n' "$(( $(date +%s) - 10 ))" > "${AMNEZIAWG_RUNTIME}/last-wan-action"
    : > "${MOCK_LOG}"
    event_wan 0 connected
    grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_service start awgstart triggers tunnel_start" {
    event_service start awgstart
    grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "event_service start awgstop triggers tunnel_stop" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    event_service start awgstop
    grep -q "^awg-quick down" "${MOCK_LOG}"
}

@test "event_service start awgrestart triggers stop+start" {
    event_service start awgrestart
    grep -q "^awg-quick down" "${MOCK_LOG}"
    grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "event_service unknown target is noop" {
    event_service start other-addon
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_firewall calls pbr_reapply_incremental" {
    # Device state unchanged — no-op expected
    state_set "awg_dev_count" "1"
    state_set "awg_dev_0_ip" "192.168.1.100"
    state_set "awg_dev_0_mac" "aa:bb:cc:dd:ee:01"
    state_set "awg_dev_0_name" "x"
    state_set "awg_dev_0_policy" "vpn_all"
    pbr_setup
    : > "${TMPDIR_TEST}/ip.log"
    event_firewall eth0
    ! grep -q 'rule add' "${TMPDIR_TEST}/ip.log"
}

@test "event_services_start installs cron entry" {
    event_services_start
    grep -q "^cru a amneziawg_watchdog" "${MOCK_LOG}"
}

@test "event_services_start starts tunnel when awg_enabled=1" {
    event_services_start
    grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "event_services_start skips tunnel_start when awg_enabled=0" {
    state_set "awg_enabled" "0"
    event_services_start
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
}
