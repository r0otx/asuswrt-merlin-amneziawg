#!/usr/bin/env bats
# shellcheck disable=SC2034

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_METRICS_FILE="${TMPDIR_TEST}/metrics.jsonl"
    export AMNEZIAWG_METRICS_WINDOW=1440
    export AMNEZIAWG_WWW_USER="${TMPDIR_TEST}/www_user"
    export AMNEZIAWG_INTERFACE="awg0"
    mkdir -p "${AMNEZIAWG_WWW_USER}"

    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_AWG_LOG="${TMPDIR_TEST}/awg.log"

    # mock `awg show <iface> transfer` and `awg show <iface> latest-handshakes`
    cat > "${TMPDIR_TEST}/bin/awg" <<'EOF'
#!/bin/sh
: "${MOCK_AWG_RX:=0}"
: "${MOCK_AWG_TX:=0}"
: "${MOCK_AWG_HANDSHAKE_AT:=0}"
: "${MOCK_AWG_FAIL:=0}"
printf '%s\n' "$*" >> "${MOCK_AWG_LOG}"
if [ "${MOCK_AWG_FAIL}" = "1" ]; then exit 1; fi
case "$3" in
    transfer)          printf '%s\t%s\n' "${MOCK_AWG_RX}" "${MOCK_AWG_TX}" ;;
    latest-handshakes) printf 'fakepubkey\t%s\n' "${MOCK_AWG_HANDSHAKE_AT}" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"

    # mock `ip link show <iface>` — MOCK_IP_LINK_UP=1 → exit 0 and print UP
    cat > "${TMPDIR_TEST}/bin/ip" <<'EOF'
#!/bin/sh
: "${MOCK_IP_LINK_UP:=1}"
if [ "$1" = "link" ] && [ "$2" = "show" ]; then
    if [ "${MOCK_IP_LINK_UP}" = "1" ]; then
        printf '5: awg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 state UNKNOWN\n'
        exit 0
    else
        exit 1
    fi
fi
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/metrics.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "metrics_get_json returns [] when file missing" {
    run metrics_get_json
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "metrics_get_json wraps JSONL lines into a JSON array" {
    printf '{"ts":1,"rx":100}\n{"ts":2,"rx":200}\n' > "${AMNEZIAWG_METRICS_FILE}"
    run metrics_get_json
    [ "$status" -eq 0 ]
    [ "$output" = '[{"ts":1,"rx":100},{"ts":2,"rx":200}]' ]
}

@test "metrics_clear removes ring and mirror" {
    printf '{}\n' > "${AMNEZIAWG_METRICS_FILE}"
    printf '{}\n' > "${AMNEZIAWG_WWW_USER}/awg_metrics.htm"
    metrics_clear
    [ ! -f "${AMNEZIAWG_METRICS_FILE}" ]
    [ ! -f "${AMNEZIAWG_WWW_USER}/awg_metrics.htm" ]
}

@test "metrics_ring_trim is a noop when line count <= window" {
    # Reduce window for test speed
    export AMNEZIAWG_METRICS_WINDOW=5
    printf '{"ts":1}\n{"ts":2}\n{"ts":3}\n' > "${AMNEZIAWG_METRICS_FILE}"
    metrics_ring_trim
    [ "$(wc -l < "${AMNEZIAWG_METRICS_FILE}" | tr -d ' ')" = "3" ]
}

@test "metrics_ring_trim keeps only last N lines when oversized" {
    export AMNEZIAWG_METRICS_WINDOW=3
    printf '{"ts":1}\n{"ts":2}\n{"ts":3}\n{"ts":4}\n{"ts":5}\n' > "${AMNEZIAWG_METRICS_FILE}"
    metrics_ring_trim
    [ "$(wc -l < "${AMNEZIAWG_METRICS_FILE}" | tr -d ' ')" = "3" ]
    head -1 "${AMNEZIAWG_METRICS_FILE}" | grep -q '"ts":3'
    tail -1 "${AMNEZIAWG_METRICS_FILE}" | grep -q '"ts":5'
}

@test "metrics_ring_trim tolerates missing file" {
    rm -f "${AMNEZIAWG_METRICS_FILE}"
    run metrics_ring_trim
    [ "$status" -eq 0 ]
}

@test "metrics_sample from empty state writes one line with rate=0" {
    export MOCK_AWG_RX=1000000 MOCK_AWG_TX=500000 MOCK_AWG_HANDSHAKE_AT=0 MOCK_IP_LINK_UP=1
    metrics_sample
    [ -s "${AMNEZIAWG_METRICS_FILE}" ]
    _line="$(cat "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_line}" | grep -q '"rx":1000000'
    echo "${_line}" | grep -q '"tx":500000'
    echo "${_line}" | grep -q '"rx_bps":0'
    echo "${_line}" | grep -q '"tx_bps":0'
    echo "${_line}" | grep -q '"up":1'
}

