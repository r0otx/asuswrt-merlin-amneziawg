#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
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

    cat > "${TMPDIR_TEST}/bin/ip"    <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
    cat > "${TMPDIR_TEST}/bin/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"
    cat > "${TMPDIR_TEST}/bin/awg"   <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"
    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"
    . "${BATS_TEST_DIRNAME}/../lib/status.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

_arm_running_state() {
    cat > "${TMPDIR_TEST}/bin/ip"    <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
    cat > "${TMPDIR_TEST}/bin/pidof" <<'EOF'
#!/bin/sh
echo 1234
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"
    cat > "${TMPDIR_TEST}/bin/awg" <<'EOF'
#!/bin/sh
if [ "$1" = "show" ] && [ "$3" = "dump" ]; then
    printf 'priv-interface-key\tpub-interface-key\t51820\toff\n'
    printf 'pubkeypeer\t(none)\texample.com:51820\t0.0.0.0/0\t%s\t1024\t2048\t25\n' "$(( $(date +%s) - 42 ))"
fi
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"
}

@test "status_emit_json writes /tmp/amneziawg/status.json" {
    status_emit_json
    [ -f "${AMNEZIAWG_RUNTIME}/status.json" ]
}

@test "status_emit_json stopped state when tunnel down" {
    status_emit_json
    grep -q '"state":"stopped"' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json running state when tunnel up" {
    _arm_running_state
    status_emit_json
    grep -q '"state":"running"' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes handshake_age_seconds when running" {
    _arm_running_state
    status_emit_json
    grep -Eq '"handshake_age_seconds":[0-9]+' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes rx/tx bytes when running" {
    _arm_running_state
    status_emit_json
    grep -q '"rx_bytes":1024' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"tx_bytes":2048' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json mirrors to /www/user/awg_status.htm" {
    status_emit_json
    [ -f "${AMNEZIAWG_WWW_USER}/awg_status.htm" ]
    cmp -s "${AMNEZIAWG_WWW_USER}/awg_status.htm" "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json writes atomically (no .tmp leftovers)" {
    status_emit_json
    ! ls "${AMNEZIAWG_RUNTIME}"/status.json.tmp.* 2>/dev/null
}

@test "status_emit_json sets stock_wg_conflict=true when wgc1 active" {
    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
case "$2" in
    wgc_unit) echo 1 ;;
    wgc1_enable) echo 1 ;;
    *) echo "" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"
    status_emit_json
    grep -q '"stock_wg_conflict":true' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes leases from dnsmasq.leases" {
    export AMNEZIAWG_DNSMASQ_LEASES="${TMPDIR_TEST}/dnsmasq.leases"
    cat > "${AMNEZIAWG_DNSMASQ_LEASES}" <<'EOF'
1729550000 aa:bb:cc:dd:ee:01 192.168.1.100 laptop *
1729550100 aa:bb:cc:dd:ee:02 192.168.1.105 phone *
EOF
    status_emit_json
    grep -q '"leases":\[' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"mac":"aa:bb:cc:dd:ee:01"' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"ip":"192.168.1.105"' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes killswitch_armed flag" {
    status_emit_json
    grep -q '"killswitch_armed":false' "${AMNEZIAWG_RUNTIME}/status.json"
    touch "${AMNEZIAWG_RUNTIME}/killswitch-armed"
    status_emit_json
    grep -q '"killswitch_armed":true' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes geo{} with last_sync and enabled" {
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/geo"
    mkdir -p "${AMNEZIAWG_GEO_ROOT}"
    printf '1729550000\n' > "${AMNEZIAWG_GEO_ROOT}/last-sync"
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_ru_mode" "direct"
    state_set "awg_geo_telegram_mode" "off"
    status_emit_json
    grep -q '"geo":{' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"last_sync":1729550000' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"enabled":\["google","ru"\]' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json emits empty geo{} when no state" {
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/geo"
    status_emit_json
    grep -q '"geo":{"last_sync":0,"enabled":\[\]}' "${AMNEZIAWG_RUNTIME}/status.json"
}
