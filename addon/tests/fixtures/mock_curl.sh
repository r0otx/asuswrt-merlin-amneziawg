#!/bin/sh
# Mock curl for bats tests.
# Behaviour:
#   - Parse -o <out> and the final URL argument.
#   - If MOCK_CURL_FAIL_URLS matches the URL (POSIX ERE), exit with MOCK_CURL_FAIL_RC (default 22).
#   - Otherwise find fixture by URL suffix under MOCK_CURL_FIXTURES_DIR and copy to <out>.
#   - Log every invocation to MOCK_CURL_LOG ($TMPDIR_TEST/curl.log if unset).

: "${MOCK_CURL_FIXTURES_DIR:?mock_curl: set MOCK_CURL_FIXTURES_DIR}"
: "${MOCK_CURL_LOG:=${TMPDIR_TEST:-/tmp}/curl.log}"
: "${MOCK_CURL_FAIL_RC:=22}"

_out=""
_url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) _out="$2"; shift 2 ;;
        --output) _out="$2"; shift 2 ;;
        -fsSL|-fsS|-s|-L|-S|-f) shift ;;
        --proto|--max-time|--retry|--connect-timeout|-w) shift 2 ;;
        http*) _url="$1"; shift ;;
        *) shift ;;
    esac
done

printf '%s %s\n' "$(date +%s)" "${_url}" >> "${MOCK_CURL_LOG}"

if [ -n "${MOCK_CURL_FAIL_URLS}" ]; then
    if printf '%s\n' "${_url}" | grep -Eq "${MOCK_CURL_FAIL_URLS}"; then
        exit "${MOCK_CURL_FAIL_RC}"
    fi
fi

# Map URL → fixture path.
# Expected URL shape:
#   https://raw.githubusercontent.com/v2fly/geoip/release/text/<cat>.txt
#   https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/<cat>
_fixture=""
case "${_url}" in
    *v2fly/geoip/*/text/*.txt)
        _cat_file="${_url##*/}"
        _fixture="${MOCK_CURL_FIXTURES_DIR}/ip/${_cat_file}"
        ;;
    *v2fly/domain-list-community/*/data/*)
        _cat="${_url##*/}"
        _fixture="${MOCK_CURL_FIXTURES_DIR}/domain/${_cat}"
        ;;
esac

if [ -z "${_fixture}" ] || [ ! -f "${_fixture}" ]; then
    # Simulate HTTP 404 → curl exits 22 with --fail
    exit 22
fi

if [ -n "${_out}" ]; then
    cp "${_fixture}" "${_out}"
else
    cat "${_fixture}"
fi
exit 0
