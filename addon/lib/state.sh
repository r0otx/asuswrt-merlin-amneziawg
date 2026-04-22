#!/bin/sh
# addon/lib/state.sh — Merlin custom_settings.txt access + v1 migration stubs.
#
# Uses atomic write (tmp + mv) to avoid partial reads from concurrent webui polls.
# custom_settings.txt format: one line per entry, space-separated "key value".
#
# Caveats:
#   - state_get returns empty for both "missing key" and "empty value" — callers
#     that need to distinguish presence must add state_has in Module 2.
#   - Values must not contain newlines; leading/trailing whitespace is not
#     preserved across round-trip.
#   - Atomic iff AMNEZIAWG_CUSTOM_SETTINGS and its directory share one filesystem
#     (true by default on /jffs; override at your own risk).

: "${AMNEZIAWG_CUSTOM_SETTINGS:=/jffs/addons/custom_settings.txt}"

# Ensure log_* helpers are available (fatal if missing — state should never be used
# before log).
if ! command -v log_info >/dev/null 2>&1; then
    echo "state.sh: log.sh must be sourced before state.sh" >&2
    return 1 2>/dev/null || exit 1
fi

_state_ensure_file() {
    if [ ! -f "${AMNEZIAWG_CUSTOM_SETTINGS}" ]; then
        mkdir -p "$(dirname "${AMNEZIAWG_CUSTOM_SETTINGS}")"
        : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    fi
}

state_get() {
    _key="$1"
    _state_ensure_file
    awk -v k="${_key}" '$1 == k { $1=""; sub(/^ /, ""); print; exit }' \
        "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

state_set() {
    _key="$1"; _value="$2"
    _state_ensure_file
    _tmp="${AMNEZIAWG_CUSTOM_SETTINGS}.tmp.$$"
    awk -v k="${_key}" -v v="${_value}" '
        $1 == k { next }
        { print }
        END { printf "%s %s\n", k, v }
    ' "${AMNEZIAWG_CUSTOM_SETTINGS}" > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

state_delete() {
    _key="$1"
    _state_ensure_file
    _tmp="${AMNEZIAWG_CUSTOM_SETTINGS}.tmp.$$"
    awk -v k="${_key}" '$1 == k { next } { print }' \
        "${AMNEZIAWG_CUSTOM_SETTINGS}" > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

state_list_awg_keys() {
    _state_ensure_file
    awk '$1 ~ /^awg_/ { print $1 }' "${AMNEZIAWG_CUSTOM_SETTINGS}"
}

# --- v1 migration -----------------------------------------------------------

# v1→v2 key rename map, colon-separated "v1:v2" pairs.
_V1_KEY_MAP="amneziawg_privatekey:awg_privatekey
amneziawg_publickey:awg_peer_publickey
amneziawg_presharedkey:awg_peer_presharedkey
amneziawg_address:awg_address
amneziawg_endpoint:awg_peer_endpoint
amneziawg_allowedips:awg_peer_allowed_ips
amneziawg_dns:awg_dns
amneziawg_mtu:awg_mtu
amneziawg_jc:awg_jc
amneziawg_jmin:awg_jmin
amneziawg_jmax:awg_jmax
amneziawg_s1:awg_s1
amneziawg_s2:awg_s2
amneziawg_s3:awg_s3
amneziawg_s4:awg_s4
amneziawg_h1:awg_h1
amneziawg_h2:awg_h2
amneziawg_h3:awg_h3
amneziawg_h4:awg_h4
amneziawg_i1:awg_i1
amneziawg_i2:awg_i2
amneziawg_i3:awg_i3
amneziawg_i4:awg_i4
amneziawg_i5:awg_i5
amneziawg_persistent_keepalive:awg_peer_keepalive
amneziawg_enabled:awg_enabled
amneziawg_default_policy:awg_default_policy"

: "${AMNEZIAWG_V1_ADDON_DIR:=/jffs/addons/amneziawg}"
: "${AMNEZIAWG_V1_OPT_DIR:=/opt/amneziawg}"
: "${AMNEZIAWG_BACKUP_DIR:=/opt/etc/amneziawg/backups}"
: "${AMNEZIAWG_V2_CONF:=/opt/etc/amneziawg/awg0.conf}"
: "${AMNEZIAWG_UNMIGRATED_KEYS:=/opt/etc/amneziawg/backups/v1-unmigrated-keys.txt}"
: "${AMNEZIAWG_MIGRATED_FLAG:=/jffs/addons/amneziawg/.migrated-from-v1}"
: "${AMNEZIAWG_JFFS_SCRIPTS:=/jffs/scripts}"
: "${AWG_VERSION:=0.0.0-dev}"

_state_ensure_backup_dir() {
    mkdir -p "${AMNEZIAWG_BACKUP_DIR}"
}

_state_rotate_backups() {
    _prefix="$1"
    _state_ensure_backup_dir
    # Keep 5 newest tar.gz matching prefix.
    # shellcheck disable=SC2012
    ls -t "${AMNEZIAWG_BACKUP_DIR}/${_prefix}"*.tar.gz 2>/dev/null \
        | awk 'NR>5' \
        | xargs rm -f 2>/dev/null || true
}

_state_migrate_v1_devices() {
    _blob="$(state_get amneziawg_devices 2>/dev/null)"
    [ -n "${_blob}" ] || return 0
    # Parse JSON array of objects — best-effort awk split.
    # v1 format: [{"ip":"x","name":"y","mac":"z","policy":"all"},{...}]
    case "${_blob}" in
        \[*\])
            : ;;
        *)
            log_warn "migrate_from_v1: v1 devices blob unparseable, skipping"
            state_delete amneziawg_devices
            return 0 ;;
    esac
    _n=0
    # Strip leading [ and trailing ]
    _inner="${_blob#[}"
    _inner="${_inner%]}"
    # Use awk to walk objects
    _tmp="$(mktemp)"
    printf '%s' "${_inner}" | awk '
        {
            gsub(/\},\{/, "\n")
            gsub(/^\{/, "")
            gsub(/\}$/, "")
            print
        }
    ' > "${_tmp}"
    while IFS= read -r _obj; do
        [ -n "${_obj}" ] || continue
        _ip="$(printf '%s' "${_obj}" | awk 'BEGIN{FS="\"ip\":\""} NF>1 {split($2, a, "\""); print a[1]}')"
        _name="$(printf '%s' "${_obj}" | awk 'BEGIN{FS="\"name\":\""} NF>1 {split($2, a, "\""); print a[1]}')"
        _mac="$(printf '%s' "${_obj}" | awk 'BEGIN{FS="\"mac\":\""} NF>1 {split($2, a, "\""); print a[1]}')"
        _policy="$(printf '%s' "${_obj}" | awk 'BEGIN{FS="\"policy\":\""} NF>1 {split($2, a, "\""); print a[1]}')"
        [ -n "${_ip}" ] || continue
        case "${_policy}" in
            all)     _policy="vpn_all" ;;
            geo)     _policy="vpn_geo" ;;
            vpn_all) : ;;
            vpn_geo) : ;;
            direct)  : ;;
            *)       _policy="direct" ;;
        esac
        state_set "awg_dev_${_n}_ip"     "${_ip}"
        state_set "awg_dev_${_n}_name"   "${_name}"
        state_set "awg_dev_${_n}_mac"    "${_mac}"
        state_set "awg_dev_${_n}_policy" "${_policy}"
        _n=$(( _n + 1 ))
    done < "${_tmp}"
    rm -f "${_tmp}"
    [ "${_n}" -gt 0 ] && state_set "awg_dev_count" "${_n}"
    state_delete amneziawg_devices
    log_info "migrate_from_v1: migrated ${_n} device entries"
}

