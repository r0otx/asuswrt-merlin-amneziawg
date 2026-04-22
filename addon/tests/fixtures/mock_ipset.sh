#!/bin/sh
# mock_ipset.sh — stateful ipset/ipset-restore mock.
# State file: $TMPDIR_TEST/ipset-state (lines: "SETNAME MEMBER" and "SET:SETNAME TYPE").
#
# Supported:
#   ipset create NAME TYPE [opts]    # create set (-exist tolerant)
#   ipset destroy NAME               # drop set
#   ipset flush NAME                 # empty set
#   ipset add NAME MEMBER [-exist]   # add member
#   ipset del NAME MEMBER            # remove member
#   ipset list NAME                  # dump set content
#   ipset test NAME MEMBER           # exit 0/1
#   ipset restore [-!]               # batch from stdin (create/flush/add ops)
#   ipset -v                         # fake version string

mock_ipset_install() {
    [ -n "${TMPDIR_TEST}" ] || { echo "mock_ipset: TMPDIR_TEST must be set" >&2; return 1; }
    mkdir -p "${TMPDIR_TEST}/bin"

    cat > "${TMPDIR_TEST}/bin/ipset" <<'MOCK_EOF'
#!/bin/sh
: "${TMPDIR_TEST:?TMPDIR_TEST must be set}"
_state="${TMPDIR_TEST}/ipset-state"
touch "${_state}"

_op="$1"; shift || true
case "${_op}" in
    -v)
        echo "ipset v7.1 (mock)" ;;
    create)
        _name="$1"; _type="$2"
        grep -qE "^SET:${_name} " "${_state}" && exit 0
        printf 'SET:%s %s\n' "${_name}" "${_type}" >> "${_state}"
        ;;
    destroy)
        _name="$1"
        if [ -z "${_name}" ]; then
            : > "${_state}"
        else
            awk -v n="${_name}" '!($1 == "SET:"n || $1 == n)' "${_state}" > "${_state}.tmp" \
                && mv "${_state}.tmp" "${_state}"
        fi
        ;;
    flush)
        _name="$1"
        awk -v n="${_name}" '$1 != n' "${_state}" > "${_state}.tmp" \
            && mv "${_state}.tmp" "${_state}"
        ;;
    add)
        _name="$1"; _member="$2"
        # Tolerate -exist
        case "$3" in -exist) : ;; esac
        grep -qE "^${_name} ${_member}\$" "${_state}" && exit 0
        printf '%s %s\n' "${_name}" "${_member}" >> "${_state}"
        ;;
    del)
        _name="$1"; _member="$2"
        grep -vxF "${_name} ${_member}" "${_state}" > "${_state}.tmp" \
            && mv "${_state}.tmp" "${_state}"
        ;;
    list)
        _name="$1"
        if [ -z "${_name}" ]; then
            awk -F: '/^SET:/ { print $2 }' "${_state}" | awk '{print $1}'
        else
            grep -qE "^SET:${_name} " "${_state}" || { echo "The set ${_name} does not exist" >&2; exit 1; }
            echo "Name: ${_name}"
            echo "Members:"
            awk -v n="${_name}" '$1 == n { print $2 }' "${_state}"
        fi
        ;;
    test)
        _name="$1"; _member="$2"
        grep -qE "^${_name} ${_member}\$" "${_state}"
        exit $? ;;
    restore)
        # ipset restore [-!] — read batch commands from stdin
        while IFS= read -r _line; do
            [ -z "${_line}" ] && continue
            set -- ${_line}
            _rop="$1"; shift
            case "${_rop}" in
                create)
                    _rname="$1"
                    grep -qE "^SET:${_rname} " "${_state}" || printf 'SET:%s %s\n' "${_rname}" "$2" >> "${_state}"
                    ;;
                flush)
                    _rname="$1"
                    awk -v n="${_rname}" '$1 != n' "${_state}" > "${_state}.tmp" && mv "${_state}.tmp" "${_state}"
                    ;;
                add)
                    _rname="$1"; _rmember="$2"
                    grep -qE "^${_rname} ${_rmember}\$" "${_state}" || printf '%s %s\n' "${_rname}" "${_rmember}" >> "${_state}"
                    ;;
                destroy)
                    _rname="$1"
                    if [ -z "${_rname}" ]; then
                        : > "${_state}"
                    else
                        awk -v n="${_rname}" '!($1 == "SET:"n || $1 == n)' "${_state}" > "${_state}.tmp" \
                            && mv "${_state}.tmp" "${_state}"
                    fi
                    ;;
            esac
        done
        exit 0 ;;
    *)
        exit 0 ;;
esac
MOCK_EOF
    chmod +x "${TMPDIR_TEST}/bin/ipset"

    # ipset-restore: read lines from stdin, execute
    cat > "${TMPDIR_TEST}/bin/ipset-restore" <<'MOCK_EOF'
#!/bin/sh
: "${TMPDIR_TEST:?TMPDIR_TEST must be set}"
_state="${TMPDIR_TEST}/ipset-state"
touch "${_state}"
while IFS= read -r _line; do
    [ -z "${_line}" ] && continue
    set -- ${_line}
    _op="$1"; shift
    case "${_op}" in
        create)
            _name="$1"
            grep -qE "^SET:${_name} " "${_state}" || printf 'SET:%s %s\n' "${_name}" "$2" >> "${_state}"
            ;;
        flush)
            _name="$1"
            awk -v n="${_name}" '$1 != n' "${_state}" > "${_state}.tmp" && mv "${_state}.tmp" "${_state}"
            ;;
        add)
            _name="$1"; _member="$2"
            grep -qE "^${_name} ${_member}\$" "${_state}" || printf '%s %s\n' "${_name}" "${_member}" >> "${_state}"
            ;;
    esac
done
exit 0
MOCK_EOF
    chmod +x "${TMPDIR_TEST}/bin/ipset-restore"
}
