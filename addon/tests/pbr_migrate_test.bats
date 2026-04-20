#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_V1_ADDON_DIR="${TMPDIR_TEST}/jffs/addons/amneziawg"
    export AMNEZIAWG_V1_OPT_DIR="${TMPDIR_TEST}/opt/amneziawg"
    export AMNEZIAWG_BACKUP_DIR="${TMPDIR_TEST}/opt/etc/amneziawg/backups"
    export AMNEZIAWG_V2_CONF="${TMPDIR_TEST}/opt/etc/amneziawg/awg0.conf"
    export AMNEZIAWG_UNMIGRATED_KEYS="${TMPDIR_TEST}/opt/etc/amneziawg/backups/v1-unmigrated-keys.txt"
    export AMNEZIAWG_MIGRATED_FLAG="${TMPDIR_TEST}/jffs/addons/amneziawg/.migrated-from-v1"
    export AMNEZIAWG_JFFS_SCRIPTS="${TMPDIR_TEST}/jffs/scripts"
    export AWG_VERSION="0.0.0-dev"

    mkdir -p "${AMNEZIAWG_V1_ADDON_DIR}" "${AMNEZIAWG_V1_OPT_DIR}" \
             "${AMNEZIAWG_JFFS_SCRIPTS}" "$(dirname "${AMNEZIAWG_V2_CONF}")"
    cat > "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh"

    cp "${BATS_TEST_DIRNAME}/fixtures/v1-custom-settings.txt" \
       "${AMNEZIAWG_CUSTOM_SETTINGS}"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "migrate_from_v1 translates amneziawg_devices JSON into awg_dev_N_* keys" {
    migrate_from_v1
    run state_get "awg_dev_count"
    [ "$output" = "2" ]
    run state_get "awg_dev_0_ip"
    [ "$output" = "192.168.1.100" ]
    run state_get "awg_dev_0_policy"
    [ "$output" = "vpn_all" ]
    run state_get "awg_dev_1_ip"
    [ "$output" = "192.168.1.105" ]
    run state_get "awg_dev_1_policy"
    [ "$output" = "vpn_geo" ]
}

@test "migrate_from_v1 translates v1 policy 'all' to 'vpn_all'" {
    # Override fixture
    awk '$1 != "amneziawg_devices"' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp"
    printf 'amneziawg_devices [{"ip":"10.0.0.1","policy":"all","name":"x","mac":""}]\n' \
        >> "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp"
    mv "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp" "${AMNEZIAWG_CUSTOM_SETTINGS}"
    migrate_from_v1
    run state_get "awg_dev_0_policy"
    [ "$output" = "vpn_all" ]
}

@test "migrate_from_v1 translates v1 policy 'geo' to 'vpn_geo'" {
    awk '$1 != "amneziawg_devices"' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp"
    printf 'amneziawg_devices [{"ip":"10.0.0.1","policy":"geo","name":"x","mac":""}]\n' \
        >> "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp"
    mv "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp" "${AMNEZIAWG_CUSTOM_SETTINGS}"
    migrate_from_v1
    run state_get "awg_dev_0_policy"
    [ "$output" = "vpn_geo" ]
}

@test "migrate_from_v1 preserves v1 default_policy into awg_default_policy" {
    migrate_from_v1
    run state_get "awg_default_policy"
    [ "$output" = "direct" ]
}

@test "migrate_from_v1 tolerates missing amneziawg_devices key" {
    awk '$1 != "amneziawg_devices"' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp"
    mv "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp" "${AMNEZIAWG_CUSTOM_SETTINGS}"
    migrate_from_v1
    run state_get "awg_dev_count"
    # count stays unset or 0
    case "$output" in ""|0) : ;; *) false ;; esac
}

@test "migrate_from_v1 tolerates malformed JSON (logs warning, continues)" {
    awk '$1 != "amneziawg_devices"' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp"
    printf 'amneziawg_devices garbage-not-json\n' >> "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp"
    mv "${AMNEZIAWG_CUSTOM_SETTINGS}.tmp" "${AMNEZIAWG_CUSTOM_SETTINGS}"
    run migrate_from_v1
    [ "$status" -eq 0 ]
    grep -q "v1 devices blob unparseable" "${AMNEZIAWG_LOG_FILE}"
}
