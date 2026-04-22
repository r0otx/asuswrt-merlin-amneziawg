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

# Implemented in Task 2
metrics_ring_trim() { log_warn "metrics_ring_trim: not implemented (Task 2)"; return 1; }
# Implemented in Task 3
metrics_sample() { log_warn "metrics_sample: not implemented (Task 3)"; return 1; }
