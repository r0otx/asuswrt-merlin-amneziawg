#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_ADDON_DIR="${TMPDIR_TEST}/addon_mock"
    mkdir -p "${AMNEZIAWG_ADDON_DIR}/webui"

    # Mock /www/user/ and /www/require/modules/menuTree.js
    export AMNEZIAWG_WWW_USER="${TMPDIR_TEST}/www_user"
    export AMNEZIAWG_MENU_TREE_SRC="${TMPDIR_TEST}/menuTree.js.src"
    export AMNEZIAWG_MENU_TREE_TMP="${TMPDIR_TEST}/menuTree.js.tmp"
    export AMNEZIAWG_ADDONWEBUI_LOCK="${TMPDIR_TEST}/addonwebui.lock"
    mkdir -p "${AMNEZIAWG_WWW_USER}"
    for i in 1 2 3 4; do : > "${AMNEZIAWG_WWW_USER}/user${i}.asp"; done
    cat > "${AMNEZIAWG_MENU_TREE_SRC}" <<'EOF'
menuList = [
  {url: "index.asp", tabName: "Home"},
  {url: "Advanced_VPN_OpenVPN.asp", tabName: "OpenVPN"},
  {url: "Advanced_Tor.asp", tabName: "Tor"}
];
EOF

    # Mock am_get_webui_page — returns user5.asp (simulated allocated slot)
    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    cat > "${TMPDIR_TEST}/bin/am_get_webui_page" <<'EOF'
#!/bin/sh
# Mock: always return user5.asp and "export" the env var the real one sets.
printf 'user5.asp\n'
EOF
    chmod +x "${TMPDIR_TEST}/bin/am_get_webui_page"

    # Mock flock (no-op wrapper that honors both calling conventions:
    #   flock -x <fd>         — lock already-open FD, no command to exec
    #   flock -x -- cmd args  — lock then exec the wrapped command
    # Also: `flock <file> -c 'cmd'` — lock-and-run (not used here but handled)
    cat > "${TMPDIR_TEST}/bin/flock" <<'EOF'
#!/bin/sh
# Strip leading short flags (e.g. -x, -s, -u, -n)
while [ $# -gt 0 ] && [ "$1" != "--" ] && [ "${1#-}" != "$1" ]; do shift; done
[ "$1" = "--" ] && shift
# If the (now-first) positional is all digits, it is a FD — no command to exec.
case "${1:-}" in
  ''|*[!0-9]*) : ;;   # not all digits: fall through and exec below
  *) exit 0 ;;         # all digits = FD-lock mode, no-op for tests
esac
if [ $# -gt 0 ]; then exec "$@"; fi
EOF
    chmod +x "${TMPDIR_TEST}/bin/flock"

    # Mock mount / umount (record calls)
    export AMNEZIAWG_MOUNT_LOG="${TMPDIR_TEST}/mount.log"
    cat > "${TMPDIR_TEST}/bin/mount" <<EOF
#!/bin/sh
printf 'mount %s\n' "\$*" >> "${AMNEZIAWG_MOUNT_LOG}"
EOF
    chmod +x "${TMPDIR_TEST}/bin/mount"
    cat > "${TMPDIR_TEST}/bin/umount" <<EOF
#!/bin/sh
printf 'umount %s\n' "\$*" >> "${AMNEZIAWG_MOUNT_LOG}"
EOF
    chmod +x "${TMPDIR_TEST}/bin/umount"

    # Load libs
    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/ui.sh"

    # Create a fake webui .asp inside the isolated mock dir (not the repo!)
    echo '<html><!-- v2 --></html>' > "${AMNEZIAWG_ADDON_DIR}/webui/amneziawg_page.asp"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "ui_mount copies webui page into allocated slot" {
    ui_mount
    grep -q '<!-- v2 -->' "${AMNEZIAWG_WWW_USER}/user5.asp"
}

@test "ui_mount creates /tmp/menuTree.js patched copy" {
    ui_mount
    [ -f "${AMNEZIAWG_MENU_TREE_TMP}" ]
    grep -q '"AmneziaWG"' "${AMNEZIAWG_MENU_TREE_TMP}"
    grep -q 'user5.asp' "${AMNEZIAWG_MENU_TREE_TMP}"
}

@test "ui_mount issues bind-mount of patched menuTree" {
    ui_mount
    grep -q "mount -o bind ${AMNEZIAWG_MENU_TREE_TMP} ${AMNEZIAWG_MENU_TREE_SRC}" \
         "${AMNEZIAWG_MOUNT_LOG}"
}

@test "ui_mount is idempotent — second call keeps single menu entry" {
    ui_mount
    ui_mount
    [ "$(grep -c '"AmneziaWG"' "${AMNEZIAWG_MENU_TREE_TMP}")" -eq 1 ]
}

@test "ui_unmount removes the .asp copy from the slot" {
    ui_mount
    ui_unmount
    [ ! -s "${AMNEZIAWG_WWW_USER}/user5.asp" ]
}

@test "ui_unmount issues umount of menuTree bind" {
    ui_mount
    ui_unmount
    grep -q "umount ${AMNEZIAWG_MENU_TREE_SRC}" "${AMNEZIAWG_MOUNT_LOG}"
}

@test "ui_unmount removes menu entry from patched menuTree" {
    ui_mount
    ui_unmount
    ! grep -q '"AmneziaWG"' "${AMNEZIAWG_MENU_TREE_TMP}" 2>/dev/null || true
}
