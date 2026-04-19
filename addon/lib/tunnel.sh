#!/bin/sh
# addon/lib/tunnel.sh — awg-quick wrapper + lifecycle verbs.
# Public API: tunnel_start, tunnel_stop, tunnel_restart, tunnel_reload, tunnel_is_up

if ! command -v log_info     >/dev/null 2>&1; then echo "tunnel.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v state_get    >/dev/null 2>&1; then echo "tunnel.sh: state.sh first"  >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v config_load  >/dev/null 2>&1; then echo "tunnel.sh: config.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_CONF:=/opt/etc/amneziawg/awg0.conf}"
: "${AMNEZIAWG_INTERFACE:=awg0}"
: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"

tunnel_is_up() {
    ip link show "${AMNEZIAWG_INTERFACE}" >/dev/null 2>&1 || return 1
    pidof -x amneziawg-go >/dev/null 2>&1 || return 1
    return 0
}

_tunnel_stock_wg_check() {
    _wgc="$(nvram get wgc_unit 2>/dev/null)"
    if [ -n "${_wgc}" ] && [ "${_wgc}" != "0" ]; then
        _en="$(nvram get "wgc${_wgc}_enable" 2>/dev/null)"
        if [ "${_en}" = "1" ]; then
            log_warn "stock Merlin WG client wgc${_wgc} is active — routing may conflict"
        fi
    fi
}

tunnel_start() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    if [ "$(state_get awg_enabled)" != "1" ]; then
        log_info "tunnel: disabled (awg_enabled=0), not starting"
        return 0
    fi
    _tunnel_stock_wg_check
    config_load
    if ! config_validate; then
        log_error "tunnel: refusing to start with invalid config"
        return 1
    fi
    config_emit "${AMNEZIAWG_CONF}"

    : > "${AMNEZIAWG_RUNTIME}/daemon.log"

    flock -x "${AMNEZIAWG_RUNTIME}/tunnel.lock" \
        -c "awg-quick up ${AMNEZIAWG_INTERFACE}" \
        >> "${AMNEZIAWG_RUNTIME}/daemon.log" 2>&1

    _i=1
    while [ "${_i}" -le 3 ]; do
        if tunnel_is_up; then
            log_info "tunnel: up"
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    log_error "tunnel: failed to come up after 3 retries"
    return 1
}

tunnel_stop() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    flock -x "${AMNEZIAWG_RUNTIME}/tunnel.lock" \
        -c "timeout 10 awg-quick down ${AMNEZIAWG_INTERFACE} 2>/dev/null || true" \
        >> "${AMNEZIAWG_RUNTIME}/daemon.log" 2>&1
    pkill -TERM -x amneziawg-go 2>/dev/null || true
    sleep 1
    pkill -KILL -x amneziawg-go 2>/dev/null || true
    ip link del "${AMNEZIAWG_INTERFACE}" 2>/dev/null || true
    log_info "tunnel: stopped"
}

tunnel_restart() {
    tunnel_stop
    tunnel_start
}

tunnel_reload() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    config_load
    if ! config_validate; then
        log_error "tunnel_reload: invalid config, aborting"
        return 1
    fi
    _candidate="${AMNEZIAWG_RUNTIME}/awg0.candidate.$$"
    config_emit "${_candidate}"

    if [ -f "${AMNEZIAWG_CONF}" ] && cmp -s "${_candidate}" "${AMNEZIAWG_CONF}"; then
        log_info "tunnel_reload: config unchanged, noop"
        rm -f "${_candidate}"
        return 0
    fi
    rm -f "${_candidate}"
    log_info "tunnel_reload: config changed, restarting"
    tunnel_restart
}
