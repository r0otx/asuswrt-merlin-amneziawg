#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

# --- _config_validate_key ---

@test "validate_key accepts 44-char base64" {
    _config_validate_key "aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
}

@test "validate_key rejects short string" {
    ! _config_validate_key "too-short"
}

@test "validate_key rejects non-base64 alphabet" {
    ! _config_validate_key "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}

@test "validate_key rejects empty string" {
    ! _config_validate_key ""
}

# --- _config_validate_addr ---

@test "validate_addr accepts 10.8.0.2/24" {
    _config_validate_addr "10.8.0.2/24"
}

@test "validate_addr accepts 192.168.1.1/32" {
    _config_validate_addr "192.168.1.1/32"
}

@test "validate_addr rejects missing prefix" {
    ! _config_validate_addr "10.8.0.2"
}

@test "validate_addr rejects bad octet" {
    ! _config_validate_addr "999.0.0.1/24"
}

@test "validate_addr rejects prefix >32" {
    ! _config_validate_addr "10.8.0.2/33"
}

# --- _config_validate_endpoint ---

@test "validate_endpoint accepts host:port" {
    _config_validate_endpoint "example.com:51820"
}

@test "validate_endpoint accepts IP:port" {
    _config_validate_endpoint "1.2.3.4:443"
}

@test "validate_endpoint rejects missing port" {
    ! _config_validate_endpoint "example.com"
}

@test "validate_endpoint rejects port=0" {
    ! _config_validate_endpoint "example.com:0"
}

@test "validate_endpoint rejects port>65535" {
    ! _config_validate_endpoint "example.com:70000"
}

# --- _config_validate_cidr_list ---

@test "validate_cidr_list accepts single cidr" {
    _config_validate_cidr_list "0.0.0.0/0"
}

@test "validate_cidr_list accepts multiple cidrs" {
    _config_validate_cidr_list "10.0.0.0/8,192.168.0.0/16"
}

@test "validate_cidr_list accepts IPv6" {
    _config_validate_cidr_list "0.0.0.0/0,::/0"
}

@test "validate_cidr_list rejects empty" {
    ! _config_validate_cidr_list ""
}

@test "validate_cidr_list rejects bad entry" {
    ! _config_validate_cidr_list "10.0.0.0/8,garbage"
}

# --- _config_validate_int_range ---

@test "validate_int_range accepts value in range" {
    _config_validate_int_range "500" 100 1000
}

@test "validate_int_range rejects below min" {
    ! _config_validate_int_range "50" 100 1000
}

@test "validate_int_range rejects above max" {
    ! _config_validate_int_range "1500" 100 1000
}

@test "validate_int_range rejects non-numeric" {
    ! _config_validate_int_range "abc" 100 1000
}

# --- _config_validate_h_value (AmneziaWG 2.0 range syntax) ---

@test "validate_h_value accepts single int" {
    _config_validate_h_value "12345"
}

@test "validate_h_value accepts range" {
    _config_validate_h_value "2072158144-2145681082"
}

@test "validate_h_value rejects range with min>max" {
    ! _config_validate_h_value "100-50"
}

@test "validate_h_value rejects non-numeric" {
    ! _config_validate_h_value "abc"
}

@test "validate_h_value rejects empty" {
    ! _config_validate_h_value ""
}

@test "validate_h_value accepts range with equal bounds" {
    _config_validate_h_value "100-100"
}

# --- _config_validate_i_sequence (I1-I5 tagged syntax) ---

@test "validate_i_sequence accepts empty (field absent)" {
    _config_validate_i_sequence ""
}

@test "validate_i_sequence accepts static bytes tag" {
    _config_validate_i_sequence "<b 0xabcd>"
}

@test "validate_i_sequence accepts random bytes tag" {
    _config_validate_i_sequence "<r 8>"
}

@test "validate_i_sequence accepts random digits tag" {
    _config_validate_i_sequence "<rd 6>"
}

@test "validate_i_sequence accepts random chars tag" {
    _config_validate_i_sequence "<rc 10>"
}

@test "validate_i_sequence accepts timestamp tag" {
    _config_validate_i_sequence "<t>"
}

@test "validate_i_sequence accepts compound sequence" {
    _config_validate_i_sequence "<b 0xabcd><r 8><t>"
}

@test "validate_i_sequence rejects odd-length hex in b tag" {
    ! _config_validate_i_sequence "<b 0xabc>"
}

@test "validate_i_sequence rejects unknown tag" {
    ! _config_validate_i_sequence "<x 5>"
}

@test "validate_i_sequence rejects stray text between tags" {
    ! _config_validate_i_sequence "<t>garbage<r 8>"
}

@test "validate_i_sequence rejects unclosed tag" {
    ! _config_validate_i_sequence "<t"
}
