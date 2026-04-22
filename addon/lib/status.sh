#!/bin/sh
# addon/lib/status.sh — JSON status producer.
# Public: status_emit_json (writes /tmp/amneziawg/status.json and mirrors to /www/user/awg_status.htm)

if ! command -v log_info    >/dev/null 2>&1; then echo "status.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v tunnel_is_up >/dev/null 2>&1; then echo "status.sh: tunnel.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"
: "${AMNEZIAWG_WWW_USER:=/www/user}"
: "${AMNEZIAWG_INTERFACE:=awg0}"

_status_stock_wg_conflict() {
    _wgc="$(nvram get wgc_unit 2>/dev/null)"
    [ -n "${_wgc}" ] && [ "${_wgc}" != "0" ] || { echo false; return; }
    _en="$(nvram get "wgc${_wgc}_enable" 2>/dev/null)"
    if [ "${_en}" = "1" ]; then echo true; else echo false; fi
}

status_emit_json() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    _ts="$(date +%s)"
    _state="stopped"
    _rx=0; _tx=0; _handshake_age=0
    _endpoint=""; _pubkey=""
    _enabled="false"
    _log_tail=""

    _leases_json="[]"
    : "${AMNEZIAWG_DNSMASQ_LEASES:=/var/lib/misc/dnsmasq.leases}"
    if [ -f "${AMNEZIAWG_DNSMASQ_LEASES}" ]; then
        _leases_json="$(awk '
            BEGIN { printf "[" }
            NR==1 { first=1 }
            NR<=50 {
                name = ($4 == "*" ? "" : $4)
                if (!first) printf ","
                printf "{\"mac\":\"%s\",\"ip\":\"%s\",\"name\":\"%s\"}", $2, $3, name
                first=0
            }
            END { printf "]" }
        ' "${AMNEZIAWG_DNSMASQ_LEASES}" 2>/dev/null)"
        [ -z "${_leases_json}" ] && _leases_json="[]"
    fi

    _killswitch_armed="false"
    [ -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ] && _killswitch_armed="true"

    # M5 geo status (last_sync + enabled cats)
    : "${AMNEZIAWG_GEO_ROOT:=/opt/etc/amneziawg/geo}"
    _geo_last=0
    if [ -f "${AMNEZIAWG_GEO_ROOT}/last-sync" ]; then
        _geo_last="$(cat "${AMNEZIAWG_GEO_ROOT}/last-sync" 2>/dev/null)"
        [ -z "${_geo_last}" ] && _geo_last=0
    fi
    _geo_enabled_csv=""
    _geo_curated="google youtube netflix telegram cloudflare github discord twitter meta tiktok cn ru by ua private tor"
    _geo_custom="$(state_get awg_geo_categories_custom 2>/dev/null | tr ',' ' ')"
    for _cat in ${_geo_curated} ${_geo_custom}; do
        [ -z "${_cat}" ] && continue
        _m="$(state_get "awg_geo_${_cat}_mode" 2>/dev/null)"
        if [ -n "${_m}" ] && [ "${_m}" != "off" ]; then
            if [ -z "${_geo_enabled_csv}" ]; then
                _geo_enabled_csv="\"${_cat}\""
            else
                _geo_enabled_csv="${_geo_enabled_csv},\"${_cat}\""
            fi
        fi
    done

    [ "$(state_get awg_enabled 2>/dev/null)" = "1" ] && _enabled="true"

    if tunnel_is_up; then
        _state="running"
        _dump="$(awg show "${AMNEZIAWG_INTERFACE}" dump 2>/dev/null)"
        if [ -n "${_dump}" ]; then
            _peer="$(printf '%s\n' "${_dump}" | sed -n '2p')"
            _pubkey="$(printf '%s' "${_peer}"   | cut -f1)"
            _endpoint="$(printf '%s' "${_peer}" | cut -f3)"
            _handshake_at="$(printf '%s' "${_peer}" | cut -f5)"
            _rx="$(printf '%s' "${_peer}" | cut -f6)"
            _tx="$(printf '%s' "${_peer}" | cut -f7)"
            if [ -n "${_handshake_at}" ] && [ "${_handshake_at}" -gt 0 ] 2>/dev/null; then
                _handshake_age=$((_ts - _handshake_at))
            fi
        fi
    fi

    _conflict="$(_status_stock_wg_conflict)"

    if [ -f "${AMNEZIAWG_RUNTIME}/daemon.log" ]; then
        _log_tail="$(tail -n 20 "${AMNEZIAWG_RUNTIME}/daemon.log" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g; s/\\/\\\\/g')"
    fi

    _tmp="${AMNEZIAWG_RUNTIME}/status.json.tmp.$$"
    {
        printf '{'
        printf '"version":"%s",'              "${AWG_VERSION:-0.0.0-dev}"
        printf '"timestamp":%s,'              "${_ts}"
        printf '"state":"%s",'                "${_state}"
        printf '"enabled":%s,'                "${_enabled}"
        printf '"interface":"%s",'            "${AMNEZIAWG_INTERFACE}"
        printf '"endpoint":"%s",'             "${_endpoint}"
        printf '"public_key":"%s",'           "${_pubkey}"
        printf '"rx_bytes":%s,'               "${_rx:-0}"
        printf '"tx_bytes":%s,'               "${_tx:-0}"
        printf '"handshake_age_seconds":%s,'  "${_handshake_age:-0}"
        printf '"stock_wg_conflict":%s,'      "${_conflict}"
        printf '"daemon_log_tail":"%s"'       "${_log_tail}"
        printf ',"leases":%s'                 "${_leases_json}"
        printf ',"killswitch_armed":%s'       "${_killswitch_armed}"
        printf ',"geo":{"last_sync":%s,"enabled":[%s]}' "${_geo_last}" "${_geo_enabled_csv}"
        printf '}\n'
    } > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_RUNTIME}/status.json"

    if [ -d "${AMNEZIAWG_WWW_USER}" ]; then
        cp "${AMNEZIAWG_RUNTIME}/status.json" "${AMNEZIAWG_WWW_USER}/awg_status.htm" 2>/dev/null \
            || log_warn "status: cannot mirror to ${AMNEZIAWG_WWW_USER}/awg_status.htm"
    fi
}
