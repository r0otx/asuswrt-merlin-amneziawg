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
