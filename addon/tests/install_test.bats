#!/usr/bin/env bats
# shellcheck disable=SC2034

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/opt/etc/amneziawg/geo"
    export AMNEZIAWG_GEO_LOCK="${TMPDIR_TEST}/geo.lock"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    mkdir -p "${AMNEZIAWG_RUNTIME}"

    # Fake AWG_ADDON_DIR containing an etc/amneziawg/sources.env
    export AWG_ADDON_DIR="${TMPDIR_TEST}/addon_mock"
    mkdir -p "${AWG_ADDON_DIR}/etc/amneziawg"
    cat > "${AWG_ADDON_DIR}/etc/amneziawg/sources.env" <<'EOF'
V2FLY_GEOIP_URL_BASE="https://raw.githubusercontent.com/v2fly/geoip/release/text"
V2FLY_DOMAIN_URL_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
FETCH_TIMEOUT=60
FETCH_RETRIES=2
EOF

    # Mocks: cru, bind mount helpers stubbed
    mkdir -p "${TMPDIR_TEST}/bin"
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_cru.sh" "${TMPDIR_TEST}/bin/cru"
    chmod +x "${TMPDIR_TEST}/bin/cru"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_CRU_LOG="${TMPDIR_TEST}/cru.log"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo_parse.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo.sh"

    # Stub helpers that install.sh dependency-checks for
    hooks_register()   { printf 'hooks_register\n'   >> "${TMPDIR_TEST}/hooks.log"; }
    hooks_unregister() { printf 'hooks_unregister\n' >> "${TMPDIR_TEST}/hooks.log"; }
    ui_mount()         { printf 'ui_mount\n'         >> "${TMPDIR_TEST}/ui.log"; }
    ui_unmount()       { printf 'ui_unmount\n'       >> "${TMPDIR_TEST}/ui.log"; }
    tunnel_stop()      { printf 'tunnel_stop\n'      >> "${TMPDIR_TEST}/tunnel.log"; }
    migrate_from_v1()  { return 0; }
    backup_before_remove() { return 0; }

    . "${BATS_TEST_DIRNAME}/../lib/install.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "install_run creates geo tree and copies sources.env" {
    install_run
    [ -d "${AMNEZIAWG_GEO_ROOT}/ip" ]
    [ -d "${AMNEZIAWG_GEO_ROOT}/domain" ]
    [ -d "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d" ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/sources.env" ]
    grep -q "V2FLY_GEOIP_URL_BASE" "${AMNEZIAWG_GEO_ROOT}/sources.env"
}

@test "install_run preserves existing sources.env (does not overwrite user edits)" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}"
    printf 'USER_CUSTOM=yes\n' > "${AMNEZIAWG_GEO_ROOT}/sources.env"
    install_run
    grep -q "USER_CUSTOM=yes" "${AMNEZIAWG_GEO_ROOT}/sources.env"
    ! grep -q "V2FLY_GEOIP_URL_BASE" "${AMNEZIAWG_GEO_ROOT}/sources.env"
}

@test "install_run registers awggeosync cron" {
    install_run
    grep -q "^a ${AMNEZIAWG_GEO_CRON_ID}" "${MOCK_CRU_LOG}"
}

@test "uninstall_run deregisters awggeosync cron" {
    install_run
    : > "${MOCK_CRU_LOG}"
    uninstall_run
    grep -q "^d ${AMNEZIAWG_GEO_CRON_ID}" "${MOCK_CRU_LOG}"
}
