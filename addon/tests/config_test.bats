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

# --- config_load ---

@test "config_load populates _cfg vars from custom_settings" {
    state_set "awg_enabled" "1"
    state_set "awg_privatekey" "aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address" "10.8.0.2/24"
    state_set "awg_peer_endpoint" "example.com:51820"
    config_load
    [ "${_cfg_enabled}" = "1" ]
    [ "${_cfg_address}" = "10.8.0.2/24" ]
    [ "${_cfg_peer_endpoint}" = "example.com:51820" ]
}

@test "config_load sets empty for missing keys" {
    config_load
    [ -z "${_cfg_privatekey}" ]
    [ -z "${_cfg_peer_endpoint}" ]
}

# --- config_validate (integration) ---

_set_minimal_valid_config() {
    state_set "awg_enabled" "1"
    state_set "awg_privatekey"     "aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"        "10.8.0.2/24"
    state_set "awg_jc"             "4"
    state_set "awg_jmin"           "40"
    state_set "awg_jmax"           "70"
    state_set "awg_h1"             "1"
    state_set "awg_h2"             "2"
    state_set "awg_h3"             "3"
    state_set "awg_h4"             "4"
    state_set "awg_peer_publickey" "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3E="
    state_set "awg_peer_endpoint"  "example.com:51820"
    state_set "awg_peer_allowed_ips" "0.0.0.0/0"
}

@test "config_validate accepts minimal valid config" {
    _set_minimal_valid_config
    config_load
    config_validate
}

@test "config_validate rejects missing privatekey" {
    _set_minimal_valid_config
    state_delete "awg_privatekey"
    config_load
    ! config_validate
    grep -q "privatekey" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate rejects bad H1" {
    _set_minimal_valid_config
    state_set "awg_h1" "abc"
    config_load
    ! config_validate
    grep -q "h1" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate rejects jmax < jmin" {
    _set_minimal_valid_config
    state_set "awg_jmin" "100"
    state_set "awg_jmax" "50"
    config_load
    ! config_validate
    grep -q "jmax" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate accepts H1 range" {
    _set_minimal_valid_config
    state_set "awg_h1" "2072158144-2145681082"
    config_load
    config_validate
}

@test "config_validate accepts optional I1" {
    _set_minimal_valid_config
    state_set "awg_i1" "<b 0xabcd><r 8><t>"
    config_load
    config_validate
}

@test "config_validate rejects bad I1" {
    _set_minimal_valid_config
    state_set "awg_i1" "garbage"
    config_load
    ! config_validate
    grep -q "i1" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate rejects bad MTU" {
    _set_minimal_valid_config
    state_set "awg_mtu" "100"
    config_load
    ! config_validate
    grep -q "mtu" "${AMNEZIAWG_LOG_FILE}"
}

# --- config_emit ---

_set_full_config_from_amnezia2() {
    state_set "awg_enabled"         "1"
    state_set "awg_privatekey"      "aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"         "10.8.0.2/24"
    state_set "awg_dns"             "1.1.1.1"
    state_set "awg_mtu"             "1280"
    state_set "awg_jc"              "4"
    state_set "awg_jmin"            "40"
    state_set "awg_jmax"            "70"
    state_set "awg_s1"              "0"
    state_set "awg_s2"              "0"
    state_set "awg_h1"              "2072158144-2145681082"
    state_set "awg_h2"              "1234"
    state_set "awg_h3"              "5678"
    state_set "awg_h4"              "9012"
    state_set "awg_i1"              "<b 0xabcd><r 8><t>"
    state_set "awg_i2"              "<rd 6>"
    state_set "awg_i3"              "<rc 10>"
    state_set "awg_peer_publickey"    "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3E="
    state_set "awg_peer_presharedkey" "cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHM="
    state_set "awg_peer_endpoint"     "vpn.example.com:51820"
    state_set "awg_peer_allowed_ips"  "0.0.0.0/0,::/0"
    state_set "awg_peer_keepalive"    "25"
}

@test "config_emit writes to target path" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    [ -f "${TMPDIR_TEST}/awg0.conf" ]
}

@test "config_emit matches golden fixture" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    diff -u "${BATS_TEST_DIRNAME}/fixtures/expected-emit-full.conf" \
            "${TMPDIR_TEST}/awg0.conf"
}

@test "config_emit is deterministic (two runs = byte-identical)" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/one.conf"
    config_emit "${TMPDIR_TEST}/two.conf"
    cmp -s "${TMPDIR_TEST}/one.conf" "${TMPDIR_TEST}/two.conf"
}

@test "config_emit uses tmp+mv (no leftover .tmp file)" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    ! ls "${TMPDIR_TEST}/awg0.conf.tmp."* 2>/dev/null
}

@test "config_emit omits empty optional fields" {
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
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    ! grep -q '^DNS '            "${TMPDIR_TEST}/awg0.conf"
    ! grep -q '^I1 '             "${TMPDIR_TEST}/awg0.conf"
    ! grep -q '^PresharedKey '   "${TMPDIR_TEST}/awg0.conf"
}

# --- config_import_from_stdin ---

@test "config_import_from_stdin parses valid Amnezia 2.0 conf" {
    config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/amnezia-2.0-import.conf"
    run state_get "awg_privatekey"
    [ "$output" = "aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=" ]
    run state_get "awg_h1"
    [ "$output" = "2072158144-2145681082" ]
    run state_get "awg_i1"
    [ "$output" = "<b 0xabcd><r 8><t>" ]
    run state_get "awg_peer_endpoint"
    [ "$output" = "vpn.example.com:51820" ]
    run state_get "awg_peer_allowed_ips"
    [ "$output" = "0.0.0.0/0,::/0" ]
}

@test "config_import_from_stdin fails on bad H1" {
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-h1.conf"
}

@test "config_import_from_stdin fails on bad key" {
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-key.conf"
}

@test "config_import_from_stdin fails on bad endpoint" {
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-endpoint.conf"
}

@test "config_import_from_stdin fails on non-conf garbage" {
    ! printf "random text\nno sections\n" | config_import_from_stdin
}

@test "config_import_from_stdin sets awg_enabled=1 after successful import" {
    state_delete "awg_enabled"
    config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/amnezia-2.0-import.conf"
    run state_get "awg_enabled"
    [ "$output" = "1" ]
}

@test "config_import_from_stdin does not partially persist on validation error" {
    state_set "awg_privatekey" "preexisting"
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-h1.conf"
    run state_get "awg_privatekey"
    [ "$output" = "preexisting" ]
}
