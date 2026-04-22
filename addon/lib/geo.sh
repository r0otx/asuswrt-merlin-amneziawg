#!/bin/sh
# addon/lib/geo.sh — v2fly GeoIP/GeoSite auto-population.
# Public:
#   geo_sync [--force]       # full fetch + apply (Task 10)
#   geo_list [<cat>]         # list IP+domain entries (Task 11)
#   geo_categories           # print curated + custom enabled names (Task 11)
#   geo_status               # emit JSON status (Task 11)
#   geo_clear [<cat>|--all]  # remove cached files + flush ipsets (Task 11)
#   geo_cron_install         # register awggeosync cron via cru (Task 12)
#   geo_cron_remove          # deregister (Task 12)
# Helpers (this task):
#   geo_sources_load         # load sources.env
#   geo_lock_acquire         # PID-based lock
#   geo_lock_release
#   geo_enabled_categories   # enumerate enabled categories from state
#   geo_category_mode        # read mode for one category (default off)

if ! command -v log_info >/dev/null 2>&1; then
    echo "geo.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v state_get >/dev/null 2>&1; then
    echo "geo.sh: state.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v geo_filter_domain >/dev/null 2>&1; then
    echo "geo.sh: geo_parse.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"
: "${AMNEZIAWG_GEO_ROOT:=/opt/etc/amneziawg/geo}"
: "${AMNEZIAWG_GEO_LOCK:=/tmp/amneziawg/geo.lock}"
: "${AMNEZIAWG_GEO_CRON_ID:=awggeosync}"
: "${AMNEZIAWG_GEO_CRON_CMD:=/jffs/addons/amneziawg/amneziawg.sh geo sync}"

GEO_CURATED="google youtube netflix telegram cloudflare github discord twitter meta tiktok cn ru by ua private tor"
GEO_IPSET_VPN="awg_geo_dst"
GEO_IPSET_DIRECT="awg_geo_direct"

# -------- sources.env --------------------------------------------------

geo_sources_load() {
    V2FLY_GEOIP_URL_BASE="https://raw.githubusercontent.com/v2fly/geoip/release/text"
    V2FLY_DOMAIN_URL_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
    FETCH_TIMEOUT=60
    FETCH_RETRIES=2
    if [ -f "${AMNEZIAWG_GEO_ROOT}/sources.env" ]; then
        # shellcheck disable=SC1091
        . "${AMNEZIAWG_GEO_ROOT}/sources.env"
    fi
}

# -------- PID lock ------------------------------------------------------

geo_lock_acquire() {
    mkdir -p "$(dirname "${AMNEZIAWG_GEO_LOCK}")"
    if [ -f "${AMNEZIAWG_GEO_LOCK}" ]; then
        _old_pid="$(cat "${AMNEZIAWG_GEO_LOCK}" 2>/dev/null)"
        if [ -n "${_old_pid}" ] && kill -0 "${_old_pid}" 2>/dev/null; then
            log_info "geo: another sync holds lock (pid=${_old_pid})"
            return 1
        fi
        log_warn "geo: stale lock (pid=${_old_pid}) — reclaiming"
        rm -f "${AMNEZIAWG_GEO_LOCK}"
    fi
    echo "$$" > "${AMNEZIAWG_GEO_LOCK}"
    return 0
}

geo_lock_release() {
    rm -f "${AMNEZIAWG_GEO_LOCK}"
}

# -------- Enumeration ---------------------------------------------------

geo_enabled_categories() {
    _out=""
    _custom="$(state_get awg_geo_categories_custom | tr ',' ' ')"
    for _cat in ${GEO_CURATED} ${_custom}; do
        [ -z "${_cat}" ] && continue
        _mode="$(state_get "awg_geo_${_cat}_mode")"
        [ -n "${_mode}" ] && [ "${_mode}" != "off" ] && _out="${_out} ${_cat}"
    done
    printf '%s' "${_out}" | sed 's/^ //'
}

geo_category_mode() {
    _cat="$1"
    _m="$(state_get "awg_geo_${_cat}_mode")"
    [ -z "${_m}" ] && _m="off"
    printf '%s' "${_m}"
}

# -------- Fetch one category into a staging dir ------------------------

_geo_fetch_category() {
    # Args: <category> <staging_root>
    # Preconditions: geo_sources_load has been called.
    # Effect: writes <staging>/ip/<cat>.txt, <staging>/domain/<cat>.txt,
    #         <staging>/dnsmasq.d/<cat>.conf. Returns non-zero on failure.
    _cat="$1"; _stg="$2"
    _mode="$(geo_category_mode "${_cat}")"
    if [ "${_mode}" = "off" ]; then
        log_warn "geo: _geo_fetch_category called for off category ${_cat}"
        return 1
    fi
    if [ "${_mode}" = "direct" ]; then
        _set="${GEO_IPSET_DIRECT}"
    else
        _set="${GEO_IPSET_VPN}"
    fi

    _ip_url="${V2FLY_GEOIP_URL_BASE}/${_cat}.txt"
    _dom_url="${V2FLY_DOMAIN_URL_BASE}/${_cat}"
    _ip_out="${_stg}/ip/${_cat}.txt"
    _dom_raw="${_stg}/domain/${_cat}.raw"
    _dom_out="${_stg}/domain/${_cat}.txt"
    _conf_out="${_stg}/dnsmasq.d/${_cat}.conf"

    # IP list (required)
    if ! curl --proto '=https' -fsSL --max-time "${FETCH_TIMEOUT:-60}" --retry "${FETCH_RETRIES:-2}" \
            -o "${_ip_out}" "${_ip_url}"; then
        log_warn "geo: fetch ip failed for ${_cat} (${_ip_url})"
        return 1
    fi

    # Domain list (optional: some categories are IP-only)
    if curl --proto '=https' -fsSL --max-time "${FETCH_TIMEOUT:-60}" --retry "${FETCH_RETRIES:-2}" \
            -o "${_dom_raw}" "${_dom_url}" 2>/dev/null; then
        _src_dir="$(dirname "${_dom_raw}")"
        # Copy raw to a name that matches include: target resolution convention
        cp "${_dom_raw}" "${_src_dir}/${_cat}"
        geo_filter_domain < "${_src_dir}/${_cat}" | \
            geo_resolve_includes "${_src_dir}" 3 "${_cat}" > "${_dom_out}"
        rm -f "${_dom_raw}" "${_src_dir}/${_cat}"
    else
        : > "${_dom_out}"
    fi

    # dnsmasq.d/<cat>.conf — one `ipset=/<domain>/<set>` per domain
    : > "${_conf_out}"
    if [ -s "${_dom_out}" ]; then
        while IFS= read -r _dom; do
            [ -n "${_dom}" ] || continue
            printf 'ipset=/%s/%s\n' "${_dom}" "${_set}" >> "${_conf_out}"
        done < "${_dom_out}"
    fi
    return 0
}

# -------- Stubs filled in later tasks (sync/list/clear/status/cron) -----
geo_sync()         { log_warn "geo_sync: not implemented (Task 10)"; return 1; }
geo_list()         { log_warn "geo_list: not implemented (Task 11)"; return 1; }
geo_categories()   { log_warn "geo_categories: not implemented (Task 11)"; return 1; }
geo_status()       { log_warn "geo_status: not implemented (Task 11)"; return 1; }
geo_clear()        { log_warn "geo_clear: not implemented (Task 11)"; return 1; }
geo_cron_install() { log_warn "geo_cron_install: not implemented (Task 12)"; return 1; }
geo_cron_remove()  { log_warn "geo_cron_remove: not implemented (Task 12)"; return 1; }
