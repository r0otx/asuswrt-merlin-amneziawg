#!/bin/sh
# mock_iptables.sh — stateful iptables/iptables-restore/ip6tables mock.
# Source from bats setup(); provides mocks that maintain chain state in
# $TMPDIR_TEST/iptables-state.<table> and $TMPDIR_TEST/ip6tables-state.<table>.
#
# Supported:
#   iptables [-t TABLE] -N CHAIN         # create chain (idempotent)
#   iptables [-t TABLE] -X CHAIN         # delete chain
#   iptables [-t TABLE] -F CHAIN         # flush chain
#   iptables [-t TABLE] -A CHAIN ARGS... # append rule
#   iptables [-t TABLE] -I CHAIN [pos] ARGS...  # insert rule
#   iptables [-t TABLE] -D CHAIN ARGS... # delete rule (by match)
#   iptables [-t TABLE] -C CHAIN ARGS... # check rule (exit 0/1)
#   iptables [-t TABLE] -S [CHAIN]       # dump rules
#   iptables-restore [--noflush] [-t T]  # batch apply from stdin
#
# Default table is `filter` when -t omitted. ip6tables mirrors iptables but
# writes to ip6tables-state.*.
#
# Note: grep -F calls use -- to prevent patterns starting with '-' (e.g. rule
# lines like "-A CHAIN ...") from being parsed as grep flags. This is POSIX
# and identical on busybox grep.

mock_iptables_install() {
    [ -n "${TMPDIR_TEST}" ] || { echo "mock_iptables: TMPDIR_TEST must be set" >&2; return 1; }
    mkdir -p "${TMPDIR_TEST}/bin"

    cat > "${TMPDIR_TEST}/bin/iptables" <<'MOCK_EOF'
#!/bin/sh
# Stateful iptables mock. State files: $TMPDIR_TEST/iptables-state.<table>
: "${TMPDIR_TEST:?TMPDIR_TEST must be set}"
_table=filter
# Parse leading -t TABLE
while [ $# -gt 0 ]; do
    case "$1" in
        -t) shift; _table="$1"; shift ;;
        *) break ;;
    esac
done
_state="${TMPDIR_TEST}/iptables-state.${_table}"
touch "${_state}"
_op="$1"; shift || true
case "${_op}" in
    -N)
        _chain="$1"
        grep -qE "^:${_chain} " "${_state}" || printf ':%s -\n' "${_chain}" >> "${_state}"
        exit 0 ;;
    -X)
        _chain="$1"
        # Remove chain header + any rules
        awk -v c="${_chain}" '$0 !~ "^:"c" " && $0 !~ "^-A "c" " && $0 !~ "^-A "c"$"' \
            "${_state}" > "${_state}.tmp" && mv "${_state}.tmp" "${_state}"
        exit 0 ;;
    -F)
        _chain="$1"
        awk -v c="${_chain}" '$0 !~ "^-A "c" " && $0 !~ "^-A "c"$"' \
            "${_state}" > "${_state}.tmp" && mv "${_state}.tmp" "${_state}"
        exit 0 ;;
    -A)
        _chain="$1"; shift
        printf '%s\n' "-A ${_chain} $*" >> "${_state}"
        exit 0 ;;
    -I)
        _chain="$1"; shift
        # Ignore optional position arg for simplicity (always prepend)
        case "$1" in ''|*[!0-9]*) : ;; *) shift ;; esac
        _rule="-A ${_chain} $*"
        { printf '%s\n' "${_rule}"; cat "${_state}"; } > "${_state}.tmp" && mv "${_state}.tmp" "${_state}"
        exit 0 ;;
    -D)
        _chain="$1"; shift
        _needle="-A ${_chain} $*"
        grep -vxF -- "${_needle}" "${_state}" > "${_state}.tmp"; mv "${_state}.tmp" "${_state}"
        exit 0 ;;
    -C)
        _chain="$1"; shift
        _needle="-A ${_chain} $*"
        grep -qxF -- "${_needle}" "${_state}"
        exit $? ;;
    -S|-L)
        if [ -n "$1" ]; then
            _chain="$1"
            grep -E "^(:|-A )${_chain}( |\$)" "${_state}" 2>/dev/null || true
        else
            cat "${_state}" 2>/dev/null || true
        fi
        exit 0 ;;
    *)
        # Unrecognized: log and succeed
        printf 'mock iptables unknown op: %s %s\n' "${_op}" "$*" >&2
        exit 0 ;;
