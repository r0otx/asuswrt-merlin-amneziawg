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

# -------- geo_sync: full orchestration ----------------------------------

geo_sync() {
    _force=0
    if [ "$1" = "--force" ]; then _force=1; fi

    if ! geo_lock_acquire; then
        return 0
    fi

    geo_sources_load

    _enabled="$(geo_enabled_categories)"
    if [ -z "${_enabled}" ]; then
        log_info "geo_sync: no enabled categories, clearing caches"
        _geo_cleanup_disabled ""
        _geo_dnsmasq_reload_if_changed "${_force}"
        _geo_ipsets_rebuild
        date +%s > "${AMNEZIAWG_GEO_ROOT}/last-sync"
        geo_lock_release
        return 0
    fi

    _parallel="$(state_get awg_geo_sync_parallel)"
    [ -z "${_parallel}" ] && _parallel=3
    case "${_parallel}" in 1|2|3|4|5|6|7|8) : ;; *) _parallel=3 ;; esac

    _stg="${TMPDIR:-/tmp}/amneziawg-geo-staging.$$"
    rm -rf "${_stg}"
    mkdir -p "${_stg}/ip" "${_stg}/domain" "${_stg}/dnsmasq.d"
    # shellcheck disable=SC2064
    trap "geo_lock_release; rm -rf \"${_stg}\"" EXIT INT TERM
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" \
             "${AMNEZIAWG_GEO_ROOT}/domain" \
             "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d"
    : > "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log.tmp"

    # Parallel semaphore: cap concurrent background fetches at _parallel
    _running=0
    for _cat in ${_enabled}; do
        while [ "${_running}" -ge "${_parallel}" ]; do
            wait
            _running=0
        done
        (
            if ! _geo_fetch_category "${_cat}" "${_stg}"; then
                printf '%s %s\n' "$(date +%s)" "${_cat}" \
                    >> "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log.tmp"
            fi
        ) &
        _running=$(( _running + 1 ))
    done
    wait

    # Move successful categories into live root (atomic per-file)
    for _cat in ${_enabled}; do
        if [ -s "${_stg}/ip/${_cat}.txt" ]; then
            mv -f "${_stg}/ip/${_cat}.txt"         "${AMNEZIAWG_GEO_ROOT}/ip/${_cat}.txt"
            mv -f "${_stg}/domain/${_cat}.txt"     "${AMNEZIAWG_GEO_ROOT}/domain/${_cat}.txt"     2>/dev/null || true
            mv -f "${_stg}/dnsmasq.d/${_cat}.conf" "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/${_cat}.conf" 2>/dev/null || true
        fi
    done

    _geo_cleanup_disabled "${_enabled}"
    _geo_dnsmasq_reload_if_changed "${_force}"
    _geo_ipsets_rebuild

    mv -f "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log.tmp" \
          "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log"
    date +%s > "${AMNEZIAWG_GEO_ROOT}/last-sync"
    rm -rf "${_stg}"

    geo_lock_release
    trap - EXIT INT TERM
    return 0
}

_geo_cleanup_disabled() {
    _keep="$1"
    for _f in "${AMNEZIAWG_GEO_ROOT}/ip/"*.txt; do
        [ -e "${_f}" ] || continue
        _cat="$(basename "${_f}" .txt)"
        case " ${_keep} " in
            *" ${_cat} "*) ;;
            *)
                rm -f "${AMNEZIAWG_GEO_ROOT}/ip/${_cat}.txt"
                rm -f "${AMNEZIAWG_GEO_ROOT}/domain/${_cat}.txt"
                rm -f "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/${_cat}.conf"
                ;;
        esac
    done
}

_geo_dnsmasq_reload_if_changed() {
    _force="$1"
    _hash_file="${AMNEZIAWG_GEO_ROOT}/.dnsmasq-hash"
    _new_hash="$(cat "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/"*.conf 2>/dev/null | sha1sum | awk '{print $1}')"
    _old_hash=""
    [ -f "${_hash_file}" ] && _old_hash="$(cat "${_hash_file}")"
    if [ "${_force}" = "1" ] || [ "${_new_hash}" != "${_old_hash}" ]; then
        printf '%s\n' "${_new_hash}" > "${_hash_file}"
        if command -v service >/dev/null 2>&1; then
            service restart_dnsmasq >/dev/null 2>&1 || true
        fi
    fi
}

