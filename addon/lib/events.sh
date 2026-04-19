#!/bin/sh
# addon/lib/events.sh — hook dispatchers for Merlin user-scripts.
# Public: event_service, event_wan, event_firewall, event_services_start

if ! command -v log_info       >/dev/null 2>&1; then echo "events.sh: log.sh first"      >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v tunnel_start   >/dev/null 2>&1; then echo "events.sh: tunnel.sh first"   >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"

_EVENTS_WAN_DEBOUNCE_SEC=5

event_service() {
    _event="$1"; _target="$2"
    case "${_event},${_target}" in
        start,awgstart|restart,awgstart)    tunnel_start ;;
        start,awgstop)                      tunnel_stop ;;
        start,awgrestart)                   tunnel_restart ;;
        start,awgsaveconf)                  tunnel_reload ;;
        *) log_debug "event_service: ignoring ${_event}/${_target}" ;;
    esac
}

event_wan() {
    _unit="$1"; _type="$2"
    [ "${_unit}" = "0" ] || return 0
    case "${_type}" in
        connected|disconnected|stopped) ;;
        *) return 0 ;;
    esac

    mkdir -p "${AMNEZIAWG_RUNTIME}"
    _now="$(date +%s)"
    _last="$(cat "${AMNEZIAWG_RUNTIME}/last-wan-action" 2>/dev/null || echo 0)"
    if [ "$((_now - _last))" -lt "${_EVENTS_WAN_DEBOUNCE_SEC}" ]; then
        log_debug "event_wan: debounced (${_type})"
        return 0
    fi
    printf '%s\n' "${_now}" > "${AMNEZIAWG_RUNTIME}/last-wan-action"

    case "${_type}" in
        connected)
            if [ "$(state_get awg_enabled)" = "1" ]; then
                tunnel_restart
            fi
            ;;
        disconnected|stopped)
            tunnel_stop
            ;;
    esac
    # Re-stamp after action so the debounce window starts from completion, not from dispatch.
    printf '%s\n' "$(date +%s)" > "${AMNEZIAWG_RUNTIME}/last-wan-action"
}

event_firewall() {
    _wan_if="$1"
    log_debug "event_firewall: ${_wan_if} (stub — M3 will setup PBR here)"
}

event_services_start() {
    if command -v ui_mount >/dev/null 2>&1; then
        ui_mount || log_warn "event_services_start: ui_mount failed (non-fatal)"
    fi
    cru a amneziawg_watchdog "* * * * * /jffs/addons/amneziawg/amneziawg.sh watchdog"
    if [ "$(state_get awg_enabled)" = "1" ]; then
        _i=1
        while [ "${_i}" -le 3 ]; do
            if tunnel_start; then
                break
            fi
            log_warn "event_services_start: tunnel_start retry ${_i}/3 (likely DNS not ready)"
            sleep 10
            _i=$((_i + 1))
        done
    fi
}
