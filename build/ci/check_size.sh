#!/bin/sh
# build/ci/check_size.sh — enforces .ipk size budgets.
#
# Caps:
#   amneziawg-go:            5 MiB
#   amneziawg-tools:        150 KiB (static-linked musl adds ~90KB)
#   amneziawg-merlin-addon:  200 KiB

set -eu

DIST_DIR="${1:-dist}"
fail=0

check_one() {
    _pkg="$1"; _cap_kb="$2"
    for _ipk in "${DIST_DIR}"/*/"${_pkg}"_*.ipk "${DIST_DIR}"/"${_pkg}"_*.ipk; do
        [ -f "${_ipk}" ] || continue
        _size_kb="$(du -k "${_ipk}" | awk '{print $1}')"
        if [ "${_size_kb}" -gt "${_cap_kb}" ]; then
            printf 'FAIL: %s is %s KB > cap %s KB\n' "${_ipk}" "${_size_kb}" "${_cap_kb}" >&2
            fail=1
        else
            printf 'OK:   %s is %s KB (cap %s KB)\n' "${_ipk}" "${_size_kb}" "${_cap_kb}"
        fi
    done
}

check_one amneziawg-go           5120
check_one amneziawg-tools        150
check_one amneziawg-merlin-addon 200

exit ${fail}
