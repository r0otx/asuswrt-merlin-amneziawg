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
case "\$1" in
    up)   touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;;
    down) rm -f "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg-quick"
    cat > "${TMPDIR_TEST}/bin/ip" <<EOF
#!/bin/sh
[ "\$1" = "link" ] && [ "\$2" = "show" ] && {
    [ -f "${TMPDIR_TEST}/link-up" ] && exit 0 || exit 1
}
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
    cat > "${TMPDIR_TEST}/bin/pidof" <<EOF
#!/bin/sh
if [ "\$1" = "-x" ]; then shift; fi
[ "\$1" = "amneziawg-go" ] && { [ -f "${TMPDIR_TEST}/daemon-pid" ] && echo 1234 || exit 1; }
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"
    cat > "${TMPDIR_TEST}/bin/pkill" <<EOF
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
if [ "$1" = "show" ] && [ "$3" = "dump" ]; then
    age="${WATCHDOG_FAKE_HANDSHAKE_AGE:-30}"
    handshake_at=$(( $(date +%s) - age ))
    printf 'priv\tpub\t51820\toff\n'
    printf 'peer-pk\t(none)\texample.com:51820\t0.0.0.0/0\t%s\t1024\t2048\t25\n' "${handshake_at}"
fi
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"
    . "${BATS_TEST_DIRNAME}/../lib/status.sh"
    . "${BATS_TEST_DIRNAME}/fixtures/mock_iptables.sh"; mock_iptables_install
    . "${BATS_TEST_DIRNAME}/../lib/iptables_chain.sh"
    . "${BATS_TEST_DIRNAME}/../lib/dns.sh"
    . "${BATS_TEST_DIRNAME}/../lib/firewall.sh"
    . "${BATS_TEST_DIRNAME}/../lib/pbr.sh"
    . "${BATS_TEST_DIRNAME}/../lib/watchdog.sh"

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

@test "watchdog_tick noop when awg_enabled=0" {
    state_set "awg_enabled" "0"
    watchdog_tick
    ! grep -q "^awg-quick" "${MOCK_LOG}"
    [ -f "${AMNEZIAWG_RUNTIME}/status.json" ]
}

@test "watchdog_tick starts tunnel when enabled but down" {
    watchdog_tick
    grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "watchdog_tick noop when tunnel up and handshake fresh" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    export WATCHDOG_FAKE_HANDSHAKE_AGE=30
    watchdog_tick
    ! grep -q "^awg-quick down" "${MOCK_LOG}"
    ! grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "watchdog_tick restarts when handshake stale (>180s)" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    export WATCHDOG_FAKE_HANDSHAKE_AGE=300
    watchdog_tick
    grep -q "^awg-quick down" "${MOCK_LOG}"
    grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "watchdog_tick rate-limits: 4th restart in 10min window is skipped" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    export WATCHDOG_FAKE_HANDSHAKE_AGE=300
    printf 'last_tick=%s\nrestart_win_start=%s\nrestart_count=3\n' \
        "$(( $(date +%s) - 40 ))" "$(( $(date +%s) - 60 ))" \
        > "${AMNEZIAWG_RUNTIME}/watchdog-state"
    : > "${MOCK_LOG}"
    watchdog_tick
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
    grep -q "rate-limited" "${AMNEZIAWG_LOG_FILE}"
}

@test "watchdog_tick skips overlap if called within 30s" {
    printf 'last_tick=%s\n' "$(( $(date +%s) - 10 ))" \
        > "${AMNEZIAWG_RUNTIME}/watchdog-state"
    : > "${MOCK_LOG}"
    watchdog_tick
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "watchdog_tick arms kill-switch when tunnel goes down" {
    state_set "awg_killswitch_strict" "1"
    # Simulate tunnel was up before (no flag), now down
    rm -f "${TMPDIR_TEST}/link-up"
    rm -f "${TMPDIR_TEST}/daemon-pid"
    # Force watchdog to think there's no overlap guard
    rm -f "${AMNEZIAWG_RUNTIME}/watchdog-state"
    watchdog_tick
    [ -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ]
}

@test "watchdog_tick disarms kill-switch when tunnel comes back up" {
    state_set "awg_killswitch_strict" "1"
    touch "${AMNEZIAWG_RUNTIME}/killswitch-armed"
    touch "${TMPDIR_TEST}/link-up"
    touch "${TMPDIR_TEST}/daemon-pid"
    # Fresh handshake so tunnel is considered healthy
    export WATCHDOG_FAKE_HANDSHAKE_AGE=30
    rm -f "${AMNEZIAWG_RUNTIME}/watchdog-state"
    watchdog_tick
    [ ! -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ]
}
