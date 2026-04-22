#!/bin/sh
# addon/lib/pbr.sh — policy-based routing.
# Public:
#   pbr_setup                           # full apply from state
#   pbr_teardown                        # remove all PBR artifacts
#   pbr_load_devices                    # dump devices as TSV to stdout: N<TAB>ip<TAB>mac<TAB>name<TAB>policy
#   pbr_apply                           # re-emit rules from current state
#   pbr_reapply_incremental             # diff-aware apply (hash compare)
#   pbr_kill_switch_arm                 # DROPs for fwmark + vpn devices
#   pbr_kill_switch_disarm              # flush AMNEZIAWG_KILL
#   pbr_geo_add <cidr>
#   pbr_geo_remove <cidr>
#   pbr_geo_clear
#   pbr_geo_apply                       # push awg_geo_entries into ipset (hash:net)
#   pbr_geo_direct_add <cidr>
#   pbr_geo_direct_remove <cidr>
#   pbr_geo_direct_clear
#   pbr_geo_direct_apply                # push awg_geo_entries_direct into ipset (hash:net)
#   pbr_default_set <policy>
#   pbr_device_set <ip> <policy> [name] [mac]
#   pbr_device_remove <ip>

if ! command -v log_info     >/dev/null 2>&1; then echo "pbr.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v chain_ensure >/dev/null 2>&1; then echo "pbr.sh: iptables_chain.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"
: "${AMNEZIAWG_DNSMASQ_LEASES:=/var/lib/misc/dnsmasq.leases}"

_PBR_FWMARK="0x100/0xFF00"
_PBR_TABLE=300
_PBR_PRIO_DIRECT=97
_PBR_PRIO_FWMARK=98
_PBR_PRIO_SOURCE=99

GEO_IPSET_VPN="awg_geo_dst"
GEO_IPSET_DIRECT="awg_geo_direct"

GEO_CURATED="google youtube netflix telegram cloudflare github discord twitter meta tiktok cn ru by ua private tor"

pbr_load_devices() {
    # Output: N<TAB>ip<TAB>mac<TAB>name<TAB>policy per device; silently skip
    # entries where ip and policy are absent.
    _count="$(state_get awg_dev_count 2>/dev/null)"
    [ -n "${_count}" ] || return 0
    [ "${_count}" -gt 0 ] 2>/dev/null || return 0
    _i=0
    while [ "${_i}" -lt "${_count}" ]; do
        _ip="$(state_get     "awg_dev_${_i}_ip")"
        _mac="$(state_get    "awg_dev_${_i}_mac")"
        _name="$(state_get   "awg_dev_${_i}_name")"
        _policy="$(state_get "awg_dev_${_i}_policy")"
        if [ -n "${_ip}" ] && [ -n "${_policy}" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "${_i}" "${_ip}" "${_mac}" "${_name}" "${_policy}"
        fi
        _i=$(( _i + 1 ))
    done
}

_pbr_resolve_ip() {
    _mac="$1"
    [ -n "${_mac}" ] || return 1
    if [ -f "${AMNEZIAWG_DNSMASQ_LEASES}" ]; then
        _ip="$(awk -v m="${_mac}" 'tolower($2) == tolower(m) { print $3; exit }' \
               "${AMNEZIAWG_DNSMASQ_LEASES}")"
        [ -n "${_ip}" ] && { printf '%s\n' "${_ip}"; return 0; }
    fi
    _ip="$(ip neigh show 2>/dev/null | awk -v m="${_mac}" \
          'tolower($5) == tolower(m) { print $1; exit }')"
    [ -n "${_ip}" ] && { printf '%s\n' "${_ip}"; return 0; }
    return 1
}

# --- applied state tracking ---------------------------------------------------

_pbr_state_file() { printf '%s\n' "${AMNEZIAWG_RUNTIME}/pbr-applied-rules"; }

# Single source of truth for the reapply hash.
# Must include ALL state that, when changed, requires a full teardown+setup.
_pbr_state_hash() {
    _hash_input="$(pbr_load_devices)
$(state_get awg_geo_entries)
$(state_get awg_geo_entries_direct)
$(state_get awg_default_policy)
$(state_get awg_killswitch_strict)
$(state_get awg_geo_categories_custom)"
    _custom="$(state_get awg_geo_categories_custom | tr ',' ' ')"
    for _cat in ${GEO_CURATED} ${_custom}; do
        [ -z "${_cat}" ] && continue
        _hash_input="${_hash_input}
${_cat}:$(state_get "awg_geo_${_cat}_mode")"
    done
    printf '%s' "${_hash_input}" | sha1sum | awk '{print $1}'
}

pbr_setup() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    chain_ensure mangle AMNEZIAWG
    chain_flush  mangle AMNEZIAWG

    # Ensure global fwmark rule (idempotent-ish: del before add)
    ip rule del fwmark "${_PBR_FWMARK}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_FWMARK}" 2>/dev/null || true
    ip rule add fwmark "${_PBR_FWMARK}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_FWMARK}"

    pbr_apply
    # Save snapshot for incremental compare
    pbr_load_devices > "$(_pbr_state_file)"
    _pbr_state_hash > "$(_pbr_state_file).sha"
}

