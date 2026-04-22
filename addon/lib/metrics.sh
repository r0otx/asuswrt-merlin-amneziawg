#!/bin/sh
# addon/lib/metrics.sh — per-minute tunnel metrics with a JSONL ring buffer.
# Public:
#   metrics_sample       # snapshot + append one sample (called from watchdog_tick)
#   metrics_ring_trim    # keep only last ${AMNEZIAWG_METRICS_WINDOW} lines
#   metrics_get_json     # stdout: current ring as a JSON array
#   metrics_clear        # remove ring + /www/user mirror

if ! command -v log_info >/dev/null 2>&1; then
    echo "metrics.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

: "${AMNEZIAWG_METRICS_FILE:=/tmp/amneziawg/metrics.jsonl}"
: "${AMNEZIAWG_METRICS_WINDOW:=1440}"
: "${AMNEZIAWG_WWW_USER:=/www/user}"
: "${AMNEZIAWG_INTERFACE:=awg0}"

metrics_get_json() {
    if [ ! -s "${AMNEZIAWG_METRICS_FILE}" ]; then
        printf '[]\n'
        return 0
    fi
    awk 'BEGIN { printf "[" }
         NR > 1 { printf "," }
         { printf "%s", $0 }
         END { printf "]\n" }' "${AMNEZIAWG_METRICS_FILE}"
}

metrics_clear() {
    rm -f "${AMNEZIAWG_METRICS_FILE}" \
          "${AMNEZIAWG_WWW_USER}/awg_metrics.htm" 2>/dev/null || true
}

metrics_ring_trim() {
    [ -s "${AMNEZIAWG_METRICS_FILE}" ] || return 0
    _n="$(wc -l < "${AMNEZIAWG_METRICS_FILE}" 2>/dev/null)"
    [ -n "${_n}" ] || return 0
    if [ "${_n}" -gt "${AMNEZIAWG_METRICS_WINDOW}" ] 2>/dev/null; then
        _tmp="${AMNEZIAWG_METRICS_FILE}.trim.$$"
        tail -n "${AMNEZIAWG_METRICS_WINDOW}" "${AMNEZIAWG_METRICS_FILE}" > "${_tmp}" \
            && mv -f "${_tmp}" "${AMNEZIAWG_METRICS_FILE}"
    fi
}

metrics_sample() {
    _ts=$(date +%s)

    # RX/TX counters from `awg show <iface> transfer`
    _dump="$(awg show "${AMNEZIAWG_INTERFACE}" transfer 2>/dev/null || true)"
    _rx="$(printf '%s' "${_dump}" | awk 'NR==1{print $1+0}')"
    _tx="$(printf '%s' "${_dump}" | awk 'NR==1{print $2+0}')"
    [ -z "${_rx}" ] && _rx=0
    [ -z "${_tx}" ] && _tx=0

    # Handshake timestamp from `awg show <iface> latest-handshakes`
    _hs_at="$(awg show "${AMNEZIAWG_INTERFACE}" latest-handshakes 2>/dev/null \
              | awk 'NR==1{print $2+0}')"
    [ -z "${_hs_at}" ] && _hs_at=0
    if [ "${_hs_at}" -gt 0 ] 2>/dev/null; then
        _hs=$(( _ts - _hs_at ))
        [ "${_hs}" -lt 0 ] && _hs=0
    else
        _hs=0
    fi

    # Link up?
    if ip link show "${AMNEZIAWG_INTERFACE}" 2>/dev/null \
         | grep -qE 'state (UP|UNKNOWN)'; then
        _up=1
    else
        _up=0
    fi

    # Rate vs last sample (if any)
    _rx_bps=0
    _tx_bps=0
    if [ -s "${AMNEZIAWG_METRICS_FILE}" ]; then
        _prev="$(tail -n 1 "${AMNEZIAWG_METRICS_FILE}")"
        _prev_ts="$(printf '%s' "${_prev}"  | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')"
        _prev_rx="$(printf '%s' "${_prev}"  | sed -n 's/.*"rx":\([0-9]*\).*/\1/p')"
        _prev_tx="$(printf '%s' "${_prev}"  | sed -n 's/.*"tx":\([0-9]*\).*/\1/p')"
        [ -z "${_prev_ts}" ] && _prev_ts=0
        [ -z "${_prev_rx}" ] && _prev_rx=0
        [ -z "${_prev_tx}" ] && _prev_tx=0
        _delta=$(( _ts - _prev_ts ))
        if [ "${_delta}" -gt 0 ] && [ "${_rx}" -ge "${_prev_rx}" ] 2>/dev/null; then
            _rx_bps=$(( (_rx - _prev_rx) * 8 / _delta ))
        fi
        if [ "${_delta}" -gt 0 ] && [ "${_tx}" -ge "${_prev_tx}" ] 2>/dev/null; then
            _tx_bps=$(( (_tx - _prev_tx) * 8 / _delta ))
        fi
    fi

    mkdir -p "$(dirname "${AMNEZIAWG_METRICS_FILE}")"
    printf '{"ts":%s,"rx":%s,"tx":%s,"rx_bps":%s,"tx_bps":%s,"hs":%s,"up":%s}\n' \
           "${_ts}" "${_rx}" "${_tx}" "${_rx_bps}" "${_tx_bps}" "${_hs}" "${_up}" \
           >> "${AMNEZIAWG_METRICS_FILE}" \
        || { log_warn "metrics: write to ${AMNEZIAWG_METRICS_FILE} failed"; return 1; }

    metrics_ring_trim

    # Atomic mirror for WebUI
    if [ -d "${AMNEZIAWG_WWW_USER}" ]; then
        _mirror_tmp="${AMNEZIAWG_WWW_USER}/awg_metrics.htm.tmp.$$"
        cp "${AMNEZIAWG_METRICS_FILE}" "${_mirror_tmp}" 2>/dev/null \
            && mv -f "${_mirror_tmp}" "${AMNEZIAWG_WWW_USER}/awg_metrics.htm"
    fi
    return 0
}