migrate_from_v1() {
    # Detect: v1 addon dir exists, no lib/ subdir, no flag.
    if [ ! -f "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh" ] \
       || [ -d "${AMNEZIAWG_V1_ADDON_DIR}/lib" ] \
       || [ -f "${AMNEZIAWG_MIGRATED_FLAG}" ]; then
        log_info "migrate_from_v1: no v1 detected, skipping"
        return 0
    fi

    log_info "migrate_from_v1: v1 detected, starting migration"

    # Stop v1 tunnel (best-effort)
    "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh" stop 2>/dev/null || true
    pkill -TERM -x amneziawg-go 2>/dev/null || true
    sleep 1

    # Backup
    _ts="$(date +%Y%m%d-%H%M%S)"
    _state_ensure_backup_dir
    _bkp="${AMNEZIAWG_BACKUP_DIR}/backup-v1-${_ts}.tar.gz"
    _keys_file="${AMNEZIAWG_BACKUP_DIR}/backup-v1-${_ts}-keys.txt"

    tar czf "${_bkp}" -C / \
        "${AMNEZIAWG_V1_OPT_DIR#/}" \
        "${AMNEZIAWG_V1_ADDON_DIR#/}" 2>/dev/null || \
        log_warn "migrate_from_v1: partial backup (some paths missing)"

    awk '/^amneziawg_/ { print }' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${_keys_file}" 2>/dev/null || :
    _state_rotate_backups "backup-v1-"

    log_info "migrate_from_v1: backup saved at ${_bkp}"

    # Copy v1 awg0.conf to v2 location
    if [ -f "${AMNEZIAWG_V1_OPT_DIR}/awg0.conf" ]; then
        mkdir -p "$(dirname "${AMNEZIAWG_V2_CONF}")"
        cp "${AMNEZIAWG_V1_OPT_DIR}/awg0.conf" "${AMNEZIAWG_V2_CONF}"
        chmod 600 "${AMNEZIAWG_V2_CONF}"
        log_info "migrate_from_v1: copied awg0.conf to ${AMNEZIAWG_V2_CONF}"
    fi

    # Translate keys — use file descriptor 3 to avoid subshell scope issue with `while`
    _map_tmp="$(mktemp)"
    printf '%s\n' "${_V1_KEY_MAP}" > "${_map_tmp}"
    while IFS=':' read -r _v1 _v2; do
        [ -n "${_v1}" ] || continue
        _val="$(state_get "${_v1}")"
        if [ -n "${_val}" ]; then
            state_set "${_v2}" "${_val}"
            state_delete "${_v1}"
        fi
    done < "${_map_tmp}"
    rm -f "${_map_tmp}"

    # Save remaining unmigrated amneziawg_* keys (before device migration deletes them)
    _state_ensure_backup_dir
    awk '/^amneziawg_/ { print }' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${AMNEZIAWG_UNMIGRATED_KEYS}" 2>/dev/null || :

    # Translate v1 'amneziawg_devices' JSON blob into per-device awg_dev_N_* keys.
    _state_migrate_v1_devices

    # Remove v1 hook invocations from /jffs/scripts/* (strict line pattern).
    for _hook in service-event firewall-start wan-event services-start; do
        _f="${AMNEZIAWG_JFFS_SCRIPTS}/${_hook}"
        [ -f "${_f}" ] || continue
        sed -i.bak '\|^[[:space:]]*/jffs/addons/amneziawg/amneziawg\.sh|d' "${_f}" 2>/dev/null || :
        rm -f "${_f}.bak"
    done

    # Write migration flag
    mkdir -p "$(dirname "${AMNEZIAWG_MIGRATED_FLAG}")"
    {
        printf 'migrated_at=%s\n' "${_ts}"
        printf 'v2_version=%s\n'  "${AWG_VERSION}"
        printf 'backup=%s\n'      "${_bkp}"
    } > "${AMNEZIAWG_MIGRATED_FLAG}"

    state_set "awg_last_migrated_from" "v1"
    log_info "migrate_from_v1: complete"
    return 0
}

