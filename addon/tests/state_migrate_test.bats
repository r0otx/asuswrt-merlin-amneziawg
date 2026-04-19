#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"

    # Simulate v1 layout under TMPDIR so tar/rm doesn't touch real root.
    export AMNEZIAWG_V1_ADDON_DIR="${TMPDIR_TEST}/jffs/addons/amneziawg"
    export AMNEZIAWG_V1_OPT_DIR="${TMPDIR_TEST}/opt/amneziawg"
    export AMNEZIAWG_BACKUP_DIR="${TMPDIR_TEST}/opt/etc/amneziawg/backups"
    export AMNEZIAWG_V2_CONF="${TMPDIR_TEST}/opt/etc/amneziawg/awg0.conf"
    export AMNEZIAWG_UNMIGRATED_KEYS="${TMPDIR_TEST}/opt/etc/amneziawg/backups/v1-unmigrated-keys.txt"
    export AMNEZIAWG_MIGRATED_FLAG="${TMPDIR_TEST}/jffs/addons/amneziawg/.migrated-from-v1"
    export AMNEZIAWG_JFFS_SCRIPTS="${TMPDIR_TEST}/jffs/scripts"
    export AWG_VERSION="0.0.0-dev"

    mkdir -p "${AMNEZIAWG_V1_ADDON_DIR}" "${AMNEZIAWG_V1_OPT_DIR}" \
             "${AMNEZIAWG_JFFS_SCRIPTS}" \
             "$(dirname "${AMNEZIAWG_V2_CONF}")"

    # Create v1 amneziawg.sh (marker for detection)
    cat > "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh" <<'EOF'
#!/bin/sh
case "$1" in
    stop) exit 0 ;;
esac
EOF
    chmod +x "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh"

    # Create v1 awg0.conf
    cp "${BATS_TEST_DIRNAME}/fixtures/v1-awg0.conf" \
       "${AMNEZIAWG_V1_OPT_DIR}/awg0.conf"

    # Pre-populate custom_settings with v1 keys (from fixture)
    cp "${BATS_TEST_DIRNAME}/fixtures/v1-custom-settings.txt" \
       "${AMNEZIAWG_CUSTOM_SETTINGS}"

    # Create hook files with v1 entries mixed in with other lines
    for h in service-event firewall-start wan-event services-start; do
        cat > "${AMNEZIAWG_JFFS_SCRIPTS}/${h}" <<EOF
#!/bin/sh
# user script
echo "user line 1"
/jffs/addons/amneziawg/amneziawg.sh ${h}_handler "\$@"
echo "user line 2 referencing amneziawg in comment"
EOF
    done

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "migrate_from_v1 detects v1 and proceeds" {
    run migrate_from_v1
    [ "$status" -eq 0 ]
    grep -q "v1 detected" "${AMNEZIAWG_LOG_FILE}"
}

@test "migrate_from_v1 creates backup tarball" {
    migrate_from_v1
    ls "${AMNEZIAWG_BACKUP_DIR}"/backup-v1-*.tar.gz >/dev/null
}

@test "migrate_from_v1 copies awg0.conf to v2 path" {
    migrate_from_v1
    [ -f "${AMNEZIAWG_V2_CONF}" ]
    grep -q '^PrivateKey = ' "${AMNEZIAWG_V2_CONF}"
}

@test "migrate_from_v1 translates known keys" {
    migrate_from_v1
    run state_get "awg_privatekey"
    [ "$output" = "aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=" ]
    run state_get "awg_peer_endpoint"
    [ "$output" = "example.com:51820" ]
    run state_get "awg_jc"
    [ "$output" = "4" ]
}

@test "migrate_from_v1 deletes v1 keys after translation" {
    migrate_from_v1
    run state_get "amneziawg_privatekey"
    [ -z "$output" ]
}

@test "migrate_from_v1 preserves non-amneziawg keys" {
    migrate_from_v1
    run state_get "unrelated_key"
    [ "$output" = "leave_me_alone" ]
}

@test "migrate_from_v1 saves unmigrated v1 keys" {
    migrate_from_v1
    [ -f "${AMNEZIAWG_UNMIGRATED_KEYS}" ]
    grep -q "amneziawg_devices" "${AMNEZIAWG_UNMIGRATED_KEYS}"
}

@test "migrate_from_v1 removes v1 hook invocation line" {
    migrate_from_v1
    ! grep -q "/jffs/addons/amneziawg/amneziawg.sh" \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "migrate_from_v1 preserves user lines and unrelated comments" {
    migrate_from_v1
    grep -q "user line 1" "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    grep -q "user line 2 referencing amneziawg in comment" \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "migrate_from_v1 writes migration flag" {
    migrate_from_v1
    [ -f "${AMNEZIAWG_MIGRATED_FLAG}" ]
    grep -q "migrated_at=" "${AMNEZIAWG_MIGRATED_FLAG}"
    grep -q "v2_version=" "${AMNEZIAWG_MIGRATED_FLAG}"
}

@test "migrate_from_v1 is idempotent (second call is noop)" {
    migrate_from_v1
    _ts_first=$(stat -f %m "${AMNEZIAWG_MIGRATED_FLAG}" 2>/dev/null \
                || stat -c %Y "${AMNEZIAWG_MIGRATED_FLAG}")
    sleep 1
    migrate_from_v1
    _ts_second=$(stat -f %m "${AMNEZIAWG_MIGRATED_FLAG}" 2>/dev/null \
                || stat -c %Y "${AMNEZIAWG_MIGRATED_FLAG}")
    [ "${_ts_first}" = "${_ts_second}" ]
    grep -q "no v1 detected, skipping" "${AMNEZIAWG_LOG_FILE}"
}

@test "backup_before_remove creates v2 backup tarball" {
    state_set "awg_privatekey" "xxx"
    backup_before_remove
    ls "${AMNEZIAWG_BACKUP_DIR}"/backup-v2-*.tar.gz >/dev/null
}
