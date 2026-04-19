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

_config_validate_h_value() {
    # AmneziaWG 2.0: single int or range "N-M" with M>=N.
    _val="$1"
    [ -n "${_val}" ] || return 1
    case "${_val}" in
        *-*)
            _lo="${_val%-*}"
            _hi="${_val#*-}"
            printf '%s' "${_lo}" | grep -Eq '^[0-9]+$' || return 1
            printf '%s' "${_hi}" | grep -Eq '^[0-9]+$' || return 1
            [ "${_lo}" -le "${_hi}" ] || return 1
            ;;
        *)
            printf '%s' "${_val}" | grep -Eq '^[0-9]+$' || return 1
            ;;
    esac
    return 0
}

_config_validate_i_sequence() {
    # AmneziaWG 2.0 tagged signature packet value.
    # Empty string OK — means "field absent".
    _val="$1"
    [ -z "${_val}" ] && return 0
    # Consume tags from left. Each iteration strips one valid tag.
    _rest="${_val}"
    while [ -n "${_rest}" ]; do
        case "${_rest}" in
            "<t>"*)
                _rest="${_rest#<t>}"
                ;;
            "<b 0x"*">"*)
                # <b 0x[even-length-hex]>
                _tag="${_rest%%>*}>"
                _hex="${_tag#<b 0x}"
                _hex="${_hex%>}"
                # Even-length hex
                _hexlen=${#_hex}
                [ "$((_hexlen % 2))" -eq 0 ] || return 1
                printf '%s' "${_hex}" | grep -Eq '^[0-9a-fA-F]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            "<r "*">"*)
                _tag="${_rest%%>*}>"
                _size="${_tag#<r }"
                _size="${_size%>}"
                printf '%s' "${_size}" | grep -Eq '^[0-9]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            "<rd "*">"*)
                _tag="${_rest%%>*}>"
                _size="${_tag#<rd }"
                _size="${_size%>}"
                printf '%s' "${_size}" | grep -Eq '^[0-9]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            "<rc "*">"*)
                _tag="${_rest%%>*}>"
                _size="${_tag#<rc }"
                _size="${_size%>}"
                printf '%s' "${_size}" | grep -Eq '^[0-9]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            *)
                return 1
                ;;
        esac
    done
    return 0
}

# ------------------------------ config_load ------------------------------

# List of all known awg_* keys. Kept in sync with spec §4.1.
_CFG_KEYS="
    enabled
    privatekey
    address
    dns
    mtu
    jc
    jmin
    jmax
    s1 s2 s3 s4
    h1 h2 h3 h4
    i1 i2 i3 i4 i5
    peer_publickey
    peer_presharedkey
    peer_endpoint
    peer_allowed_ips
    peer_keepalive
"

config_load() {
    for _key in ${_CFG_KEYS}; do
        _val="$(state_get "awg_${_key}")"
        eval "_cfg_${_key}=\"\${_val}\""
    done
}

# ------------------------------ config_validate ------------------------------

_config_err() { log_error "config: $*"; _config_bad=1; }

config_validate() {
    _config_bad=0

    # enabled: 0 or 1 (default 0)
    case "${_cfg_enabled:-0}" in
        0|1) ;;
        *) _config_err "enabled must be 0 or 1" ;;
    esac

    # Required: privatekey, address, peer_publickey, peer_endpoint, peer_allowed_ips
    if ! _config_validate_key "${_cfg_privatekey}"; then
        _config_err "privatekey invalid (must be 44-char base64)"
    fi
    if ! _config_validate_addr "${_cfg_address}"; then
        _config_err "address invalid (must be IP/prefix, e.g. 10.8.0.2/24)"
    fi
    if ! _config_validate_key "${_cfg_peer_publickey}"; then
        _config_err "peer_publickey invalid"
    fi
    if ! _config_validate_endpoint "${_cfg_peer_endpoint}"; then
        _config_err "peer_endpoint invalid (must be host:port)"
    fi
    if ! _config_validate_cidr_list "${_cfg_peer_allowed_ips}"; then
        _config_err "peer_allowed_ips invalid (CIDR list required)"
    fi

    # Optional: presharedkey
    if [ -n "${_cfg_peer_presharedkey}" ]; then
        _config_validate_key "${_cfg_peer_presharedkey}" \
            || _config_err "peer_presharedkey invalid"
    fi

    # Optional: dns (comma-separated IPs)
    if [ -n "${_cfg_dns}" ]; then
        _IFS_save="${IFS}"; IFS=','
        for _ip in ${_cfg_dns}; do
            printf '%s' "${_ip}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                || _config_err "dns entry '${_ip}' invalid"
        done
        IFS="${_IFS_save}"
    fi

    # MTU: default 1280, range 576..1500
    _mtu="${_cfg_mtu:-1280}"
    if ! _config_validate_int_range "${_mtu}" 576 1500; then
        _config_err "mtu invalid (range 576..1500, got '${_mtu}')"
    fi

    # Jc: 1..128
    _config_validate_int_range "${_cfg_jc:-0}" 1 128 \
        || _config_err "jc invalid (range 1..128)"
    _config_validate_int_range "${_cfg_jmin:-0}" 0 1500 \
        || _config_err "jmin invalid"
    _config_validate_int_range "${_cfg_jmax:-0}" 0 1500 \
        || _config_err "jmax invalid"
    if [ "${_cfg_jmax:-0}" -lt "${_cfg_jmin:-0}" ] 2>/dev/null; then
        _config_err "jmax (${_cfg_jmax}) must be >= jmin (${_cfg_jmin})"
    fi

    # S1..S4: optional, 0..1500 each
    for _s in s1 s2 s3 s4; do
        eval "_val=\"\${_cfg_${_s}}\""
        [ -z "${_val}" ] && continue
        _config_validate_int_range "${_val}" 0 1500 \
            || _config_err "${_s} invalid"
    done

    # H1..H4: required, range syntax
    for _h in h1 h2 h3 h4; do
        eval "_val=\"\${_cfg_${_h}}\""
        _config_validate_h_value "${_val}" \
            || _config_err "${_h} invalid (int or int-int, got '${_val}')"
    done

    # I1..I5: optional, tagged syntax
    for _i in i1 i2 i3 i4 i5; do
        eval "_val=\"\${_cfg_${_i}}\""
        _config_validate_i_sequence "${_val}" \
            || _config_err "${_i} invalid tagged sequence"
    done

    # peer_keepalive: optional, 0..65535
    if [ -n "${_cfg_peer_keepalive}" ]; then
        _config_validate_int_range "${_cfg_peer_keepalive}" 0 65535 \
            || _config_err "peer_keepalive invalid"
    fi

    [ "${_config_bad}" -eq 0 ]
}