esac
MOCK_EOF
    chmod +x "${TMPDIR_TEST}/bin/iptables"

    # ip6tables: identical logic, different state file prefix
    cat > "${TMPDIR_TEST}/bin/ip6tables" <<'MOCK_EOF'
#!/bin/sh
: "${TMPDIR_TEST:?TMPDIR_TEST must be set}"
_table=filter
while [ $# -gt 0 ]; do
    case "$1" in
        -t) shift; _table="$1"; shift ;;
        -P) shift; shift; exit 0 ;;
        *) break ;;
    esac
done
_state="${TMPDIR_TEST}/ip6tables-state.${_table}"
touch "${_state}"
_op="$1"; shift || true
case "${_op}" in
    -N) grep -qE "^:$1 " "${_state}" || printf ':%s -\n' "$1" >> "${_state}"; exit 0 ;;
    -I) _chain="$1"; shift; case "$1" in ''|*[!0-9]*) : ;; *) shift ;; esac
        { printf '%s\n' "-A ${_chain} $*"; cat "${_state}"; } > "${_state}.tmp" && mv "${_state}.tmp" "${_state}"; exit 0 ;;
    -A) _chain="$1"; shift; printf '%s\n' "-A ${_chain} $*" >> "${_state}"; exit 0 ;;
    -D) _chain="$1"; shift; grep -vxF -- "-A ${_chain} $*" "${_state}" > "${_state}.tmp"; mv "${_state}.tmp" "${_state}"; exit 0 ;;
    -S|-L) [ -n "$1" ] && grep -E "^(:|-A )$1( |\$)" "${_state}" || cat "${_state}"; exit 0 ;;
    -F) _chain="$1"; awk -v c="${_chain}" '$0 !~ "^-A "c" " && $0 !~ "^-A "c"$"' "${_state}" > "${_state}.tmp" && mv "${_state}.tmp" "${_state}"; exit 0 ;;
    *) exit 0 ;;
esac
MOCK_EOF
    chmod +x "${TMPDIR_TEST}/bin/ip6tables"

    # iptables-restore: read from stdin, apply line by line to the right state file
    cat > "${TMPDIR_TEST}/bin/iptables-restore" <<'MOCK_EOF'
#!/bin/sh
: "${TMPDIR_TEST:?TMPDIR_TEST must be set}"
_noflush=0
_restrict_table=""
while [ $# -gt 0 ]; do
    case "$1" in
        --noflush|-n) _noflush=1; shift ;;
        -T|-t) shift; _restrict_table="$1"; shift ;;
        *) shift ;;
    esac
done

_table=""
while IFS= read -r _line; do
    case "${_line}" in
        \**)
            _table="${_line#\*}"
            _state="${TMPDIR_TEST}/iptables-state.${_table}"
            touch "${_state}"
            if [ -n "${_restrict_table}" ] && [ "${_table}" != "${_restrict_table}" ]; then
                _state=""
            fi
            if [ "${_noflush}" -eq 0 ] && [ -n "${_state}" ]; then
                : > "${_state}"
            fi
            ;;
        :*)
            [ -n "${_state}" ] || continue
            _chain="${_line%% *}"
            _chain="${_chain#:}"
            grep -qE "^:${_chain} " "${_state}" || printf '%s\n' "${_line}" >> "${_state}"
            ;;
        -A*)
            [ -n "${_state}" ] || continue
            printf '%s\n' "${_line}" >> "${_state}"
            ;;
        COMMIT)
            _state=""
            ;;
        *)
            : ;;
    esac
done
exit 0
MOCK_EOF
    chmod +x "${TMPDIR_TEST}/bin/iptables-restore"
}