_pbr_lan_cidr() {
    _ip="$(nvram get lan_ipaddr 2>/dev/null)"
    _nm="$(nvram get lan_netmask 2>/dev/null)"
    [ -n "${_ip}" ] && [ -n "${_nm}" ] || { echo ""; return 1; }
    # Convert dotted netmask to prefix length (POSIX-safe)
    _pref=0
    _IFS_save="${IFS}"; IFS='.'
    for _octet in ${_nm}; do
        case "${_octet}" in
            255) _pref=$(( _pref + 8 )) ;;
            254) _pref=$(( _pref + 7 ));;
            252) _pref=$(( _pref + 6 ));;
            248) _pref=$(( _pref + 5 ));;
            240) _pref=$(( _pref + 4 ));;
            224) _pref=$(( _pref + 3 ));;
            192) _pref=$(( _pref + 2 ));;
            128) _pref=$(( _pref + 1 ));;
            0) : ;;
        esac
    done
    IFS="${_IFS_save}"
    # Compute network address (zero out host bits naively, octet-level)
    _net=""
    _remain="${_pref}"
    _IFS_save="${IFS}"; IFS='.'
    for _octet in ${_ip}; do
        if [ "${_remain}" -ge 8 ]; then
            _net="${_net}.${_octet}"
            _remain=$(( _remain - 8 ))
        elif [ "${_remain}" -gt 0 ]; then
            _mask_octet=$(( 256 - (1 << (8 - _remain)) ))
            _net="${_net}.$(( _octet & _mask_octet ))"
            _remain=0
        else
            _net="${_net}.0"
        fi
    done
    IFS="${_IFS_save}"
    printf '%s/%s\n' "${_net#.}" "${_pref}"
}