# --- key validation ----------------------------------------------------------

# state_validate_key KEY VALUE
# Returns 0 if VALUE is acceptable for KEY, 1 otherwise.
# Uses case-glob matching on KEY; the final *) clause accepts unknown keys
# without complaint so that future keys don't break old code.
state_validate_key() {
    _key="$1"
    _val="$2"
    case "${_key}" in
        awg_geo_*_mode)
            case "${_val}" in
                off|vpn|direct) return 0 ;;
                *) log_warn "state: invalid mode ${_val} for ${_key} (expected off|vpn|direct)"; return 1 ;;
            esac
            ;;
        awg_geo_entries_direct)
            [ -z "${_val}" ] && return 0
            _IFS_save="${IFS}"; IFS=','
            for _c in ${_val}; do
                _c="$(printf '%s' "${_c}" | tr -d ' ')"
                [ -z "${_c}" ] && continue
                case "${_c}" in
                    *:*/*)
                        printf '%s' "${_c}" | grep -Eq '^[0-9A-Fa-f:]+/[0-9]+$' || {
                            IFS="${_IFS_save}"; return 1
                        }
                        ;;
                    *.*.*.*/*)
                        printf '%s' "${_c}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || {
                            IFS="${_IFS_save}"; return 1
                        }
                        ;;
                    *)
                        IFS="${_IFS_save}"; return 1
                        ;;
                esac
            done
            IFS="${_IFS_save}"
            return 0
            ;;
        awg_geo_sync_parallel)
            case "${_val}" in 1|2|3|4|5|6|7|8) return 0 ;; *) return 1 ;; esac
            ;;
        awg_geo_sync_weekday)
            case "${_val}" in 0|1|2|3|4|5|6) return 0 ;; *) return 1 ;; esac
            ;;
        awg_geo_sync_hour)
            case "${_val}" in
                0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        awg_geo_categories_custom)
            [ -z "${_val}" ] && return 0
            _IFS_save="${IFS}"; IFS=','
            for _c in ${_val}; do
                case "${_c}" in *[!a-zA-Z0-9_-]*) IFS="${_IFS_save}"; return 1 ;; esac
            done
            IFS="${_IFS_save}"
            return 0
            ;;
        awg_dev_*_policy)
            case "${_val}" in
                vpn_all|vpn_geo|vpn_except_geo|direct) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac
}

backup_before_remove() {
    _ts="$(date +%Y%m%d-%H%M%S)"
    _state_ensure_backup_dir
    _bkp="${AMNEZIAWG_BACKUP_DIR}/backup-v2-${_ts}.tar.gz"
    _keys_file="${AMNEZIAWG_BACKUP_DIR}/backup-v2-${_ts}-keys.txt"

    tar czf "${_bkp}" -C / \
        opt/etc/amneziawg \
        jffs/addons/amneziawg/.migrated-from-v1 2>/dev/null || :

    awk '/^awg_/ { print }' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${_keys_file}" 2>/dev/null || :
    _state_rotate_backups "backup-v2-"

    log_info "backup_before_remove: saved ${_bkp}"
    return 0
}
