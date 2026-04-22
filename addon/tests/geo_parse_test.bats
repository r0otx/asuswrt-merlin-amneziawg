#!/usr/bin/env bats
# shellcheck disable=SC2034

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo_parse.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "geo_filter_domain keeps domain: / full: and drops regexp:" {
    result="$(geo_filter_domain < "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain/ru")"
    echo "${result}" | grep -q '^yandex.ru$'
    echo "${result}" | grep -q '^mail.ru$'
    echo "${result}" | grep -q '^vk.com$'
    ! echo "${result}" | grep -q 'sberbank'
}

@test "geo_filter_domain strips @attribute suffixes and whitespace" {
    result="$(printf 'domain:example.com @cn\nfull:a.b @ad\n' | geo_filter_domain)"
    [ "$(echo "${result}" | sed -n 1p)" = "example.com" ]
    [ "$(echo "${result}" | sed -n 2p)" = "a.b" ]
}

@test "geo_filter_domain skips blank lines and comments" {
    result="$(printf '# comment\n\ndomain:ok.net\n   \n' | geo_filter_domain)"
    [ "$(echo "${result}" | wc -l | tr -d ' ')" = "1" ]
    echo "${result}" | grep -q '^ok.net$'
}

@test "geo_filter_domain passes through include: lines untouched" {
    result="$(printf 'include:youtube\ndomain:google.com\n' | geo_filter_domain)"
    echo "${result}" | grep -q '^include:youtube$'
    echo "${result}" | grep -q '^google.com$'
}

@test "geo_resolve_includes expands 3-level chain" {
    cd "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain"
    result="$(geo_filter_domain < includes-a | geo_resolve_includes "." "3" "includes-a")"
    echo "${result}" | grep -q '^a.com$'
    echo "${result}" | grep -q '^b.com$'
    echo "${result}" | grep -q '^c.com$'
    ! echo "${result}" | grep -q '^include:'
}

@test "geo_resolve_includes caps recursion at max depth (logs warn)" {
    cd "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain"
    # With depth=1, includes-a expansion resolves includes-b but not includes-c
    result="$(geo_filter_domain < includes-a | geo_resolve_includes "." "1" "includes-a")"
    echo "${result}" | grep -q '^a.com$'
    echo "${result}" | grep -q '^b.com$'
    ! echo "${result}" | grep -q '^c.com$'
    grep -q 'geo_resolve_includes: depth cap' "${AMNEZIAWG_LOG_FILE}"
}

@test "geo_resolve_includes detects cycle and stops" {
    cd "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain"
    result="$(geo_filter_domain < cycle-a | geo_resolve_includes "." "5" "cycle-a")"
    echo "${result}" | grep -q '^ca.com$'
    echo "${result}" | grep -q '^cb.com$'
    # Must terminate; no duplicate ca.com beyond first occurrence
    [ "$(echo "${result}" | grep -c '^ca.com$')" -eq 1 ]
    grep -q 'geo_resolve_includes: cycle detected' "${AMNEZIAWG_LOG_FILE}"
}

@test "geo_resolve_includes handles missing include target gracefully" {
    result="$(printf 'domain:ok.com\ninclude:nonexistent\n' | geo_filter_domain | geo_resolve_includes "${TMPDIR_TEST}" "3" "root")"
    echo "${result}" | grep -q '^ok.com$'
    grep -q 'geo_resolve_includes: missing' "${AMNEZIAWG_LOG_FILE}"
}