pbr_apply() {
    _default="$(state_get awg_default_policy 2>/dev/null)"
    [ -z "${_default}" ] && _default="direct"

    # Per-device first (needed for vpn_all RETURN exceptions later)
    pbr_load_devices | while IFS="$(printf '\t')" read -r _n _ip _mac _name _policy; do
        if [ -n "${_mac}" ]; then
            _resolved="$(_pbr_resolve_ip "${_mac}" 2>/dev/null)" || _resolved=""
            if [ -n "${_resolved}" ] && [ "${_resolved}" != "${_ip}" ]; then
                log_warn "pbr: device ${_name:-#${_n}} IP changed ${_ip} -> ${_resolved} (using resolved)"
                _ip="${_resolved}"
            fi
        fi
        case "${_policy}" in
            vpn_all)
                ip rule del from "${_ip}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_SOURCE}" 2>/dev/null || true
                ip rule add from "${_ip}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_SOURCE}"
                ;;
            direct)
                ip rule del from "${_ip}" lookup main prio "${_PBR_PRIO_DIRECT}" 2>/dev/null || true
                ip rule add from "${_ip}" lookup main prio "${_PBR_PRIO_DIRECT}"
                ;;
            vpn_geo)
                iptables -t mangle -A AMNEZIAWG -s "${_ip}" \
                    -m set --match-set awg_geo_dst dst \
                    -j MARK --set-mark "${_PBR_FWMARK}"
                ;;
            vpn_except_geo)
                # RETURN for packets destined to the bypass pool must precede
                # the blanket MARK for this source — iptables evaluates rules
                # in append order. -A appends, so insertion order here matches
                # traversal order.
                # Routing is via the global fwmark rule (prio 98) — we do NOT
                # add a per-source 'from <ip>' rule, because that would force
                # all packets from this IP through table 300 and defeat the
                # RETURN bypass. Mangle-only, like vpn_geo.
                iptables -t mangle -A AMNEZIAWG -s "${_ip}" \
                    -m set --match-set awg_geo_direct dst \
                    -j RETURN
                iptables -t mangle -A AMNEZIAWG -s "${_ip}" \
                    -j MARK --set-mark "${_PBR_FWMARK}"
                ;;
        esac
    done

    # default_policy=vpn_all — blanket MARK after per-device RETURN exceptions
    if [ "${_default}" = "vpn_all" ]; then
        # Insert RETURN exceptions for every direct device FIRST in chain
        pbr_load_devices | while IFS="$(printf '\t')" read -r _n _ip _mac _name _policy; do
            [ "${_policy}" = "direct" ] || continue
            iptables -t mangle -I AMNEZIAWG -s "${_ip}" -j RETURN
        done
        # Blanket MARK for LAN subnet (appended at end)
        _cidr="$(_pbr_lan_cidr)"
        if [ -n "${_cidr}" ]; then
            iptables -t mangle -A AMNEZIAWG -s "${_cidr}" \
                -j MARK --set-mark "${_PBR_FWMARK}"
        fi
    fi
}

pbr_teardown() {
    pbr_load_devices | while IFS="$(printf '\t')" read -r _n _ip _mac _name _policy; do
        case "${_policy}" in
            vpn_all)
                ip rule del from "${_ip}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_SOURCE}" 2>/dev/null || true
                ;;
            direct)
                ip rule del from "${_ip}" lookup main prio "${_PBR_PRIO_DIRECT}" 2>/dev/null || true
                ;;
        esac
    done
    ip rule del fwmark "${_PBR_FWMARK}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_FWMARK}" 2>/dev/null || true
    chain_flush mangle AMNEZIAWG 2>/dev/null || true
    rm -f "$(_pbr_state_file)" "$(_pbr_state_file).sha"
}

pbr_kill_switch_arm() {
    _strict="$(state_get awg_killswitch_strict 2>/dev/null)"
    [ -z "${_strict}" ] && _strict=1
    if [ "${_strict}" != "1" ]; then
        log_info "pbr: kill-switch soft mode (awg_killswitch_strict=0), not arming"
        return 0
    fi

    chain_ensure filter AMNEZIAWG_KILL
    chain_flush  filter AMNEZIAWG_KILL
    iptables -A AMNEZIAWG_KILL -m mark --mark "${_PBR_FWMARK}" -j DROP

    pbr_load_devices | while IFS="$(printf '\t')" read -r _n _ip _mac _name _policy; do
        case "${_policy}" in
            vpn_all|vpn_geo|vpn_except_geo)
                iptables -A AMNEZIAWG_KILL -s "${_ip}" -j DROP
                ;;
        esac
    done

    mkdir -p "${AMNEZIAWG_RUNTIME}"
    touch "${AMNEZIAWG_RUNTIME}/killswitch-armed"
    log_warn "pbr: kill-switch armed"
}

pbr_kill_switch_disarm() {
    chain_flush filter AMNEZIAWG_KILL 2>/dev/null || true
    rm -f "${AMNEZIAWG_RUNTIME}/killswitch-armed"
    log_info "pbr: kill-switch disarmed"
}