_geo_ipsets_rebuild() {
    # Destroy and recreate both geo ipsets, populate from ip/*.txt + manual lists.
    { printf 'destroy %s\n' "${GEO_IPSET_VPN}"
      printf 'destroy %s\n' "${GEO_IPSET_DIRECT}"
    } | ipset restore -! 2>/dev/null || true

    _tmp="$(mktemp)"
    {
        printf 'create %s hash:net family inet maxelem 65536 -exist\n' "${GEO_IPSET_VPN}"
        printf 'create %s hash:net family inet maxelem 65536 -exist\n' "${GEO_IPSET_DIRECT}"
        printf 'flush %s\n' "${GEO_IPSET_VPN}"
        printf 'flush %s\n' "${GEO_IPSET_DIRECT}"

        # Per-category IPs → route by mode
        for _f in "${AMNEZIAWG_GEO_ROOT}/ip/"*.txt; do
            [ -s "${_f}" ] || continue
            _cat="$(basename "${_f}" .txt)"
            _m="$(geo_category_mode "${_cat}")"
            [ "${_m}" = "off" ] && continue
            _set="${GEO_IPSET_VPN}"
            [ "${_m}" = "direct" ] && _set="${GEO_IPSET_DIRECT}"
            while IFS= read -r _cidr; do
                [ -n "${_cidr}" ] || continue
                case "${_cidr}" in '#'*) continue ;; esac
                printf 'add %s %s -exist\n' "${_set}" "${_cidr}"
            done < "${_f}"
        done

        # Manual entries
        _man_vpn="$(state_get awg_geo_entries)"
        _IFS_save="${IFS}"; IFS=','
        for _c in ${_man_vpn}; do
            _c="$(printf '%s' "${_c}" | tr -d ' ')"
            [ -n "${_c}" ] && printf 'add %s %s -exist\n' "${GEO_IPSET_VPN}" "${_c}"
        done
        _man_dir="$(state_get awg_geo_entries_direct)"
        for _c in ${_man_dir}; do
            _c="$(printf '%s' "${_c}" | tr -d ' ')"
            [ -n "${_c}" ] && printf 'add %s %s -exist\n' "${GEO_IPSET_DIRECT}" "${_c}"
        done
        IFS="${_IFS_save}"
    } > "${_tmp}"

    ipset restore -! < "${_tmp}"
    rm -f "${_tmp}"
}

# -------- geo_categories / geo_list / geo_status / geo_clear -----------

geo_categories() {
    for _cat in ${GEO_CURATED}; do
        printf '%s\n' "${_cat}"
    done
    _custom="$(state_get awg_geo_categories_custom | tr ',' ' ')"
    for _cat in ${_custom}; do
        [ -n "${_cat}" ] && printf '%s\n' "${_cat}"
    done
}

geo_list() {
    _cat="$1"
    if [ -z "${_cat}" ]; then
        geo_enabled_categories | tr ' ' '\n'
        return 0
    fi
    _ip_file="${AMNEZIAWG_GEO_ROOT}/ip/${_cat}.txt"
    _dom_file="${AMNEZIAWG_GEO_ROOT}/domain/${_cat}.txt"
    [ -s "${_ip_file}" ]  && cat "${_ip_file}"
    [ -s "${_dom_file}" ] && cat "${_dom_file}"
    return 0
}

geo_status() {
    _ls=0
    if [ -f "${AMNEZIAWG_GEO_ROOT}/last-sync" ]; then
        _ls="$(cat "${AMNEZIAWG_GEO_ROOT}/last-sync" 2>/dev/null)"
        [ -z "${_ls}" ] && _ls=0
    fi
    _enabled_csv=""
    for _cat in $(geo_enabled_categories); do
        if [ -z "${_enabled_csv}" ]; then
            _enabled_csv="\"${_cat}\""
        else
            _enabled_csv="${_enabled_csv},\"${_cat}\""
        fi
    done
    _errs_csv=""
    if [ -f "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log" ]; then
        while IFS=' ' read -r _ts _c; do
            [ -n "${_c}" ] || continue
            if [ -z "${_errs_csv}" ]; then
                _errs_csv="\"${_c}\""
            else
                _errs_csv="${_errs_csv},\"${_c}\""
            fi
        done < "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log"
    fi
    printf '{"last_sync":%s,"enabled":[%s],"errors":[%s]}\n' \
        "${_ls}" "${_enabled_csv}" "${_errs_csv}"
}

geo_clear() {
    _target="$1"
    if [ -z "${_target}" ]; then
        log_warn "geo_clear: argument required (--all or <category>)"
        return 1
    fi
    if [ "${_target}" = "--all" ]; then
        rm -f "${AMNEZIAWG_GEO_ROOT}/ip/"*.txt          2>/dev/null || true
        rm -f "${AMNEZIAWG_GEO_ROOT}/domain/"*.txt      2>/dev/null || true
        rm -f "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/"*.conf  2>/dev/null || true
        rm -f "${AMNEZIAWG_GEO_ROOT}/last-sync" \
              "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log" \
              "${AMNEZIAWG_GEO_ROOT}/.dnsmasq-hash" 2>/dev/null || true
        {
            printf 'flush %s\n' "${GEO_IPSET_VPN}"
            printf 'flush %s\n' "${GEO_IPSET_DIRECT}"
        } | ipset restore -! 2>/dev/null || true
    else
        rm -f "${AMNEZIAWG_GEO_ROOT}/ip/${_target}.txt" \
              "${AMNEZIAWG_GEO_ROOT}/domain/${_target}.txt" \
              "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/${_target}.conf"
    fi
    return 0
}

# -------- Stubs for Task 12 (cron) --------------------------------------
geo_cron_install() { log_warn "geo_cron_install: not implemented (Task 12)"; return 1; }
geo_cron_remove()  { log_warn "geo_cron_remove: not implemented (Task 12)"; return 1; }
