#!/bin/sh
# addon/lib/state.sh — Merlin custom_settings.txt access + v1 migration stubs.
#
# Uses atomic write (tmp + mv) to avoid partial reads from concurrent webui polls.
# custom_settings.txt format: one line per entry, space-separated "key value".

: "${AMNEZIAWG_CUSTOM_SETTINGS:=/jffs/addons/custom_settings.txt}"

# Ensure log_* helpers are available (fatal if missing — state should never be used
# before log).
if ! command -v log_info >/dev/null 2>&1; then
    echo "state.sh: log.sh must be sourced before state.sh" >&2
    return 1 2>/dev/null || exit 1
fi

_state_ensure_file() {
    if [ ! -f "${AMNEZIAWG_CUSTOM_SETTINGS}" ]; then
        mkdir -p "$(dirname "${AMNEZIAWG_CUSTOM_SETTINGS}")"
        : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    fi
}

state_get() {
    _key="$1"
    _state_ensure_file
    awk -v k="${_key}" '$1 == k { $1=""; sub(/^ /, ""); print; exit }' \
        "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

state_set() {
    _key="$1"; _value="$2"
    _state_ensure_file
    _tmp="${AMNEZIAWG_CUSTOM_SETTINGS}.tmp.$$"
    awk -v k="${_key}" -v v="${_value}" '
        $1 == k { next }
        { print }
        END { printf "%s %s\n", k, v }
    ' "${AMNEZIAWG_CUSTOM_SETTINGS}" > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

state_delete() {
    _key="$1"
    _state_ensure_file
    _tmp="${AMNEZIAWG_CUSTOM_SETTINGS}.tmp.$$"
    awk -v k="${_key}" '$1 == k { next } { print }' \
        "${AMNEZIAWG_CUSTOM_SETTINGS}" > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

state_list_awg_keys() {
    _state_ensure_file
    awk '/^awg_/ { print $1 }' "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

# --- v1 migration (real logic: Module 2) ------------------------------------
migrate_from_v1() {
    log_warn "migrate_from_v1 is stubbed in Module 1 — real logic in Module 2"
    return 0
}

backup_before_remove() {
    log_warn "backup_before_remove is stubbed in Module 1 — real logic in Module 2"
    return 0
}
