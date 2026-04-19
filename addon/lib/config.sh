#!/bin/sh
# addon/lib/config.sh — parse, validate, emit awg0.conf.
#
# Schema: custom_settings.txt v2 keys prefixed `awg_`. See spec §4.1.
# Public API:
#   config_load                    — read awg_* keys into _cfg_<key> vars
#   config_validate                — validate loaded vars, logs errors
#   config_emit <path>             — atomic tmp+mv write of awg0.conf
#   config_import_from_stdin       — parse .conf, validate, persist
#   config_export                  — emit current custom_settings as .conf
#
# All private functions prefixed `_config_`.

# Guard: requires log.sh and state.sh sourced first.
if ! command -v log_info >/dev/null 2>&1; then
    echo "config.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v state_get >/dev/null 2>&1; then
    echo "config.sh: state.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

# ------------------------------ scalar validators ------------------------------

_config_validate_key() {
    # 44-char base64 (32-byte key + `=` padding).
    _val="$1"
    [ -n "${_val}" ] || return 1
    [ "${#_val}" -eq 44 ] || return 1
    # Base64 alphabet: A-Z a-z 0-9 + / and trailing =
    printf '%s' "${_val}" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || return 1
    return 0
}

_config_validate_addr() {
    # IPv4/prefix (IPv6 support: v2.x).
    _val="$1"
    printf '%s' "${_val}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || return 1
    _ip="${_val%/*}"
    _prefix="${_val##*/}"
    _i=1
    for _octet in $(printf '%s\n' "${_ip}" | tr '.' ' '); do
        [ "${_octet}" -ge 0 ] 2>/dev/null && [ "${_octet}" -le 255 ] || return 1
        _i=$((_i + 1))
    done
    [ "${_prefix}" -ge 0 ] 2>/dev/null && [ "${_prefix}" -le 32 ] || return 1
    return 0
}

_config_validate_endpoint() {
    # host:port where host is DNS name or IP, port is 1..65535.
    _val="$1"
    case "${_val}" in
        *:*) ;;
        *) return 1 ;;
    esac
    _host="${_val%:*}"
    _port="${_val##*:}"
    [ -n "${_host}" ] || return 1
    [ "${_port}" -ge 1 ] 2>/dev/null && [ "${_port}" -le 65535 ] || return 1
    return 0
}

_config_validate_cidr_list() {
    # Comma-separated CIDRs (IPv4 or IPv6).
    _val="$1"
    [ -n "${_val}" ] || return 1
    _IFS_save="${IFS}"
    IFS=','
    for _entry in ${_val}; do
        case "${_entry}" in
            *:*/*)
                # IPv6: must contain at least one `:` in host part.
                printf '%s' "${_entry}" | grep -Eq '^[0-9A-Fa-f:]+/[0-9]+$' || {
                    IFS="${_IFS_save}"
                    return 1
                }
                ;;
            *.*.*.*/*)
                printf '%s' "${_entry}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || {
                    IFS="${_IFS_save}"
                    return 1
                }
                ;;
            *)
                IFS="${_IFS_save}"
                return 1
                ;;
        esac
    done
    IFS="${_IFS_save}"
    return 0
}

_config_validate_int_range() {
    _val="$1"; _min="$2"; _max="$3"
    printf '%s' "${_val}" | grep -Eq '^[0-9]+$' || return 1
    [ "${_val}" -ge "${_min}" ] && [ "${_val}" -le "${_max}" ] || return 1
    return 0
}