pbr_reapply_incremental() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    _current="$(_pbr_state_hash)"
    _previous=""
    if [ -f "$(_pbr_state_file).sha" ]; then
        _previous="$(cat "$(_pbr_state_file).sha")"
    fi
    if [ "${_current}" = "${_previous}" ]; then
        log_debug "pbr: no state change, skip reapply"
        return 0
    fi
    log_info "pbr: state changed, full reapply"
    # Full reapply = teardown + setup. Safer than delta in M3 MVP.
    pbr_teardown
    pbr_setup
    printf '%s\n' "${_current}" > "$(_pbr_state_file).sha"
}

pbr_geo_add() {
    _cidr="$1"
    [ -n "${_cidr}" ] || return 1
    _list="$(state_get awg_geo_entries)"
    if [ -z "${_list}" ]; then
        _list="${_cidr}"
    else
        # avoid duplicate
        case ",${_list}," in
            *,"${_cidr}",*) return 0 ;;
        esac
        _list="${_list},${_cidr}"
    fi
    state_set "awg_geo_entries" "${_list}"
}

pbr_geo_remove() {
    _cidr="$1"
    _list="$(state_get awg_geo_entries)"
    [ -n "${_list}" ] || return 0
    _new=""
    _IFS_save="${IFS}"; IFS=','
    for _entry in ${_list}; do
        [ "${_entry}" = "${_cidr}" ] && continue
        if [ -z "${_new}" ]; then _new="${_entry}"; else _new="${_new},${_entry}"; fi
    done
    IFS="${_IFS_save}"
    state_set "awg_geo_entries" "${_new}"
}

pbr_geo_clear() {
    state_set "awg_geo_entries" ""
}

# NOTE: The initial 'ipset destroy' is best-effort (tolerated via || true) and
# handles the v1 hash:ip -> hash:net schema migration. On a live system with
# iptables rules referencing this set, destroy will fail silently — callers
# must invoke pbr_teardown (or equivalent chain flush) first if the set is
# already populated and referenced. pbr_setup enforces this ordering.
pbr_geo_apply() {
    _list="$(state_get awg_geo_entries)"
    ipset destroy "${GEO_IPSET_VPN}" 2>/dev/null || true
    _tmp="$(mktemp)"
    {
        printf 'create %s hash:net family inet maxelem 65536 -exist\n' "${GEO_IPSET_VPN}"
        printf 'flush %s\n' "${GEO_IPSET_VPN}"
        if [ -n "${_list}" ]; then
            _IFS_save="${IFS}"; IFS=','
            for _cidr in ${_list}; do
                _cidr="$(printf '%s' "${_cidr}" | tr -d ' ')"
                [ -n "${_cidr}" ] || continue
                printf 'add %s %s -exist\n' "${GEO_IPSET_VPN}" "${_cidr}"
            done
            IFS="${_IFS_save}"
        fi
    } > "${_tmp}"
    if command -v ipset-restore >/dev/null 2>&1; then
        ipset-restore < "${_tmp}"
    else
        ipset restore < "${_tmp}"
    fi
    rm -f "${_tmp}"
}

pbr_geo_direct_add() {
    _cidr="$(printf '%s' "$1" | tr -d ' ')"
    [ -n "${_cidr}" ] || return 1
    _existing="$(state_get awg_geo_entries_direct)"
    if [ -z "${_existing}" ]; then
        state_set "awg_geo_entries_direct" "${_cidr}"
    else
        state_set "awg_geo_entries_direct" "${_existing},${_cidr}"
    fi
}

pbr_geo_direct_remove() {
    _cidr="$(printf '%s' "$1" | tr -d ' ')"
    _existing="$(state_get awg_geo_entries_direct)"
    [ -z "${_existing}" ] && return 0
    _new=""
    _IFS_save="${IFS}"; IFS=','
    for _c in ${_existing}; do
        _c="$(printf '%s' "${_c}" | tr -d ' ')"
        [ "${_c}" = "${_cidr}" ] && continue
        [ -z "${_new}" ] && _new="${_c}" || _new="${_new},${_c}"
    done
    IFS="${_IFS_save}"
    state_set "awg_geo_entries_direct" "${_new}"
}

pbr_geo_direct_clear() {
    state_set "awg_geo_entries_direct" ""
}

