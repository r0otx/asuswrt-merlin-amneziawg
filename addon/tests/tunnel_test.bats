#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_CONF="${TMPDIR_TEST}/awg0.conf"
    export AMNEZIAWG_INTERFACE="awg0"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    mkdir -p "${AMNEZIAWG_RUNTIME}"

    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_LOG="${TMPDIR_TEST}/mock.log"
    : > "${MOCK_LOG}"

    cat > "${TMPDIR_TEST}/bin/awg-quick" <<EOF
#!/bin/sh
printf 'awg-quick %s\n' "\$*" >> "${MOCK_LOG}"
case "\$1" in
    up)    touch "${TMPDIR_TEST}/link-up"
           touch "${TMPDIR_TEST}/daemon-pid"
           ;;
    down)  rm -f "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
           ;;
esac
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg-quick"

    cat > "${TMPDIR_TEST}/bin/ip" <<EOF
#!/bin/sh
if [ "\$1" = "link" ] && [ "\$2" = "show" ]; then
    [ -f "${TMPDIR_TEST}/link-up" ] && exit 0 || exit 1
fi
if [ "\$1" = "link" ] && [ "\$2" = "del" ]; then
    rm -f "${TMPDIR_TEST}/link-up"
    exit 0
fi
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"

    cat > "${TMPDIR_TEST}/bin/pidof" <<EOF
#!/bin/sh
if [ "\$1" = "-x" ]; then shift; fi
if [ "\$1" = "amneziawg-go" ]; then
    [ -f "${TMPDIR_TEST}/daemon-pid" ] && echo "1234" || exit 1
else
    exit 1
fi
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"

    cat > "${TMPDIR_TEST}/bin/pkill" <<EOF
#!/bin/sh
printf 'pkill %s\n' "\$*" >> "${MOCK_LOG}"
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
while [ $# -gt 0 ]; do
    case "$1" in
        -x|-s|-u|-n) shift ;;
        -c) shift; exec sh -c "$1" ;;
        *) shift ;;
    esac
done
EOF
    chmod +x "${TMPDIR_TEST}/bin/flock"

    cat > "${TMPDIR_TEST}/bin/nvram" <<EOF
#!/bin/sh
[ "\$1" = "get" ] && echo ""
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"

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

@test "tunnel_is_up returns 0 when link and daemon present" {
    touch "${TMPDIR_TEST}/link-up"
    touch "${TMPDIR_TEST}/daemon-pid"
    tunnel_is_up
}

@test "tunnel_is_up returns 1 when link missing" {
    rm -f "${TMPDIR_TEST}/link-up"
    touch "${TMPDIR_TEST}/daemon-pid"
    ! tunnel_is_up
}

@test "tunnel_is_up returns 1 when daemon missing" {
    touch "${TMPDIR_TEST}/link-up"
    rm -f "${TMPDIR_TEST}/daemon-pid"
    ! tunnel_is_up
}

@test "tunnel_start with awg_enabled=0 is noop" {
    state_set "awg_enabled" "0"
    tunnel_start
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "tunnel_start invokes awg-quick up exactly once" {
    tunnel_start
    [ "$(grep -c '^awg-quick up' "${MOCK_LOG}")" -eq 1 ]
}

@test "tunnel_start emits awg0.conf via config_emit" {
    tunnel_start
    [ -f "${AMNEZIAWG_CONF}" ]
    grep -q '^PrivateKey = ' "${AMNEZIAWG_CONF}"
    grep -q '^Endpoint = example.com:51820' "${AMNEZIAWG_CONF}"
}

@test "tunnel_start returns 1 when config invalid" {
    state_set "awg_privatekey" "too-short"
    ! tunnel_start
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "tunnel_stop invokes awg-quick down" {
    touch "${TMPDIR_TEST}/link-up"
    touch "${TMPDIR_TEST}/daemon-pid"
    tunnel_stop
    grep -q "^awg-quick down" "${MOCK_LOG}"
}

@test "tunnel_stop is idempotent (double call ok)" {
    tunnel_stop
    tunnel_stop
    [ "$(grep -c '^awg-quick down' "${MOCK_LOG}")" -eq 2 ]
}

@test "tunnel_stop calls pkill as safety net" {
    tunnel_stop
    grep -q "pkill" "${MOCK_LOG}"
}

@test "tunnel_restart = stop + start in sequence" {
    tunnel_restart
    _down_line=$(grep -n "^awg-quick down" "${MOCK_LOG}" | head -1 | cut -d: -f1)
    _up_line=$(grep -n "^awg-quick up" "${MOCK_LOG}" | head -1 | cut -d: -f1)
    [ "${_down_line}" -lt "${_up_line}" ]
}

@test "tunnel_reload is noop when config unchanged" {
    tunnel_start
    : > "${MOCK_LOG}"
    tunnel_reload
    ! grep -q "^awg-quick down" "${MOCK_LOG}"
    ! grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "tunnel_reload restarts when config changes" {
    tunnel_start
    : > "${MOCK_LOG}"
    state_set "awg_peer_endpoint" "newhost.example:51820"
    tunnel_reload
    grep -q "^awg-quick down" "${MOCK_LOG}"
    grep -q "^awg-quick up"   "${MOCK_LOG}"
}
