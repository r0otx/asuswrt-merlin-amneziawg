#!/bin/sh
# addon/lib/log.sh — structured logging helpers.
#
# Emits INFO/WARN/ERROR/DEBUG lines to either:
#   - syslog via `logger -t "$AMNEZIAWG_LOG_TAG"` (production)
#   - AMNEZIAWG_LOG_FILE (tests)
#
# DEBUG lines are suppressed unless AMNEZIAWG_LOG_LEVEL=debug.
# Functions never fail the caller: all return 0 (logging must not break control flow).

: "${AMNEZIAWG_LOG_TAG:=amneziawg}"
: "${AMNEZIAWG_LOG_LEVEL:=info}"

_log_emit() {
    # $1 = level string (5 chars, padded), $2 = message
    _level="$1"; shift
    _msg="$*"
    _line="${_level} ${_msg}"
    if [ -n "${AMNEZIAWG_LOG_FILE:-}" ]; then
        printf '%s\n' "${_line}" >> "${AMNEZIAWG_LOG_FILE}"
    else
        logger -t "${AMNEZIAWG_LOG_TAG}" -- "${_line}" 2>/dev/null || true
    fi
    return 0
}

log_info()  { _log_emit "INFO " "$*"; }
log_warn()  { _log_emit "WARN " "$*"; }
log_error() { _log_emit "ERROR" "$*"; }

log_debug() {
    case "${AMNEZIAWG_LOG_LEVEL}" in
        debug|verbose) _log_emit "DEBUG" "$*" ;;
        *) : ;;
    esac
    return 0
}
