#!/usr/bin/env bats
# shellcheck disable=SC2034

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/geo"
    export AMNEZIAWG_GEO_LOCK="${TMPDIR_TEST}/geo.lock"
    mkdir -p "${AMNEZIAWG_RUNTIME}" "${AMNEZIAWG_GEO_ROOT}"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"

    # Mock curl
    mkdir -p "${TMPDIR_TEST}/bin"
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_curl.sh" "${TMPDIR_TEST}/bin/curl"
    chmod +x "${TMPDIR_TEST}/bin/curl"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_CURL_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/v2fly"
    export MOCK_CURL_LOG="${TMPDIR_TEST}/curl.log"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo_parse.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo.sh"

    cat > "${AMNEZIAWG_GEO_ROOT}/sources.env" <<'EOF'
V2FLY_GEOIP_URL_BASE="https://raw.githubusercontent.com/v2fly/geoip/release/text"
V2FLY_DOMAIN_URL_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
FETCH_TIMEOUT=60
FETCH_RETRIES=2
EOF
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "geo_sources_load reads sources.env into shell vars" {
    geo_sources_load
    [ "${V2FLY_GEOIP_URL_BASE}" = "https://raw.githubusercontent.com/v2fly/geoip/release/text" ]
    [ "${FETCH_TIMEOUT}" = "60" ]
}

@test "geo_sources_load uses defaults if sources.env missing" {
    rm "${AMNEZIAWG_GEO_ROOT}/sources.env"
    geo_sources_load
    [ -n "${V2FLY_GEOIP_URL_BASE}" ]
    [ -n "${V2FLY_DOMAIN_URL_BASE}" ]
}

@test "geo_lock_acquire succeeds on first call, fails on second call" {
    run geo_lock_acquire
    [ "$status" -eq 0 ]
    [ -f "${AMNEZIAWG_GEO_LOCK}" ]
    # A second call in a separate process with a different PID must fail.
    # We simulate this by overwriting the lock with a live PID that isn't ours.
    # The harness PID is alive, so any acquire attempt while the lock is held
    # by *another* live PID should fail. Use `sh -c` to get a child shell PID.
    sh -c 'echo $$' > "${AMNEZIAWG_GEO_LOCK}"  # likely stale (child exited) — acquire reclaims
    # For a true "live-other-pid" simulation we use the parent bats PID
    echo "$PPID" > "${AMNEZIAWG_GEO_LOCK}"
    run geo_lock_acquire
    [ "$status" -ne 0 ]
    # cleanup
    rm -f "${AMNEZIAWG_GEO_LOCK}"
    geo_lock_release
}

@test "geo_lock stale after pid death is reclaimable" {
    # PID 999999 is almost certainly not running
    echo "999999" > "${AMNEZIAWG_GEO_LOCK}"
    run geo_lock_acquire
    [ "$status" -eq 0 ]
    geo_lock_release
}

@test "geo_enabled_categories lists cats with mode != off" {
    state_set "awg_geo_ru_mode" "direct"
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_telegram_mode" "off"
    result="$(geo_enabled_categories)"
    echo "${result}" | tr ' ' '\n' | grep -q '^ru$'
    echo "${result}" | tr ' ' '\n' | grep -q '^google$'
    ! echo "${result}" | tr ' ' '\n' | grep -q '^telegram$'
}

@test "geo_category_mode defaults to off when unset" {
    result="$(geo_category_mode "nosuch")"
    [ "${result}" = "off" ]
}

@test "geo_category_mode returns stored mode" {
    state_set "awg_geo_ru_mode" "direct"
    result="$(geo_category_mode "ru")"
    [ "${result}" = "direct" ]
}

@test "_geo_fetch_category downloads ip+domain and emits dnsmasq.conf (mode=vpn → awg_geo_dst)" {
    state_set "awg_geo_google_mode" "vpn"
    mkdir -p "${TMPDIR_TEST}/staging/ip" "${TMPDIR_TEST}/staging/domain" "${TMPDIR_TEST}/staging/dnsmasq.d"
    geo_sources_load
    run _geo_fetch_category "google" "${TMPDIR_TEST}/staging"
    [ "$status" -eq 0 ]
    [ -s "${TMPDIR_TEST}/staging/ip/google.txt" ]
    [ -s "${TMPDIR_TEST}/staging/domain/google.txt" ]
    [ -s "${TMPDIR_TEST}/staging/dnsmasq.d/google.conf" ]
    grep -q 'ipset=/.*/awg_geo_dst$' "${TMPDIR_TEST}/staging/dnsmasq.d/google.conf"
    grep -q 'google.com' "${TMPDIR_TEST}/staging/dnsmasq.d/google.conf"
}

@test "_geo_fetch_category routes mode=direct content into awg_geo_direct" {
    state_set "awg_geo_ru_mode" "direct"
    mkdir -p "${TMPDIR_TEST}/staging/ip" "${TMPDIR_TEST}/staging/domain" "${TMPDIR_TEST}/staging/dnsmasq.d"
    geo_sources_load
    run _geo_fetch_category "ru" "${TMPDIR_TEST}/staging"
    [ "$status" -eq 0 ]
    grep -q 'ipset=/.*/awg_geo_direct$' "${TMPDIR_TEST}/staging/dnsmasq.d/ru.conf"
}

@test "_geo_fetch_category returns non-zero and logs on HTTP failure" {
    export MOCK_CURL_FAIL_URLS="/google\.txt$"
    export MOCK_CURL_FAIL_RC=22
    state_set "awg_geo_google_mode" "vpn"
    mkdir -p "${TMPDIR_TEST}/staging/ip" "${TMPDIR_TEST}/staging/domain" "${TMPDIR_TEST}/staging/dnsmasq.d"
    geo_sources_load
    run _geo_fetch_category "google" "${TMPDIR_TEST}/staging"
    [ "$status" -ne 0 ]
}

@test "_geo_fetch_category skips off category" {
    state_set "awg_geo_google_mode" "off"
    mkdir -p "${TMPDIR_TEST}/staging/ip" "${TMPDIR_TEST}/staging/domain" "${TMPDIR_TEST}/staging/dnsmasq.d"
    geo_sources_load
    run _geo_fetch_category "google" "${TMPDIR_TEST}/staging"
    [ "$status" -ne 0 ]
}
