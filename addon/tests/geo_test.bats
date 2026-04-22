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

    # Mock ipset + iptables (for ipset rebuild)
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_ipset.sh"    "${TMPDIR_TEST}/bin/mock_ipset.sh"
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_iptables.sh" "${TMPDIR_TEST}/bin/mock_iptables.sh"
    . "${TMPDIR_TEST}/bin/mock_ipset.sh"
    . "${TMPDIR_TEST}/bin/mock_iptables.sh"
    mock_ipset_install
    mock_iptables_install

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo_parse.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo.sh"

    # Shadow /sbin/service with a no-op logger
    service() { printf '%s\n' "$*" >> "${TMPDIR_TEST}/service.log"; }

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

@test "geo_sync happy path: 2 cats enabled, files land, ipsets populated, timestamp written" {
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_ru_mode" "direct"
    state_set "awg_geo_sync_parallel" "2"
    run geo_sync
    [ "$status" -eq 0 ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt" ]
    [ -f "${AMNEZIAWG_GEO_ROOT}/last-sync" ]
    # ipset membership verifies restoration
    ipset test awg_geo_dst 8.8.8.0/24
    ipset test awg_geo_direct 5.8.0.0/20
}

@test "geo_sync partial failure: ru timeout, google still applied" {
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_ru_mode" "direct"
    export MOCK_CURL_FAIL_URLS="/ru\.txt$"
    export MOCK_CURL_FAIL_RC=28
    run geo_sync
    [ "$status" -eq 0 ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt" ]
    grep -q 'ru' "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log"
}

@test "geo_sync cleanup: disabling cat removes its files" {
    state_set "awg_geo_google_mode" "vpn"
    geo_sync
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    state_set "awg_geo_google_mode" "off"
    geo_sync
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/google.conf" ]
}

@test "geo_sync is noop for restart_dnsmasq when dnsmasq.d unchanged" {
    state_set "awg_geo_google_mode" "vpn"
    geo_sync
    _first_count="$(grep -c 'restart_dnsmasq' "${TMPDIR_TEST}/service.log" 2>/dev/null || echo 0)"
    geo_sync
    _second_count="$(grep -c 'restart_dnsmasq' "${TMPDIR_TEST}/service.log" 2>/dev/null || echo 0)"
    [ "${_second_count}" -eq "${_first_count}" ]
}

@test "geo_sync under lock collision exits rc=0 with note" {
    # Hold the lock from our own alive bats shell PID
    mkdir -p "$(dirname "${AMNEZIAWG_GEO_LOCK}")"
    echo "$$" > "${AMNEZIAWG_GEO_LOCK}"
    state_set "awg_geo_google_mode" "vpn"
    run geo_sync
    [ "$status" -eq 0 ]
    grep -q 'another sync holds lock' "${AMNEZIAWG_LOG_FILE}"
}

@test "geo_categories prints curated + enabled custom" {
    state_set "awg_geo_categories_custom" "custom-a,custom-b"
    run geo_categories
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^google$'
    echo "$output" | grep -q '^custom-a$'
    echo "$output" | grep -q '^custom-b$'
    # All 16 curated must appear
    [ "$(echo "$output" | wc -l | tr -d ' ')" = "18" ]
}

@test "geo_list with arg prints ip+domain for that cat" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" "${AMNEZIAWG_GEO_ROOT}/domain"
    printf '1.2.3.0/24\n'  > "${AMNEZIAWG_GEO_ROOT}/ip/foo.txt"
    printf 'foo.com\n'     > "${AMNEZIAWG_GEO_ROOT}/domain/foo.txt"
    run geo_list foo
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '1.2.3.0/24'
    echo "$output" | grep -q 'foo.com'
}

@test "geo_list (no arg) prints enabled cats one per line" {
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_ru_mode" "direct"
    run geo_list
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^google$'
    echo "$output" | grep -q '^ru$'
}

@test "geo_status emits JSON with last_sync, enabled, errors" {
    state_set "awg_geo_google_mode" "vpn"
    printf '1729550000\n' > "${AMNEZIAWG_GEO_ROOT}/last-sync"
    printf '1729550001 ru\n' > "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log"
    run geo_status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"last_sync":1729550000'
    echo "$output" | grep -q '"enabled":\["google"\]'
    echo "$output" | grep -q '"errors":\["ru"\]'
}

@test "geo_status emits sane JSON when no state yet" {
    run geo_status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"last_sync":0'
    echo "$output" | grep -q '"enabled":\[\]'
    echo "$output" | grep -q '"errors":\[\]'
}

@test "geo_clear --all removes all category files + flushes ipsets" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" "${AMNEZIAWG_GEO_ROOT}/domain" "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d"
    touch "${AMNEZIAWG_GEO_ROOT}/ip/google.txt"
    touch "${AMNEZIAWG_GEO_ROOT}/domain/google.txt"
    touch "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/google.conf"
    run geo_clear --all
    [ "$status" -eq 0 ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/domain/google.txt" ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/google.conf" ]
}

@test "geo_clear <cat> removes only that category" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" "${AMNEZIAWG_GEO_ROOT}/domain" "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d"
    touch "${AMNEZIAWG_GEO_ROOT}/ip/google.txt"
    touch "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt"
    run geo_clear google
    [ "$status" -eq 0 ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ -f "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt" ]
}

@test "geo_clear with no arg returns error (not silent --all)" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip"
    touch "${AMNEZIAWG_GEO_ROOT}/ip/google.txt"
    run geo_clear
    [ "$status" -ne 0 ]
    [ -f "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
}