@test "metrics_sample computes rate vs previous sample" {
    _now=$(date +%s)
    _prev_ts=$((_now - 60))
    printf '{"ts":%s,"rx":1000000,"tx":500000,"rx_bps":0,"tx_bps":0,"hs":0,"up":1}\n' \
           "${_prev_ts}" > "${AMNEZIAWG_METRICS_FILE}"
    export MOCK_AWG_RX=1600000 MOCK_AWG_TX=800000 MOCK_AWG_HANDSHAKE_AT=0 MOCK_IP_LINK_UP=1
    metrics_sample
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"rx_bps":80000'
    echo "${_last}" | grep -q '"tx_bps":40000'
}

@test "metrics_sample clamps rate to 0 on counter wrap" {
    _now=$(date +%s); _prev_ts=$((_now - 60))
    printf '{"ts":%s,"rx":5000000000,"tx":4000000000,"rx_bps":0,"tx_bps":0,"hs":0,"up":1}\n' \
           "${_prev_ts}" > "${AMNEZIAWG_METRICS_FILE}"
    export MOCK_AWG_RX=1000 MOCK_AWG_TX=2000 MOCK_AWG_HANDSHAKE_AT=0 MOCK_IP_LINK_UP=1
    metrics_sample
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"rx_bps":0'
    echo "${_last}" | grep -q '"tx_bps":0'
}

@test "metrics_sample sets up=0 when ip link show fails" {
    export MOCK_AWG_RX=0 MOCK_AWG_TX=0 MOCK_IP_LINK_UP=0
    metrics_sample
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"up":0'
}

@test "metrics_sample computes handshake age correctly" {
    _now=$(date +%s); _hs=$((_now - 42))
    export MOCK_AWG_RX=0 MOCK_AWG_TX=0 MOCK_AWG_HANDSHAKE_AT="${_hs}" MOCK_IP_LINK_UP=1
    metrics_sample
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    # Approximately 42 (within 1s jitter between two `date +%s` calls)
    echo "${_last}" | grep -qE '"hs":(41|42|43)'
}

@test "metrics_sample survives awg binary failure (daemon down)" {
    export MOCK_AWG_FAIL=1 MOCK_IP_LINK_UP=0
    run metrics_sample
    [ "$status" -eq 0 ]
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"rx":0'
    echo "${_last}" | grep -q '"tx":0'
    echo "${_last}" | grep -q '"up":0'
}

@test "metrics_sample mirrors to /www/user atomically" {
    export MOCK_AWG_RX=100 MOCK_AWG_TX=50 MOCK_IP_LINK_UP=1
    metrics_sample
    [ -s "${AMNEZIAWG_WWW_USER}/awg_metrics.htm" ]
    diff "${AMNEZIAWG_METRICS_FILE}" "${AMNEZIAWG_WWW_USER}/awg_metrics.htm"
    ! ls "${AMNEZIAWG_WWW_USER}"/*.tmp 2>/dev/null
}

@test "metrics_sample triggers ring trim when over window" {
    export AMNEZIAWG_METRICS_WINDOW=3
    _now=$(date +%s)
    for i in 1 2 3; do
        printf '{"ts":%s,"rx":0,"tx":0,"rx_bps":0,"tx_bps":0,"hs":0,"up":1}\n' \
               $((_now - 300 + i*60)) >> "${AMNEZIAWG_METRICS_FILE}"
    done
    export MOCK_AWG_RX=100 MOCK_AWG_TX=50 MOCK_IP_LINK_UP=1
    metrics_sample
    _count="$(wc -l < "${AMNEZIAWG_METRICS_FILE}" | tr -d ' ')"
    [ "${_count}" = "3" ]
}
