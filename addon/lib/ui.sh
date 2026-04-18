#!/bin/sh
# addon/lib/ui.sh — mount and unmount the AmneziaWG page in the Merlin WebUI.
#
# Uses:
#   am_get_webui_page     — official helper to allocate /www/user/userN.asp slot
#   flock FD 386          — coordinates with other addons patching menuTree.js
#   bind-mount            — overlays patched menuTree.js onto read-only squashfs

: "${AMNEZIAWG_WWW_USER:=/www/user}"
: "${AMNEZIAWG_MENU_TREE_SRC:=/www/require/modules/menuTree.js}"
: "${AMNEZIAWG_MENU_TREE_TMP:=/tmp/menuTree.js}"
: "${AMNEZIAWG_ADDONWEBUI_LOCK:=/tmp/addonwebui.lock}"
: "${AMNEZIAWG_ADDON_DIR:=/jffs/addons/amneziawg}"

_UI_MENU_ANCHOR='{url: "Advanced_VPN_OpenVPN.asp", tabName: "OpenVPN"},'
_UI_MENU_INSERT_REGEX='Advanced_VPN_OpenVPN.asp'

_ui_slot_file() {
    # Returns the filename (userN.asp) assigned to AmneziaWG; uses
    # am_get_webui_page on a live Merlin, falls back to mock output in tests.
    am_get_webui_page "${AMNEZIAWG_ADDON_DIR}/webui/amneziawg_page.asp"
}

_ui_copy_page() {
    _slot="$1"
    cp "${AMNEZIAWG_ADDON_DIR}/webui/amneziawg_page.asp" \
       "${AMNEZIAWG_WWW_USER}/${_slot}"
    # Also copy sibling assets if present
    for _asset in amneziawg.js amneziawg.css; do
        if [ -f "${AMNEZIAWG_ADDON_DIR}/webui/${_asset}" ]; then
            cp "${AMNEZIAWG_ADDON_DIR}/webui/${_asset}" \
               "${AMNEZIAWG_WWW_USER}/${_asset}"
        fi
    done
}

_ui_prepare_menutree() {
    if [ ! -f "${AMNEZIAWG_MENU_TREE_TMP}" ]; then
        cp "${AMNEZIAWG_MENU_TREE_SRC}" "${AMNEZIAWG_MENU_TREE_TMP}"
    fi
}

_ui_patch_menutree() {
    _slot="$1"
    _ui_prepare_menutree
    # Remove any existing AmneziaWG menu entry first (idempotence)
    _tmp="${AMNEZIAWG_MENU_TREE_TMP}.new.$$"
    awk '!/"AmneziaWG"/' "${AMNEZIAWG_MENU_TREE_TMP}" > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_MENU_TREE_TMP}"
    # Insert new entry after the OpenVPN anchor line
    awk -v slot="${_slot}" -v anchor="${_UI_MENU_INSERT_REGEX}" '
        { print }
        $0 ~ anchor && !done {
            printf "{url: \"%s\", tabName: \"AmneziaWG\"},\n", slot
            done=1
        }
    ' "${AMNEZIAWG_MENU_TREE_TMP}" > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_MENU_TREE_TMP}"
}

_ui_bind_mount() {
    umount "${AMNEZIAWG_MENU_TREE_SRC}" 2>/dev/null || true
    mount -o bind "${AMNEZIAWG_MENU_TREE_TMP}" "${AMNEZIAWG_MENU_TREE_SRC}"
}

_ui_with_lock() {
    # Run the function $1 under flock FD 386 on $AMNEZIAWG_ADDONWEBUI_LOCK.
    _fn="$1"; shift
    (
        # Under flock on FD 386 (Merlin addonwebui convention — coordinates
        # concurrent menuTree.js patches from other addons). POSIX sh does
        # not guarantee FDs above 9, but busybox ash / dash / bash all accept.
        # shellcheck disable=SC3023
        exec 386>"${AMNEZIAWG_ADDONWEBUI_LOCK}"
        flock -x 386
        "${_fn}" "$@"
    )
}

_ui_do_mount() {
    _slot="$(_ui_slot_file)"
    [ -n "${_slot}" ] || { log_error "failed to allocate webui slot"; return 1; }
    _ui_copy_page "${_slot}"
    _ui_patch_menutree "${_slot}"
    _ui_bind_mount
    log_info "webui mounted at ${_slot}"
}

_ui_do_unmount() {
    umount "${AMNEZIAWG_MENU_TREE_SRC}" 2>/dev/null || true
    if [ -f "${AMNEZIAWG_MENU_TREE_TMP}" ]; then
        _tmp="${AMNEZIAWG_MENU_TREE_TMP}.new.$$"
        awk '!/"AmneziaWG"/' "${AMNEZIAWG_MENU_TREE_TMP}" > "${_tmp}"
        mv "${_tmp}" "${AMNEZIAWG_MENU_TREE_TMP}"
    fi
    # Clear the slot file (cannot remove — it was registered by am_get_webui_page)
    if [ -n "${AMNEZIAWG_WWW_USER}" ]; then
        _slot_guess="$(_ui_slot_file)"
        if [ -n "${_slot_guess}" ] && [ -f "${AMNEZIAWG_WWW_USER}/${_slot_guess}" ]; then
            : > "${AMNEZIAWG_WWW_USER}/${_slot_guess}"
        fi
    fi
    log_info "webui unmounted"
}

ui_mount()   { _ui_with_lock _ui_do_mount; }
ui_unmount() { _ui_with_lock _ui_do_unmount; }