# NOTE: The initial 'ipset destroy' is best-effort (tolerated via || true) and
# handles the v1 hash:ip -> hash:net schema migration. On a live system with
# iptables rules referencing this set, destroy will fail silently — callers
# must invoke pbr_teardown (or equivalent chain flush) first if the set is
# already populated and referenced. pbr_setup enforces this ordering.
pbr_geo_direct_apply() {
    _list="$(state_get awg_geo_entries_direct)"
    ipset destroy "${GEO_IPSET_DIRECT}" 2>/dev/null || true
    _tmp="$(mktemp)"
    {
        printf 'create %s hash:net family inet maxelem 65536 -exist\n' "${GEO_IPSET_DIRECT}"
        printf 'flush %s\n' "${GEO_IPSET_DIRECT}"
        if [ -n "${_list}" ]; then
            _IFS_save="${IFS}"; IFS=','
            for _cidr in ${_list}; do
                _cidr="$(printf '%s' "${_cidr}" | tr -d ' ')"
                [ -n "${_cidr}" ] || continue
                printf 'add %s %s -exist\n' "${GEO_IPSET_DIRECT}" "${_cidr}"
            done
            IFS="${_IFS_save}"
        fi
    } > "${_tmp}"
    if command -v ipset-restore >/dev/null 2>&1; then
        ipset-restore < "${_tmp}"
    else
        ipset restore < "${_tmp}"
    fi
    rm -f "${_tmp}"
}

pbr_device_set() {
    _ip="$1"; _policy="$2"; _name="$3"; _mac="$4"
    [ -n "${_ip}" ] && [ -n "${_policy}" ] || return 1
    _count="$(state_get awg_dev_count)"
    [ -z "${_count}" ] && _count=0
    _found=-1
    _i=0
    while [ "${_i}" -lt "${_count}" ]; do
        _cur_ip="$(state_get "awg_dev_${_i}_ip")"
        if [ "${_cur_ip}" = "${_ip}" ]; then _found="${_i}"; break; fi
        _i=$(( _i + 1 ))
    done
    if [ "${_found}" -ge 0 ]; then
        _idx="${_found}"
    else
        _idx="${_count}"
        state_set "awg_dev_count" "$(( _count + 1 ))"
    fi
    state_set "awg_dev_${_idx}_ip"     "${_ip}"
    state_set "awg_dev_${_idx}_policy" "${_policy}"
    state_set "awg_dev_${_idx}_name"   "${_name}"
    state_set "awg_dev_${_idx}_mac"    "${_mac}"
}

pbr_device_remove() {
    _ip="$1"
    _count="$(state_get awg_dev_count)"
    [ -z "${_count}" ] || [ "${_count}" -le 0 ] 2>/dev/null && return 0

    _found=-1
    _i=0
    while [ "${_i}" -lt "${_count}" ]; do
        _cur_ip="$(state_get "awg_dev_${_i}_ip")"
        if [ "${_cur_ip}" = "${_ip}" ]; then _found="${_i}"; break; fi
        _i=$(( _i + 1 ))
    done
    [ "${_found}" -ge 0 ] || return 0

    # Shift all entries [found+1 .. count-1] down by 1
    _j="${_found}"
    while [ "${_j}" -lt "$(( _count - 1 ))" ]; do
        _next=$(( _j + 1 ))
        for _field in ip mac name policy; do
            _v="$(state_get "awg_dev_${_next}_${_field}")"
            state_set "awg_dev_${_j}_${_field}" "${_v}"
        done
        _j=$(( _j + 1 ))
    done
    # Clear last
    for _field in ip mac name policy; do
        state_delete "awg_dev_$(( _count - 1 ))_${_field}"
    done
    state_set "awg_dev_count" "$(( _count - 1 ))"
}

pbr_default_set() {
    _policy="$1"
    case "${_policy}" in
        direct|vpn_all|vpn_geo) state_set "awg_default_policy" "${_policy}" ;;
        *) log_error "pbr_default_set: invalid policy '${_policy}'"; return 1 ;;
    esac
}
