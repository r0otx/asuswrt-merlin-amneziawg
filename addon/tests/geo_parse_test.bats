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
