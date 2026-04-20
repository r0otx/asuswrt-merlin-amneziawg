#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"

    . "${BATS_TEST_DIRNAME}/fixtures/mock_iptables.sh"
    mock_iptables_install
    export PATH="${TMPDIR_TEST}/bin:${PATH}"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/iptables_chain.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "chain_ensure creates chain on first call" {
    chain_ensure mangle FOO
    iptables -t mangle -S FOO | grep -q '^:FOO '
}

@test "chain_ensure is idempotent (second call no error)" {
    chain_ensure mangle FOO
    chain_ensure mangle FOO
    [ "$(iptables -t mangle -S FOO | grep -c '^:FOO ')" -eq 1 ]
}

@test "chain_flush empties target chain only" {
    chain_ensure mangle FOO
    chain_ensure mangle BAR
    iptables -t mangle -A FOO -s 1.2.3.4 -j MARK
    iptables -t mangle -A BAR -s 5.6.7.8 -j MARK
    chain_flush mangle FOO
    [ -z "$(iptables -t mangle -S FOO | grep '^-A FOO ')" ]
    iptables -t mangle -S BAR | grep -q '^-A BAR -s 5.6.7.8'
}

@test "chain_delete removes chain entirely" {
    chain_ensure mangle FOO
    chain_delete mangle FOO
    ! iptables -t mangle -S FOO | grep -q '^:FOO '
}

@test "rule_exists returns 0 when rule present" {
    chain_ensure mangle FOO
    iptables -t mangle -A FOO -s 1.2.3.4 -j MARK
    rule_exists mangle FOO -s 1.2.3.4 -j MARK
}

@test "rule_exists returns 1 when rule absent" {
    chain_ensure mangle FOO
    ! rule_exists mangle FOO -s 9.9.9.9 -j MARK
}

@test "rule_add_if_missing adds only on first call" {
    chain_ensure mangle FOO
    rule_add_if_missing mangle FOO -s 1.2.3.4 -j MARK
    rule_add_if_missing mangle FOO -s 1.2.3.4 -j MARK
    [ "$(iptables -t mangle -S FOO | grep -c -- '-s 1.2.3.4 -j MARK')" -eq 1 ]
}

@test "rule_del_if_exists tolerates missing rule" {
    chain_ensure mangle FOO
    rule_del_if_exists mangle FOO -s 9.9.9.9 -j MARK
    # no error, chain still exists
    iptables -t mangle -S FOO | grep -q '^:FOO '
}
