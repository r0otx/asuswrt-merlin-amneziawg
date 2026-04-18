#!/bin/sh
# addon/lib/hooks.sh — register/unregister demarcated AmneziaWG blocks in
# Merlin user-scripts (service-event, firewall-start, wan-event, services-start).
#
# Format of a block:
#
#   #### AmneziaWG-Addon-v2 BEGIN [<hook>] (hash=<sha1>) ####
#   <content from addon/hooks/<hook>.block>
#   #### AmneziaWG-Addon-v2 END ####
#
# hash is sha1sum of the content, allowing idempotent detection of updates.

: "${AMNEZIAWG_JFFS_SCRIPTS:=/jffs/scripts}"
: "${AMNEZIAWG_ADDON_DIR:=/jffs/addons/amneziawg}"

_MARK_BEGIN_PREFIX="#### AmneziaWG-Addon-v2 BEGIN"
_MARK_END="#### AmneziaWG-Addon-v2 END ####"

_HOOKS_LIST="service-event firewall-start wan-event services-start"

_hooks_content_hash() {
    _block_file="$1"
    sha1sum "${_block_file}" | awk '{print $1}'
}

_hooks_render_block() {
    _hook="$1"
    _block_file="${AMNEZIAWG_ADDON_DIR}/hooks/${_hook}.block"
    _hash="$(_hooks_content_hash "${_block_file}")"
    printf '%s [%s] (hash=%s) ####\n' "${_MARK_BEGIN_PREFIX}" "${_hook}" "${_hash}"
    cat "${_block_file}"
    printf '%s\n' "${_MARK_END}"
}

_hooks_strip_existing_block() {
    # Remove any existing AmneziaWG-Addon-v2 block from a file (in place).
    # Preserves executable bit across the mv.
    _file="$1"
    _tmp="${_file}.tmp.$$"
    _was_exec=0
    [ -x "${_file}" ] && _was_exec=1
    awk -v begin="${_MARK_BEGIN_PREFIX}" -v endm="${_MARK_END}" '
        index($0, begin) == 1 { skip=1; next }
        skip && index($0, endm) == 1 { skip=0; next }
        !skip { print }
    ' "${_file}" > "${_tmp}"
    mv "${_tmp}" "${_file}"
    [ "${_was_exec}" -eq 1 ] && chmod 755 "${_file}"
}

_hooks_ensure_file() {
    _file="$1"
    if [ ! -f "${_file}" ]; then
        mkdir -p "$(dirname "${_file}")"
        printf '#!/bin/sh\n' > "${_file}"
        chmod 755 "${_file}"
    elif ! head -1 "${_file}" | grep -q '^#!'; then
        # File exists but lacks shebang — prepend one
        _tmp="${_file}.tmp.$$"
        { printf '#!/bin/sh\n'; cat "${_file}"; } > "${_tmp}"
        mv "${_tmp}" "${_file}"
        chmod 755 "${_file}"
    fi
}

hooks_register() {
    for _hook in ${_HOOKS_LIST}; do
        _file="${AMNEZIAWG_JFFS_SCRIPTS}/${_hook}"
        _hooks_ensure_file "${_file}"
        _hooks_strip_existing_block "${_file}"
        _hooks_render_block "${_hook}" >> "${_file}"
    done
    log_info "hooks registered"
}

hooks_unregister() {
    for _hook in ${_HOOKS_LIST}; do
        _file="${AMNEZIAWG_JFFS_SCRIPTS}/${_hook}"
        if [ -f "${_file}" ]; then
            _hooks_strip_existing_block "${_file}"
        fi
    done
    log_info "hooks unregistered"
}
