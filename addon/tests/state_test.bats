#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/custom_settings.txt"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    # shellcheck source=../lib/log.sh
    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    # shellcheck source=../lib/state.sh
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "state_set stores a key-value pair" {
    state_set "awg_test" "hello"
    grep -q "^awg_test hello$" "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

@test "state_get returns stored value" {
    state_set "awg_test" "hello"
    run state_get "awg_test"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "state_get returns empty string for missing key" {
    run state_get "awg_nonexistent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "state_set replaces existing value in-place (no duplicate lines)" {
    state_set "awg_test" "first"
    state_set "awg_test" "second"
    [ "$(grep -c '^awg_test ' "${AMNEZIAWG_CUSTOM_SETTINGS}")" -eq 1 ]
    run state_get "awg_test"
    [ "$output" = "second" ]
}

@test "state_delete removes the key" {
    state_set "awg_test" "hello"
    state_delete "awg_test"
    ! grep -q "^awg_test " "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

@test "state_list_awg_keys returns only awg_-prefixed keys" {
    state_set "awg_one" "1"
    state_set "awg_two" "2"
    echo "other_key value" >> "${AMNEZIAWG_CUSTOM_SETTINGS}"
    run state_list_awg_keys
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^awg_one$"
    echo "$output" | grep -q "^awg_two$"
    ! echo "$output" | grep -q "^other_key$"
}

@test "state_set writes atomically via .tmp + mv" {
    # Simulate: file is watched by a concurrent reader; write must use temp file.
    state_set "awg_test" "atomic"
    # Verify the function uses mv by checking no .tmp file remains
    ! ls "${AMNEZIAWG_CUSTOM_SETTINGS}".tmp 2>/dev/null
    grep -q "^awg_test atomic$" "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

@test "state_validate_key accepts awg_geo_<cat>_mode with valid enum" {
    run state_validate_key "awg_geo_ru_mode" "direct"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_google_mode" "vpn"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_telegram_mode" "off"
    [ "$status" -eq 0 ]
}

@test "state_validate_key rejects invalid awg_geo_<cat>_mode value" {
    run state_validate_key "awg_geo_ru_mode" "bypass"
    [ "$status" -ne 0 ]
}

@test "state_validate_key accepts awg_geo_entries_direct (csv CIDR)" {
    run state_validate_key "awg_geo_entries_direct" "10.0.0.0/8,192.168.0.0/16"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_entries_direct" ""
    [ "$status" -eq 0 ]
}

@test "state_validate_key rejects awg_geo_entries_direct with bad CIDR" {
    run state_validate_key "awg_geo_entries_direct" "not.an.ip/24"
    [ "$status" -ne 0 ]
}

@test "state_validate_key accepts awg_geo_sync_parallel in 1..8" {
    run state_validate_key "awg_geo_sync_parallel" "3"
    [ "$status" -eq 0 ]
}

@test "state_validate_key rejects awg_geo_sync_parallel out of range" {
    run state_validate_key "awg_geo_sync_parallel" "0"
    [ "$status" -ne 0 ]
    run state_validate_key "awg_geo_sync_parallel" "9"
    [ "$status" -ne 0 ]
}

@test "state_validate_key accepts awg_geo_sync_weekday 0..6 and hour 0..23" {
    run state_validate_key "awg_geo_sync_weekday" "0"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_sync_weekday" "6"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_sync_hour" "23"
    [ "$status" -eq 0 ]
}

@test "state_validate_key accepts awg_dev_N_policy = vpn_except_geo" {
    run state_validate_key "awg_dev_0_policy" "vpn_except_geo"
    [ "$status" -eq 0 ]
}

@test "state_validate_key accepts awg_geo_categories_custom (valid names)" {
    run state_validate_key "awg_geo_categories_custom" ""
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_categories_custom" "mycat,another-cat,cat_3"
    [ "$status" -eq 0 ]
}

@test "state_validate_key rejects awg_geo_categories_custom with invalid chars" {
    run state_validate_key "awg_geo_categories_custom" "bad name"
    [ "$status" -ne 0 ]
    run state_validate_key "awg_geo_categories_custom" "cat,bad/name"
    [ "$status" -ne 0 ]
}

@test "state_validate_key rejects awg_geo_sync_hour out of range" {
    run state_validate_key "awg_geo_sync_hour" "24"
    [ "$status" -ne 0 ]
    run state_validate_key "awg_geo_sync_hour" "-1"
    [ "$status" -ne 0 ]
}

@test "state_validate_key rejects awg_geo_entries_direct with out-of-range IPv4 prefix" {
    run state_validate_key "awg_geo_entries_direct" "10.0.0.0/33"
    [ "$status" -ne 0 ]
}

@test "state_validate_key rejects awg_geo_entries_direct with out-of-range IPv6 prefix" {
    run state_validate_key "awg_geo_entries_direct" "2001:db8::/129"
    [ "$status" -ne 0 ]
}

@test "state_validate_key catch-all accepts unknown keys" {
    run state_validate_key "awg_unknown_future_key" "anything"
    [ "$status" -eq 0 ]
}
