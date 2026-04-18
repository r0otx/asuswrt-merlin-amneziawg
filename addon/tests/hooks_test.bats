#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_JFFS_SCRIPTS="${TMPDIR_TEST}/scripts"
    export AMNEZIAWG_ADDON_DIR="${BATS_TEST_DIRNAME}/.."
    mkdir -p "${AMNEZIAWG_JFFS_SCRIPTS}"
    for h in service-event firewall-start wan-event services-start; do
        cat > "${AMNEZIAWG_JFFS_SCRIPTS}/${h}" <<'EOF'
#!/bin/sh
# existing user content
echo "user line"
EOF
        chmod +x "${AMNEZIAWG_JFFS_SCRIPTS}/${h}"
    done
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    # shellcheck source=../lib/log.sh
    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    # shellcheck source=../lib/hooks.sh
    . "${BATS_TEST_DIRNAME}/../lib/hooks.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "hooks_register appends demarcated block to service-event" {
    hooks_register
    grep -q "AmneziaWG-Addon-v2 BEGIN \[service-event\]" \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    grep -q "AmneziaWG-Addon-v2 END" \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    grep -q "user line" "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "hooks_register is idempotent — second call does not duplicate block" {
    hooks_register
    hooks_register
    [ "$(grep -c 'AmneziaWG-Addon-v2 BEGIN' "${AMNEZIAWG_JFFS_SCRIPTS}/service-event")" -eq 1 ]
}

@test "hooks_register creates hook file if missing" {
    rm -f "${AMNEZIAWG_JFFS_SCRIPTS}/wan-event"
    hooks_register
    [ -x "${AMNEZIAWG_JFFS_SCRIPTS}/wan-event" ]
    grep -q "AmneziaWG-Addon-v2 BEGIN" "${AMNEZIAWG_JFFS_SCRIPTS}/wan-event"
}

@test "hooks_register writes sha1 hash into marker" {
    hooks_register
    grep -qE 'AmneziaWG-Addon-v2 BEGIN \[service-event\] \(hash=[a-f0-9]{40}\)' \
         "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "hooks_register updates block when content hash changes" {
    hooks_register
    # Simulate stale block with different hash
    sed -i.bak 's/(hash=[a-f0-9]*)/(hash=0000000000000000000000000000000000000000)/' \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    rm -f "${AMNEZIAWG_JFFS_SCRIPTS}/service-event.bak"
    hooks_register
    # Old stale hash should be gone; new real hash present; still exactly one block
    ! grep -q 'hash=0000000000000000000000000000000000000000' \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    [ "$(grep -c 'AmneziaWG-Addon-v2 BEGIN' "${AMNEZIAWG_JFFS_SCRIPTS}/service-event")" -eq 1 ]
}

@test "hooks_unregister removes only the demarcated block, preserving user content" {
    hooks_register
    hooks_unregister
    ! grep -q 'AmneziaWG-Addon-v2' "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    grep -q "user line" "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "hooks_unregister is idempotent — second call is a no-op" {
    hooks_register
    hooks_unregister
    hooks_unregister
    grep -q "user line" "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "hooks_unregister does NOT delete lines that merely contain the string amneziawg" {
    hooks_register
    echo "# unrelated line about amneziawg that user wrote" \
        >> "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    hooks_unregister
    grep -q "unrelated line about amneziawg that user wrote" \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "hooks_register populates all four hook files" {
    hooks_register
    for h in service-event firewall-start wan-event services-start; do
        grep -q "AmneziaWG-Addon-v2 BEGIN" "${AMNEZIAWG_JFFS_SCRIPTS}/${h}"
    done
}
