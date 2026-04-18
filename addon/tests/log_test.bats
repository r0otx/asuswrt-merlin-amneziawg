#!/usr/bin/env bats

setup() {
    LOG_TAG_TEST="amneziawg-test-$$"
    export AMNEZIAWG_LOG_TAG="${LOG_TAG_TEST}"
    # Override logger to write to a file we control, instead of syslog
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    # shellcheck source=../lib/log.sh
    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "log_info writes INFO-prefixed line" {
    log_info "hello"
    grep -q "INFO  hello" "${AMNEZIAWG_LOG_FILE}"
}

@test "log_warn writes WARN-prefixed line" {
    log_warn "careful"
    grep -q "WARN  careful" "${AMNEZIAWG_LOG_FILE}"
}

@test "log_error writes ERROR-prefixed line and returns non-zero when used as guard" {
    log_error "bang" || true
    grep -q "ERROR bang" "${AMNEZIAWG_LOG_FILE}"
}

@test "log_debug is silent when LOG_LEVEL=info" {
    export AMNEZIAWG_LOG_LEVEL=info
    log_debug "shh"
    ! grep -q "DEBUG shh" "${AMNEZIAWG_LOG_FILE}"
}

@test "log_debug is emitted when LOG_LEVEL=debug" {
    export AMNEZIAWG_LOG_LEVEL=debug
    log_debug "heard"
    grep -q "DEBUG heard" "${AMNEZIAWG_LOG_FILE}"
}
