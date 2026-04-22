#!/bin/sh
# addon/lib/watchdog.sh — periodic health check.
# Public: watchdog_tick (called every 60s from cru cron).

if ! command -v log_info        >/dev/null 2>&1; then echo "watchdog.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v tunnel_is_up    >/dev/null 2>&1; then echo "watchdog.sh: tunnel.sh first" >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v status_emit_json >/dev/null 2>&1; then echo "watchdog.sh: status.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"
: "${AMNEZIAWG_INTERFACE:=awg0}"

_HANDSHAKE_STALE_THRESHOLD=180
_OVERLAP_GUARD_SECONDS=30
_RESTART_WINDOW_SECONDS=600
_RESTART_WINDOW_MAX=3

_wd_read_state() {
    _last_tick=0
    _restart_win_start=0
    _restart_count=0
    if [ -f "${AMNEZIAWG_RUNTIME}/watchdog-state" ]; then
        while IFS='=' read -r _k _v; do
            case "${_k}" in
                last_tick)         _last_tick="${_v}" ;;
                restart_win_start) _restart_win_start="${_v}" ;;
                restart_count)     _restart_count="${_v}" ;;
            esac
        done < "${AMNEZIAWG_RUNTIME}/watchdog-state"
    fi
}

_wd_write_state() {
    _tmp="${AMNEZIAWG_RUNTIME}/watchdog-state.tmp.$$"
    {
        printf 'last_tick=%s\n'         "${_last_tick}"
        printf 'restart_win_start=%s\n' "${_restart_win_start}"
        printf 'restart_count=%s\n'     "${_restart_count}"
    } > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_RUNTIME}/watchdog-state"
}

_wd_try_restart_allowed() {
    _now="$1"
    if [ "$((_now - _restart_win_start))" -gt "${_RESTART_WINDOW_SECONDS}" ]; then
        _restart_win_start="${_now}"
        _restart_count=1
        return 0
    fi
    if [ "${_restart_count}" -ge "${_RESTART_WINDOW_MAX}" ]; then
        return 1
    fi
    _restart_count=$((_restart_count + 1))
    return 0
}

watchdog_tick() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    _now="$(date +%s)"
    _wd_read_state

    if [ "$((_now - _last_tick))" -lt "${_OVERLAP_GUARD_SECONDS}" ]; then
        log_debug "watchdog: overlap guard, skip"
        return 0
    fi
    _last_tick="${_now}"
    _wd_write_state

    if [ "$(state_get awg_enabled)" != "1" ]; then
        status_emit_json
        return 0
    fi

    if tunnel_is_up; then
        # If we had armed kill-switch before, disarm now
        if [ -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ] && \
           command -v pbr_kill_switch_disarm >/dev/null 2>&1; then
            pbr_kill_switch_disarm
        fi

        _dump="$(awg show "${AMNEZIAWG_INTERFACE}" dump 2>/dev/null)"
        _handshake_at="$(printf '%s\n' "${_dump}" | sed -n '2p' | cut -f5)"
        if [ -z "${_handshake_at}" ] || [ "${_handshake_at}" -eq 0 ] 2>/dev/null; then
            _handshake_age=0
        else
            _handshake_age=$((_now - _handshake_at))
        fi
        if [ "${_handshake_age}" -gt "${_HANDSHAKE_STALE_THRESHOLD}" ]; then
            if _wd_try_restart_allowed "${_now}"; then
                log_warn "watchdog: stale handshake (${_handshake_age}s), restarting"
                tunnel_restart
            else
                log_warn "watchdog: rate-limited, skip restart (count=${_restart_count})"
            fi
            _wd_write_state
        fi
    else
        # Tunnel down — arm kill-switch if not yet
        if command -v pbr_kill_switch_arm >/dev/null 2>&1; then
            pbr_kill_switch_arm
        fi
        if _wd_try_restart_allowed "${_now}"; then
            log_warn "watchdog: tunnel down despite enabled, starting"
            tunnel_start
        else
            log_warn "watchdog: rate-limited, skip start"
        fi
        _wd_write_state
    fi

    status_emit_json
    if command -v metrics_sample >/dev/null 2>&1; then
        metrics_sample || log_warn "watchdog: metrics_sample failed"
    fi
}
