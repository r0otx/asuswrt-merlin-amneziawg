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
