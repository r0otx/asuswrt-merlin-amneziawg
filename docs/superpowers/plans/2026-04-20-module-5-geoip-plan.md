# Module 5 — GeoIP / v2fly Auto-Population Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace v1 manual GeoIP CIDR list with a curated, auto-refreshing GeoIP + GeoSite system driven by v2fly text lists, plus a new 4th PBR policy `vpn_except_geo` for inverted routing (all-via-VPN-except-matched-networks).

**Architecture:** Per-category mode (`off`/`vpn`/`direct`) lands content in one of two ipsets (`awg_geo_dst` or `awg_geo_direct`). Weekly `cru` cron + on-demand WebUI "Sync now" drives `amneziawg.sh geo sync` which fetches v2fly via parallel curl (N=3), atomically replaces per-category files, regenerates `dnsmasq.d/*.conf` entries, and rebuilds ipsets. PBR gains a 4th policy that inserts `RETURN`-before-`MARK` rules bound to `awg_geo_direct`.

**Tech Stack:** POSIX shell (busybox ash), bats-core for backend tests, Node 18+ `--test` for WebUI helpers, vanilla JS, `cru` for cron, `ipset`+`iptables`, `curl`, `dnsmasq`.

**Spec:** `docs/superpowers/specs/2026-04-20-module-5-geoip-design.md`

**Starting point:** M4 complete at commit `95a00f5` (head of `main`).

---

## File structure

### Created in M5

- `addon/lib/geo.sh` — orchestration: `geo_sync`, `geo_list`, `geo_categories`, `geo_status`, `geo_clear`, `geo_cron_install`, `geo_cron_remove`.
- `addon/lib/geo_parse.sh` — pure helpers: `geo_filter_domain`, `geo_resolve_includes`.
- `addon/etc/amneziawg/sources.env` — packaged template with pinned v2fly refs.
- `addon/tests/geo_test.bats` — sync-flow tests.
- `addon/tests/geo_parse_test.bats` — domain filter / recursion tests.
- `addon/tests/pbr_except_geo_test.bats` — 4th policy tests.
- `addon/tests/fixtures/mock_curl.sh` — URL→fixture server with failure injection.
- `addon/tests/fixtures/mock_cru.sh` — cron stub that logs invocations.
- `addon/tests/fixtures/v2fly/ip/{google,ru,cn,private}.txt` — sample CIDR lists.
- `addon/tests/fixtures/v2fly/domain/{google,ru,telegram,includes-a,includes-b}` — sample domain files including a 3-deep `include:` chain + a cycle fixture.
- `addon/webui/tests/geo.test.js` — Node tests for `AWG.geo` and validator mode-enum.

### Modified in M5

- `addon/lib/geo.sh` — **overwrite** the 3-line M1 stub.
- `addon/lib/pbr.sh` — change `awg_geo_dst` to `hash:net`; add `awg_geo_direct`; add `vpn_except_geo` policy; extend `pbr_reapply_incremental` hash; new `pbr_geo_direct_apply` + `pbr_geo_direct_add/remove/clear`.
- `addon/lib/state.sh` — validator for `awg_geo_<cat>_mode`, `awg_geo_entries_direct`, `awg_geo_sync_parallel/weekday/hour`.
- `addon/lib/dns.sh` — `dns_dnsmasq_postconf_generate` concatenates `/opt/etc/amneziawg/geo/dnsmasq.d/*.conf`.
- `addon/lib/status.sh` — extend `status_emit_json` with `geo{ last_sync, enabled, errors, ipset_counts }`.
- `addon/lib/install.sh` — register `awggeosync` cron on install, deregister on uninstall, create `/opt/etc/amneziawg/geo/` tree, copy `sources.env`.
- `addon/amneziawg.sh` — add `geo` subcommand dispatcher + `start_awggeosync` service hook.
- `addon/webui/amneziawg_page.asp` — new "GeoIP" fieldset.
- `addon/webui/amneziawg.js` — new `AWG.geo` IIFE module, `AWG.pbr` gains `vpn_except_geo`, `AWG.validator` accepts mode enum.
- `addon/webui/amneziawg.css` — style the category mode table.
- `addon/tests/status_test.bats` — +1 test for `geo{}` JSON field.
- `Makefile` — no changes (test target already runs bats + node).
- `CHANGELOG.md` — M5 unreleased entry.

### Ipk payload files

New files under `addon/etc/amneziawg/` are automatically picked up by the M1 `make_ipk.sh` which globs `addon/*`. No Makefile changes required.

---

## Constants (defined here, referenced everywhere)

```sh
# These constants are used across geo.sh, pbr.sh, install.sh and tests.
AMNEZIAWG_GEO_ROOT="/opt/etc/amneziawg/geo"    # overridable in tests
AMNEZIAWG_GEO_LOCK="/tmp/amneziawg/geo.lock"
AMNEZIAWG_GEO_CRON_ID="awggeosync"
AMNEZIAWG_GEO_CRON_CMD="/jffs/addons/amneziawg/amneziawg.sh geo sync"

# Curated 16 categories (stable order; extending requires a code change).
GEO_CURATED="google youtube netflix telegram cloudflare github discord twitter meta tiktok cn ru by ua private tor"

# ipset names — awg_geo_dst exists in M3 (as hash:ip, being migrated to hash:net).
GEO_IPSET_VPN="awg_geo_dst"
GEO_IPSET_DIRECT="awg_geo_direct"
```

---

## Phase 1 — State schema extensions

### Task 1: Validators for new M5 state keys

**Files:**
- Modify: `addon/lib/state.sh`
- Modify: `addon/tests/state_test.bats`

- [ ] **Step 1: Append failing tests to `addon/tests/state_test.bats`**

```bash

@test "state_validate_key accepts awg_geo_<cat>_mode with valid enum" {
    run state_validate_key "awg_geo_ru_mode" "direct"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_google_mode" "vpn"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_telegram_mode" "off"
    [ "$status" -eq 0 ]
}

@test "state_validate_key rejects invalid awg_geo_<cat>_mode value" {
    run state_validate_key "awg_geo_ru_mode" "bypass"
    [ "$status" -ne 0 ]
}

@test "state_validate_key accepts awg_geo_entries_direct (csv CIDR)" {
    run state_validate_key "awg_geo_entries_direct" "10.0.0.0/8,192.168.0.0/16"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_entries_direct" ""
    [ "$status" -eq 0 ]
}

@test "state_validate_key rejects awg_geo_entries_direct with bad CIDR" {
    run state_validate_key "awg_geo_entries_direct" "not.an.ip/24"
    [ "$status" -ne 0 ]
}

@test "state_validate_key accepts awg_geo_sync_parallel in 1..8" {
    run state_validate_key "awg_geo_sync_parallel" "3"
    [ "$status" -eq 0 ]
}

@test "state_validate_key rejects awg_geo_sync_parallel out of range" {
    run state_validate_key "awg_geo_sync_parallel" "0"
    [ "$status" -ne 0 ]
    run state_validate_key "awg_geo_sync_parallel" "9"
    [ "$status" -ne 0 ]
}

@test "state_validate_key accepts awg_geo_sync_weekday 0..6 and hour 0..23" {
    run state_validate_key "awg_geo_sync_weekday" "0"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_sync_weekday" "6"
    [ "$status" -eq 0 ]
    run state_validate_key "awg_geo_sync_hour" "23"
    [ "$status" -eq 0 ]
}

@test "state_validate_key accepts awg_dev_N_policy = vpn_except_geo" {
    run state_validate_key "awg_dev_0_policy" "vpn_except_geo"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests — 8 fail**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/state_test.bats 2>&1 | tail -15
```
Expected: 8 failures (validator doesn't know new keys / enum).

- [ ] **Step 3: Open `addon/lib/state.sh`, locate `state_validate_key()`, add new clauses**

Find the existing `state_validate_key()` function (grep for `state_validate_key`). Add these cases to the big `case "${_key}"` statement, **before** the final catch-all:

```sh
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
            config_validate_cidr "${_c}" || { IFS="${_IFS_save}"; return 1; }
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
```

Also locate the existing `awg_dev_*_policy` case (grep for `vpn_all|vpn_geo|direct`) and extend:

```sh
    awg_dev_*_policy)
        case "${_val}" in
            vpn_all|vpn_geo|vpn_except_geo|direct) return 0 ;;
            *) return 1 ;;
        esac
        ;;
```

- [ ] **Step 4: Re-run tests — 8 pass, no regressions**

```bash
bats addon/tests/state_test.bats 2>&1 | tail -5
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add addon/lib/state.sh addon/tests/state_test.bats
git commit -m "feat(state): validate M5 keys (geo mode enum, entries_direct, sync schedule, vpn_except_geo)"
```

---

## Phase 2 — PBR: 4th policy `vpn_except_geo`

### Task 2: Migrate `awg_geo_dst` to `hash:net` + add `awg_geo_direct` ipset

**Why:** v2fly lists are CIDR ranges; `hash:ip` would explode on `/8`. `hash:net` stores networks natively. This is a one-time schema change — `pbr_geo_apply` destroys+recreates so no migration code is needed.

**Files:**
- Modify: `addon/lib/pbr.sh`
- Modify: `addon/tests/pbr_test.bats`

- [ ] **Step 1: Append failing test to `addon/tests/pbr_test.bats`**

```bash

@test "pbr_geo_apply creates awg_geo_dst as hash:net" {
    state_set "awg_geo_entries" "10.0.0.0/8,192.168.1.0/24"
    pbr_geo_apply
    grep -q 'create awg_geo_dst hash:net family inet' "${TMPDIR_TEST}/ipset.log"
    grep -q 'add awg_geo_dst 10.0.0.0/8' "${TMPDIR_TEST}/ipset.log"
}

@test "pbr_geo_direct_apply creates awg_geo_direct as hash:net" {
    state_set "awg_geo_entries_direct" "172.16.0.0/12"
    pbr_geo_direct_apply
    grep -q 'create awg_geo_direct hash:net family inet' "${TMPDIR_TEST}/ipset.log"
    grep -q 'add awg_geo_direct 172.16.0.0/12' "${TMPDIR_TEST}/ipset.log"
}

@test "pbr_geo_direct_add appends to awg_geo_entries_direct" {
    pbr_geo_direct_add "10.0.0.0/8"
    pbr_geo_direct_add "192.168.0.0/16"
    run state_get "awg_geo_entries_direct"
    [ "$output" = "10.0.0.0/8,192.168.0.0/16" ]
}

@test "pbr_geo_direct_remove drops a CIDR" {
    state_set "awg_geo_entries_direct" "10.0.0.0/8,172.16.0.0/12"
    pbr_geo_direct_remove "10.0.0.0/8"
    run state_get "awg_geo_entries_direct"
    [ "$output" = "172.16.0.0/12" ]
}
```

- [ ] **Step 2: Run tests — 4 fail**

```bash
bats addon/tests/pbr_test.bats -f "awg_geo_d" 2>&1 | tail -10
```
Expected: 4 failures (functions missing, wrong ipset type).

- [ ] **Step 3: Modify `addon/lib/pbr.sh` `pbr_geo_apply`**

Change line `printf 'create awg_geo_dst hash:ip family inet -exist\n'` to:

```sh
        printf 'create awg_geo_dst hash:net family inet maxelem 65536 -exist\n'
```

Since `hash:ip` cannot be converted in-place to `hash:net`, prepend a destroy:

```sh
    {
        printf 'destroy awg_geo_dst\n'
        printf 'create awg_geo_dst hash:net family inet maxelem 65536 -exist\n'
        ...
```

Wrap the `destroy` to tolerate first-run absence. Since `ipset restore` aborts on a failing line by default, switch to the `-!` flag (skip errors) or split into two invocations. Split is clearer:

Replace the whole `pbr_geo_apply` body with:

```sh
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
```

Also add near the top of `pbr.sh` (after the existing constants):

```sh
GEO_IPSET_VPN="awg_geo_dst"
GEO_IPSET_DIRECT="awg_geo_direct"
```

- [ ] **Step 4: Add `pbr_geo_direct_*` functions after `pbr_geo_apply` in `addon/lib/pbr.sh`**

```sh
pbr_geo_direct_add() {
    _cidr="$1"
    [ -n "${_cidr}" ] || return 1
    _existing="$(state_get awg_geo_entries_direct)"
    if [ -z "${_existing}" ]; then
        state_set "awg_geo_entries_direct" "${_cidr}"
    else
        state_set "awg_geo_entries_direct" "${_existing},${_cidr}"
    fi
}

pbr_geo_direct_remove() {
    _cidr="$1"
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
```

- [ ] **Step 5: Run tests — 4 pass**

```bash
bats addon/tests/pbr_test.bats 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add addon/lib/pbr.sh addon/tests/pbr_test.bats
git commit -m "feat(pbr): migrate awg_geo_dst to hash:net; add awg_geo_direct ipset + CRUD"
```

### Task 3: Add `vpn_except_geo` policy to `pbr_apply`

**Files:**
- Modify: `addon/lib/pbr.sh`
- Modify: `addon/tests/pbr_test.bats`

- [ ] **Step 1: Append failing tests**

```bash

@test "pbr_apply emits RETURN-before-MARK for vpn_except_geo device" {
    state_set "awg_dev_count" "1"
    state_set "awg_dev_0_ip" "192.168.1.50"
    state_set "awg_dev_0_policy" "vpn_except_geo"
    state_set "awg_dev_0_name" "laptop"
    state_set "awg_dev_0_mac" "aa:bb:cc:dd:ee:ff"
    pbr_apply
    # Verify RETURN rule precedes MARK for same IP
    grep -n 'AMNEZIAWG.*192.168.1.50.*awg_geo_direct.*RETURN' "${TMPDIR_TEST}/iptables.log"
    grep -n 'AMNEZIAWG.*192.168.1.50.*MARK --set-mark' "${TMPDIR_TEST}/iptables.log"
    _return_line="$(grep -n 'awg_geo_direct.*RETURN' "${TMPDIR_TEST}/iptables.log" | cut -d: -f1)"
    _mark_line="$(grep -n '192.168.1.50.*MARK --set-mark' "${TMPDIR_TEST}/iptables.log" | cut -d: -f1)"
    [ "${_return_line}" -lt "${_mark_line}" ]
}

@test "pbr_apply leaves vpn_geo and direct devices unchanged" {
    state_set "awg_dev_count" "2"
    state_set "awg_dev_0_ip" "192.168.1.60"; state_set "awg_dev_0_policy" "vpn_geo"
    state_set "awg_dev_1_ip" "192.168.1.61"; state_set "awg_dev_1_policy" "direct"
    pbr_apply
    grep -q 'AMNEZIAWG.*192.168.1.60.*awg_geo_dst.*MARK' "${TMPDIR_TEST}/iptables.log"
    grep -q 'ip rule add from 192.168.1.61' "${TMPDIR_TEST}/iptables.log" || \
        grep -q 'from 192.168.1.61' "${TMPDIR_TEST}/ip.log"
}
```

Note: the existing harness captures `iptables` and `ip` invocations — verify by running `grep -n 'TMPDIR_TEST' addon/tests/pbr_test.bats` to see exact log file names. Adjust the `grep` target if the harness uses a different file (e.g., `iptables_invocations.log`).

- [ ] **Step 2: Run tests — fail**

```bash
bats addon/tests/pbr_test.bats -f "vpn_except_geo" 2>&1 | tail -10
```

- [ ] **Step 3: Extend `pbr_apply()` in `addon/lib/pbr.sh`**

Find the `case "${_policy}"` block around line 137 (inside `pbr_apply`). Add the new arm **before** the closing `esac`:

```sh
            vpn_except_geo)
                # RETURN for packets destined to bypass pool, then blanket MARK.
                # Order matters — RETURN must be inserted first so it appears
                # first in chain traversal for packets from this source.
                iptables -t mangle -A AMNEZIAWG -s "${_ip}" \
                    -m set --match-set awg_geo_direct dst \
                    -j RETURN
                iptables -t mangle -A AMNEZIAWG -s "${_ip}" \
                    -j MARK --set-mark "${_PBR_FWMARK}"
                ip rule del from "${_ip}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_SOURCE}" 2>/dev/null || true
                ip rule add from "${_ip}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_SOURCE}"
                ;;
```

Also update `pbr_teardown()` (around line 170) — add handling for the new policy:

```sh
            vpn_except_geo)
                ip rule del from "${_ip}" lookup "${_PBR_TABLE}" prio "${_PBR_PRIO_SOURCE}" 2>/dev/null || true
                ;;
```

And `pbr_kill_switch_arm()` (around line 198) — include `vpn_except_geo` in the devices-to-drop set:

```sh
            vpn_all|vpn_geo|vpn_except_geo)
                iptables -A AMNEZIAWG_KILL -s "${_ip}" -j DROP
                ;;
```

- [ ] **Step 4: Run — tests pass**

```bash
bats addon/tests/pbr_test.bats 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/pbr.sh addon/tests/pbr_test.bats
git commit -m "feat(pbr): add vpn_except_geo policy (RETURN-before-MARK bypass via awg_geo_direct)"
```

### Task 4: Extend `pbr_reapply_incremental` hash to cover new state

**Files:**
- Modify: `addon/lib/pbr.sh`
- Modify: `addon/tests/pbr_test.bats`

- [ ] **Step 1: Append failing test**

```bash

@test "pbr_reapply_incremental re-applies when awg_geo_entries_direct changes" {
    state_set "awg_dev_count" "1"
    state_set "awg_dev_0_ip" "192.168.1.50"
    state_set "awg_dev_0_policy" "vpn_except_geo"
    pbr_reapply_incremental
    _sha_before="$(cat "$(pbr_state_file_path 2>/dev/null || echo "${AMNEZIAWG_RUNTIME}/pbr.state.sha")")"

    state_set "awg_geo_entries_direct" "10.0.0.0/8"
    pbr_reapply_incremental
    _sha_after="$(cat "${AMNEZIAWG_RUNTIME}/pbr.state.sha")"

    [ "${_sha_before}" != "${_sha_after}" ]
}

@test "pbr_reapply_incremental re-applies when awg_geo_<cat>_mode changes" {
    state_set "awg_dev_count" "1"
    state_set "awg_dev_0_ip" "192.168.1.50"
    state_set "awg_dev_0_policy" "vpn_geo"
    pbr_reapply_incremental
    _sha_before="$(cat "${AMNEZIAWG_RUNTIME}/pbr.state.sha")"

    state_set "awg_geo_ru_mode" "direct"
    pbr_reapply_incremental
    _sha_after="$(cat "${AMNEZIAWG_RUNTIME}/pbr.state.sha")"

    [ "${_sha_before}" != "${_sha_after}" ]
}
```

- [ ] **Step 2: Run tests — 2 fail**

- [ ] **Step 3: Modify `pbr_reapply_incremental` in `addon/lib/pbr.sh`**

Find `pbr_reapply_incremental()` and locate the hash input — it currently concatenates device state + `awg_geo_entries` + default policy. Add the new state to the hash input. Look for a block like:

```sh
_hash_input="$(pbr_load_devices)$(state_get awg_geo_entries)$(state_get awg_default_policy)$(state_get awg_killswitch_strict)"
```

Replace with:

```sh
_hash_input="$(pbr_load_devices)$(state_get awg_geo_entries)$(state_get awg_geo_entries_direct)$(state_get awg_default_policy)$(state_get awg_killswitch_strict)"
for _cat in ${GEO_CURATED} $(state_get awg_geo_categories_custom | tr ',' ' '); do
    _hash_input="${_hash_input}$(state_get "awg_geo_${_cat}_mode")"
done
```

Ensure `GEO_CURATED` is defined in `pbr.sh` (add near top if not already):

```sh
GEO_CURATED="google youtube netflix telegram cloudflare github discord twitter meta tiktok cn ru by ua private tor"
```

- [ ] **Step 4: Run — 2 pass**

- [ ] **Step 5: Commit**

```bash
git add addon/lib/pbr.sh addon/tests/pbr_test.bats
git commit -m "feat(pbr): include geo state in pbr_reapply_incremental hash"
```

---

## Phase 3 — Geo parse helpers (pure, unit-tested)

### Task 5: `geo_filter_domain` — strip unsupported prefixes + attributes

**Files:**
- Create: `addon/lib/geo_parse.sh`
- Create: `addon/tests/geo_parse_test.bats`
- Create: `addon/tests/fixtures/v2fly/domain/google`
- Create: `addon/tests/fixtures/v2fly/domain/ru`
- Create: `addon/tests/fixtures/v2fly/domain/telegram`

- [ ] **Step 1: Create fixture files**

`addon/tests/fixtures/v2fly/domain/google`:
```
# Comment line
domain:google.com
domain:gstatic.com @cn
full:www.google.com
regexp:.*\.googleapis\.com
include:youtube
```

`addon/tests/fixtures/v2fly/domain/ru`:
```
domain:yandex.ru
domain:mail.ru
regexp:.*\.sberbank\.ru
full:vk.com @ad
```

`addon/tests/fixtures/v2fly/domain/telegram`:
```
domain:telegram.org
domain:t.me
```

- [ ] **Step 2: Create failing test file `addon/tests/geo_parse_test.bats`**

```bash
#!/usr/bin/env bats
# shellcheck disable=SC2034

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo_parse.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "geo_filter_domain keeps domain: / full: and drops regexp:" {
    result="$(geo_filter_domain < "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain/ru")"
    echo "${result}" | grep -q '^yandex.ru$'
    echo "${result}" | grep -q '^mail.ru$'
    echo "${result}" | grep -q '^vk.com$'
    ! echo "${result}" | grep -q 'sberbank'
}

@test "geo_filter_domain strips @attribute suffixes and whitespace" {
    result="$(printf 'domain:example.com @cn\nfull:a.b @ad\n' | geo_filter_domain)"
    [ "$(echo "${result}" | sed -n 1p)" = "example.com" ]
    [ "$(echo "${result}" | sed -n 2p)" = "a.b" ]
}

@test "geo_filter_domain skips blank lines and comments" {
    result="$(printf '# comment\n\ndomain:ok.net\n   \n' | geo_filter_domain)"
    [ "$(echo "${result}" | wc -l)" = "1" ]
    echo "${result}" | grep -q '^ok.net$'
}

@test "geo_filter_domain passes through include: lines untouched" {
    result="$(printf 'include:youtube\ndomain:google.com\n' | geo_filter_domain)"
    echo "${result}" | grep -q '^include:youtube$'
}
```

- [ ] **Step 3: Run — 4 fail (library missing)**

```bash
bats addon/tests/geo_parse_test.bats 2>&1 | tail -10
```

- [ ] **Step 4: Create `addon/lib/geo_parse.sh`**

```sh
#!/bin/sh
# addon/lib/geo_parse.sh — pure parsers for v2fly domain-list-community format.
# Public:
#   geo_filter_domain            # stdin → stdout, stripping regexp: and attributes
#   geo_resolve_includes <cat> <src_dir> <depth> <visited_csv>
#                                # stdin: filtered output of one category
#                                # stdout: fully expanded (include: replaced with contents)

if ! command -v log_info >/dev/null 2>&1; then
    echo "geo_parse.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

geo_filter_domain() {
    # Read from stdin, write to stdout.
    # Keep lines: domain:..., full:..., include:...
    # Drop: regexp:..., comments (#...), blank.
    # Strip trailing @attr / whitespace from domain: and full: lines.
    awk '
        /^[[:space:]]*$/     { next }
        /^[[:space:]]*#/     { next }
        /^[[:space:]]*regexp:/ { next }
        /^[[:space:]]*include:/ {
            sub(/^[[:space:]]*/, "")
            sub(/[[:space:]].*/, "")
            print
            next
        }
        /^[[:space:]]*(domain|full):/ {
            sub(/^[[:space:]]*(domain|full):/, "")
            sub(/[[:space:]]+@.*$/, "")
            sub(/[[:space:]]+#.*$/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
            next
        }
    '
}
```

- [ ] **Step 5: Run — 4 pass**

- [ ] **Step 6: Commit**

```bash
git add addon/lib/geo_parse.sh addon/tests/geo_parse_test.bats addon/tests/fixtures/v2fly/domain/
git commit -m "feat(geo): add geo_filter_domain (v2fly format parser)"
```

### Task 6: `geo_resolve_includes` — depth-capped recursion with cycle guard

**Files:**
- Modify: `addon/lib/geo_parse.sh`
- Modify: `addon/tests/geo_parse_test.bats`
- Create: `addon/tests/fixtures/v2fly/domain/includes-a`
- Create: `addon/tests/fixtures/v2fly/domain/includes-b`
- Create: `addon/tests/fixtures/v2fly/domain/includes-c`
- Create: `addon/tests/fixtures/v2fly/domain/cycle-a`
- Create: `addon/tests/fixtures/v2fly/domain/cycle-b`

- [ ] **Step 1: Create fixture chains**

`addon/tests/fixtures/v2fly/domain/includes-a`:
```
domain:a.com
include:includes-b
```
`addon/tests/fixtures/v2fly/domain/includes-b`:
```
domain:b.com
include:includes-c
```
`addon/tests/fixtures/v2fly/domain/includes-c`:
```
domain:c.com
```
`addon/tests/fixtures/v2fly/domain/cycle-a`:
```
domain:ca.com
include:cycle-b
```
`addon/tests/fixtures/v2fly/domain/cycle-b`:
```
domain:cb.com
include:cycle-a
```

- [ ] **Step 2: Append failing tests**

```bash

@test "geo_resolve_includes expands 3-level chain" {
    cd "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain"
    result="$(geo_filter_domain < includes-a | geo_resolve_includes "." "3" "includes-a")"
    echo "${result}" | grep -q '^a.com$'
    echo "${result}" | grep -q '^b.com$'
    echo "${result}" | grep -q '^c.com$'
    ! echo "${result}" | grep -q '^include:'
}

@test "geo_resolve_includes caps recursion at max depth (logs warn)" {
    cd "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain"
    # With depth=1, includes-a expansion resolves includes-b but not includes-c
    result="$(geo_filter_domain < includes-a | geo_resolve_includes "." "1" "includes-a")"
    echo "${result}" | grep -q '^a.com$'
    echo "${result}" | grep -q '^b.com$'
    ! echo "${result}" | grep -q '^c.com$'
    grep -q 'geo_resolve_includes: depth cap' "${AMNEZIAWG_LOG_FILE}"
}

@test "geo_resolve_includes detects cycle and stops" {
    cd "${BATS_TEST_DIRNAME}/fixtures/v2fly/domain"
    result="$(geo_filter_domain < cycle-a | geo_resolve_includes "." "5" "cycle-a")"
    echo "${result}" | grep -q '^ca.com$'
    echo "${result}" | grep -q '^cb.com$'
    # Must terminate; no duplicate ca.com beyond first occurrence
    [ "$(echo "${result}" | grep -c '^ca.com$')" -eq 1 ]
    grep -q 'geo_resolve_includes: cycle detected' "${AMNEZIAWG_LOG_FILE}"
}

@test "geo_resolve_includes handles missing include target gracefully" {
    result="$(printf 'domain:ok.com\ninclude:nonexistent\n' | geo_resolve_includes "${TMPDIR_TEST}" "3" "root")"
    echo "${result}" | grep -q '^ok.com$'
    grep -q 'geo_resolve_includes: missing' "${AMNEZIAWG_LOG_FILE}"
}
```

- [ ] **Step 3: Run — 4 fail**

- [ ] **Step 4: Append `geo_resolve_includes` to `addon/lib/geo_parse.sh`**

```sh
geo_resolve_includes() {
    # Args: <src_dir> <max_depth> <visited_csv>
    # Stdin:  lines from geo_filter_domain
    # Stdout: fully expanded (include: replaced with target's filtered+resolved contents)
    _src_dir="$1"; _max_depth="$2"; _visited="$3"
    [ -z "${_max_depth}" ] && _max_depth=3

    while IFS= read -r _line; do
        case "${_line}" in
            include:*)
                _target="${_line#include:}"
                _target="$(printf '%s' "${_target}" | tr -d ' \t')"
                # Cycle check
                case ",${_visited}," in
                    *",${_target},"*)
                        log_warn "geo_resolve_includes: cycle detected at ${_target} (visited=${_visited})"
                        continue
                        ;;
                esac
                # Depth check
                if [ "${_max_depth}" -le 0 ] 2>/dev/null; then
                    log_warn "geo_resolve_includes: depth cap hit at include:${_target}"
                    continue
                fi
                # Missing-file check
                if [ ! -f "${_src_dir}/${_target}" ]; then
                    log_warn "geo_resolve_includes: missing include target ${_src_dir}/${_target}"
                    continue
                fi
                # Recurse: filter the target and pipe into a recursive call with depth-1
                geo_filter_domain < "${_src_dir}/${_target}" | \
                    geo_resolve_includes "${_src_dir}" \
                        "$(( _max_depth - 1 ))" \
                        "${_visited},${_target}"
                ;;
            *)
                [ -n "${_line}" ] && printf '%s\n' "${_line}"
                ;;
        esac
    done
}
```

- [ ] **Step 5: Run — 4 pass**

- [ ] **Step 6: Commit**

```bash
git add addon/lib/geo_parse.sh addon/tests/geo_parse_test.bats addon/tests/fixtures/v2fly/domain/
git commit -m "feat(geo): add geo_resolve_includes with depth cap and cycle guard"
```

---

## Phase 4 — Mocks & fixtures for sync tests

### Task 7: `mock_curl.sh` + v2fly IP fixtures

**Files:**
- Create: `addon/tests/fixtures/mock_curl.sh`
- Create: `addon/tests/fixtures/mock_cru.sh`
- Create: `addon/tests/fixtures/v2fly/ip/google.txt`
- Create: `addon/tests/fixtures/v2fly/ip/ru.txt`
- Create: `addon/tests/fixtures/v2fly/ip/cn.txt`
- Create: `addon/tests/fixtures/v2fly/ip/private.txt`

- [ ] **Step 1: Create IP fixtures**

`addon/tests/fixtures/v2fly/ip/google.txt`:
```
8.8.4.0/24
8.8.8.0/24
34.64.0.0/10
```
`addon/tests/fixtures/v2fly/ip/ru.txt`:
```
5.8.0.0/20
77.88.8.0/24
87.250.224.0/19
```
`addon/tests/fixtures/v2fly/ip/cn.txt`:
```
1.0.1.0/24
1.0.2.0/23
223.255.252.0/23
```
`addon/tests/fixtures/v2fly/ip/private.txt`:
```
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
```

- [ ] **Step 2: Create `addon/tests/fixtures/mock_curl.sh`**

```sh
#!/bin/sh
# Mock curl for bats tests.
# Behaviour:
#   - Parse -o <out> and the final URL argument.
#   - If MOCK_CURL_FAIL_URLS matches the URL (POSIX BRE), exit with MOCK_CURL_FAIL_RC (default 22).
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
# Expected URL shape (see sources.env):
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
```

- [ ] **Step 3: Create `addon/tests/fixtures/mock_cru.sh`**

```sh
#!/bin/sh
# Mock cru (Merlin cron wrapper). Logs every call; always succeeds.
: "${MOCK_CRU_LOG:=${TMPDIR_TEST:-/tmp}/cru.log}"
printf '%s\n' "$*" >> "${MOCK_CRU_LOG}"
exit 0
```

- [ ] **Step 4: Make both executable**

```bash
chmod +x addon/tests/fixtures/mock_curl.sh addon/tests/fixtures/mock_cru.sh
```

- [ ] **Step 5: Smoke-test the mocks manually**

```bash
export TMPDIR_TEST="$(mktemp -d)"
export MOCK_CURL_FIXTURES_DIR="$(pwd)/addon/tests/fixtures/v2fly"
./addon/tests/fixtures/mock_curl.sh -o /tmp/out.txt https://raw.githubusercontent.com/v2fly/geoip/release/text/google.txt
cat /tmp/out.txt
```
Expected: prints the 3 google CIDR lines.

```bash
MOCK_CURL_FAIL_URLS="/ru\.txt$" MOCK_CURL_FAIL_RC=28 ./addon/tests/fixtures/mock_curl.sh -o /tmp/fail.txt https://raw.githubusercontent.com/v2fly/geoip/release/text/ru.txt
echo "rc=$?"
```
Expected: `rc=28`.

- [ ] **Step 6: Commit**

```bash
git add addon/tests/fixtures/mock_curl.sh addon/tests/fixtures/mock_cru.sh addon/tests/fixtures/v2fly/ip/
git commit -m "test(geo): add mock_curl + mock_cru + v2fly IP fixtures"
```

---

## Phase 5 — Geo core (`addon/lib/geo.sh`)

### Task 8: `geo.sh` skeleton + `sources.env` + PID lock

**Files:**
- Modify (wholesale overwrite): `addon/lib/geo.sh`
- Create: `addon/etc/amneziawg/sources.env`
- Create: `addon/tests/geo_test.bats`

- [ ] **Step 1: Overwrite `addon/etc/amneziawg/sources.env` with pinned URLs**

```sh
mkdir -p addon/etc/amneziawg
cat > addon/etc/amneziawg/sources.env <<'EOF'
# addon/etc/amneziawg/sources.env
# Pinned sources for Module 5 GeoIP/GeoSite fetch. Installed into
# /opt/etc/amneziawg/geo/sources.env by install_run; users may edit
# in place. Upstream schema changes require a plan update.

V2FLY_GEOIP_URL_BASE="https://raw.githubusercontent.com/v2fly/geoip/release/text"
V2FLY_DOMAIN_URL_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
FETCH_TIMEOUT=60
FETCH_RETRIES=2
EOF
```

- [ ] **Step 2: Create failing test for `geo_sources_load` and PID lock**

`addon/tests/geo_test.bats` (new file):

```bash
#!/usr/bin/env bats
# shellcheck disable=SC2034

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/geo"
    export AMNEZIAWG_GEO_LOCK="${TMPDIR_TEST}/geo.lock"
    mkdir -p "${AMNEZIAWG_RUNTIME}" "${AMNEZIAWG_GEO_ROOT}"

    # Mock curl + cru
    mkdir -p "${TMPDIR_TEST}/bin"
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_curl.sh" "${TMPDIR_TEST}/bin/curl"
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_cru.sh" "${TMPDIR_TEST}/bin/cru"
    chmod +x "${TMPDIR_TEST}/bin/curl" "${TMPDIR_TEST}/bin/cru"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_CURL_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/v2fly"
    export MOCK_CURL_LOG="${TMPDIR_TEST}/curl.log"
    export MOCK_CRU_LOG="${TMPDIR_TEST}/cru.log"

    # ipset / iptables mocks (existing in fixtures/)
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_ipset.sh"    "${TMPDIR_TEST}/bin/ipset"
    cp "${BATS_TEST_DIRNAME}/fixtures/mock_iptables.sh" "${TMPDIR_TEST}/bin/iptables"
    chmod +x "${TMPDIR_TEST}/bin/ipset" "${TMPDIR_TEST}/bin/iptables"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo_parse.sh"
    . "${BATS_TEST_DIRNAME}/../lib/geo.sh"

    # Default sources.env for tests (no network)
    cat > "${AMNEZIAWG_GEO_ROOT}/sources.env" <<'EOF'
V2FLY_GEOIP_URL_BASE="https://raw.githubusercontent.com/v2fly/geoip/release/text"
V2FLY_DOMAIN_URL_BASE="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
FETCH_TIMEOUT=60
FETCH_RETRIES=2
EOF
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "geo_sources_load reads sources.env into shell vars" {
    geo_sources_load
    [ "${V2FLY_GEOIP_URL_BASE}" = "https://raw.githubusercontent.com/v2fly/geoip/release/text" ]
    [ "${FETCH_TIMEOUT}" = "60" ]
}

@test "geo_sources_load uses defaults if sources.env missing" {
    rm "${AMNEZIAWG_GEO_ROOT}/sources.env"
    geo_sources_load
    [ -n "${V2FLY_GEOIP_URL_BASE}" ]
}

@test "geo_lock_acquire succeeds on first call, fails on second call" {
    run geo_lock_acquire
    [ "$status" -eq 0 ]
    [ -f "${AMNEZIAWG_GEO_LOCK}" ]
    run geo_lock_acquire
    [ "$status" -ne 0 ]
    geo_lock_release
    [ ! -f "${AMNEZIAWG_GEO_LOCK}" ]
}

@test "geo_lock stale after pid death is reclaimable" {
    # Fake a stale lock
    echo "999999" > "${AMNEZIAWG_GEO_LOCK}"
    run geo_lock_acquire
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Run — 4 fail (geo.sh stub)**

```bash
bats addon/tests/geo_test.bats 2>&1 | tail -10
```

- [ ] **Step 4: Overwrite `addon/lib/geo.sh` with the skeleton**

```sh
#!/bin/sh
# addon/lib/geo.sh — v2fly GeoIP/GeoSite auto-population.
# Public:
#   geo_sync [--force]       # full fetch + apply
#   geo_list [<cat>]         # list IP+domain entries for a cat
#   geo_categories           # print curated + custom enabled names
#   geo_status               # emit json { last_sync, enabled, errors, ipset_counts }
#   geo_clear [<cat>|--all]  # remove cached files + flush ipsets
#   geo_cron_install         # register awggeosync cron via cru
#   geo_cron_remove          # deregister
# Private helpers prefixed _geo_.

if ! command -v log_info >/dev/null 2>&1; then
    echo "geo.sh: log.sh first" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v state_get >/dev/null 2>&1; then
    echo "geo.sh: state.sh first" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v geo_filter_domain >/dev/null 2>&1; then
    echo "geo.sh: geo_parse.sh first" >&2
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

# -------- sources.env ---------------------------------------------------

geo_sources_load() {
    # Safe-source sources.env; fall back to defaults.
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
    # Echo space-separated list of categories with mode != off.
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
```

Append stubs for the public API functions (filled in later tasks):

```sh
# -------- Stubs filled in later tasks (sync/list/clear/status/cron) -----
geo_sync()         { log_warn "geo_sync: not implemented"; return 1; }
geo_list()         { log_warn "geo_list: not implemented"; return 1; }
geo_categories()   { printf '%s\n' ${GEO_CURATED}; }
geo_status()       { log_warn "geo_status: not implemented"; return 1; }
geo_clear()        { log_warn "geo_clear: not implemented"; return 1; }
geo_cron_install() { log_warn "geo_cron_install: not implemented"; return 1; }
geo_cron_remove()  { log_warn "geo_cron_remove: not implemented"; return 1; }
```

- [ ] **Step 5: Run — 4 pass**

```bash
bats addon/tests/geo_test.bats 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add addon/lib/geo.sh addon/etc/amneziawg/sources.env addon/tests/geo_test.bats
git commit -m "feat(geo): add skeleton — sources.env loader + PID lock + category enumeration"
```

### Task 9: `_geo_fetch_category` — single-category fetch into staging dir

**Files:**
- Modify: `addon/lib/geo.sh`
- Modify: `addon/tests/geo_test.bats`

- [ ] **Step 1: Append failing tests**

```bash

@test "_geo_fetch_category downloads ip+domain and emits dnsmasq.conf" {
    state_set "awg_geo_google_mode" "vpn"
    mkdir -p "${TMPDIR_TEST}/staging/ip" "${TMPDIR_TEST}/staging/domain" "${TMPDIR_TEST}/staging/dnsmasq.d"
    geo_sources_load
    run _geo_fetch_category "google" "${TMPDIR_TEST}/staging"
    [ "$status" -eq 0 ]
    [ -s "${TMPDIR_TEST}/staging/ip/google.txt" ]
    [ -s "${TMPDIR_TEST}/staging/domain/google.txt" ]
    [ -s "${TMPDIR_TEST}/staging/dnsmasq.d/google.conf" ]
    grep -q 'ipset=.*awg_geo_dst' "${TMPDIR_TEST}/staging/dnsmasq.d/google.conf"
    grep -q 'google.com' "${TMPDIR_TEST}/staging/dnsmasq.d/google.conf"
}

@test "_geo_fetch_category routes mode=direct content into awg_geo_direct" {
    state_set "awg_geo_ru_mode" "direct"
    mkdir -p "${TMPDIR_TEST}/staging/ip" "${TMPDIR_TEST}/staging/domain" "${TMPDIR_TEST}/staging/dnsmasq.d"
    geo_sources_load
    run _geo_fetch_category "ru" "${TMPDIR_TEST}/staging"
    [ "$status" -eq 0 ]
    grep -q 'ipset=.*awg_geo_direct' "${TMPDIR_TEST}/staging/dnsmasq.d/ru.conf"
}

@test "_geo_fetch_category returns non-zero and logs on HTTP failure" {
    export MOCK_CURL_FAIL_URLS="/google\.txt$"
    export MOCK_CURL_FAIL_RC=22
    state_set "awg_geo_google_mode" "vpn"
    mkdir -p "${TMPDIR_TEST}/staging/ip" "${TMPDIR_TEST}/staging/domain" "${TMPDIR_TEST}/staging/dnsmasq.d"
    geo_sources_load
    run _geo_fetch_category "google" "${TMPDIR_TEST}/staging"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run — 3 fail**

- [ ] **Step 3: Append `_geo_fetch_category` to `addon/lib/geo.sh`**

Between `geo_category_mode` and the stubs section, insert:

```sh
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

    # IP list
    if ! curl --proto '=https' -fsSL --max-time "${FETCH_TIMEOUT:-60}" --retry "${FETCH_RETRIES:-2}" \
            -o "${_ip_out}" "${_ip_url}"; then
        log_warn "geo: fetch ip failed for ${_cat} (${_ip_url})"
        return 1
    fi

    # Domain list (tolerate absence: some categories are ip-only)
    if curl --proto '=https' -fsSL --max-time "${FETCH_TIMEOUT:-60}" --retry "${FETCH_RETRIES:-2}" \
            -o "${_dom_raw}" "${_dom_url}" 2>/dev/null; then
        # filter + resolve includes (depth 3)
        _src_dir="$(dirname "${_dom_raw}")"
        # Copy raw to a temporary name that matches the include: target convention
        cp "${_dom_raw}" "${_src_dir}/${_cat}"
        geo_filter_domain < "${_src_dir}/${_cat}" | \
            geo_resolve_includes "${_src_dir}" 3 "${_cat}" > "${_dom_out}"
        rm -f "${_dom_raw}" "${_src_dir}/${_cat}"
    else
        : > "${_dom_out}"
    fi

    # dnsmasq.d/<cat>.conf — one ipset=/<d>/<set> per domain
    : > "${_conf_out}"
    if [ -s "${_dom_out}" ]; then
        while IFS= read -r _dom; do
            [ -n "${_dom}" ] || continue
            printf 'ipset=/%s/%s\n' "${_dom}" "${_set}" >> "${_conf_out}"
        done < "${_dom_out}"
    fi
    return 0
}
```

- [ ] **Step 4: Run — 3 pass**

- [ ] **Step 5: Commit**

```bash
git add addon/lib/geo.sh addon/tests/geo_test.bats
git commit -m "feat(geo): add _geo_fetch_category (per-category fetch + dnsmasq.conf emit)"
```

### Task 10: `geo_sync` — parallel fetch + atomic move + cleanup + ipset rebuild

**Files:**
- Modify: `addon/lib/geo.sh`
- Modify: `addon/tests/geo_test.bats`

- [ ] **Step 1: Append failing tests**

```bash

@test "geo_sync happy path: 2 cats enabled, files land, ipsets populated, timestamp written" {
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_ru_mode" "direct"
    state_set "awg_geo_sync_parallel" "2"
    run geo_sync
    [ "$status" -eq 0 ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt" ]
    [ -f "${AMNEZIAWG_GEO_ROOT}/last-sync" ]
    # ipset restore should have populated awg_geo_dst + awg_geo_direct
    grep -q "add awg_geo_dst 8.8.8.0/24" "${TMPDIR_TEST}/ipset.log"
    grep -q "add awg_geo_direct 5.8.0.0/20" "${TMPDIR_TEST}/ipset.log"
}

@test "geo_sync partial failure: ru timeout, google still applied" {
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_ru_mode" "direct"
    export MOCK_CURL_FAIL_URLS="/ru\.txt$"
    export MOCK_CURL_FAIL_RC=28
    run geo_sync
    [ "$status" -eq 0 ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt" ]
    grep -q 'ru' "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log"
}

@test "geo_sync cleanup: disabling cat removes its files" {
    state_set "awg_geo_google_mode" "vpn"
    geo_sync
    [ -s "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    state_set "awg_geo_google_mode" "off"
    geo_sync
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/google.conf" ]
}

@test "geo_sync is a no-op restart_dnsmasq when dnsmasq.d unchanged" {
    state_set "awg_geo_google_mode" "vpn"
    # Stub service() to log calls
    service() { printf '%s\n' "$*" >> "${TMPDIR_TEST}/service.log"; }
    export -f service 2>/dev/null || true
    geo_sync
    _first_count="$(grep -c 'restart_dnsmasq' "${TMPDIR_TEST}/service.log" 2>/dev/null || echo 0)"
    geo_sync
    _second_count="$(grep -c 'restart_dnsmasq' "${TMPDIR_TEST}/service.log" 2>/dev/null || echo 0)"
    [ "${_second_count}" -eq "${_first_count}" ]
}

@test "geo_sync under lock collision exits rc=0 with note" {
    # Hold the lock from a fake pid that is alive (our own shell)
    mkdir -p "$(dirname "${AMNEZIAWG_GEO_LOCK}")"
    echo "$$" > "${AMNEZIAWG_GEO_LOCK}"
    state_set "awg_geo_google_mode" "vpn"
    run geo_sync
    [ "$status" -eq 0 ]
    grep -q 'another sync holds lock' "${AMNEZIAWG_LOG_FILE}"
}
```

- [ ] **Step 2: Run — 5 fail (stub)**

- [ ] **Step 3: Replace the `geo_sync` stub in `addon/lib/geo.sh`**

```sh
geo_sync() {
    _force=0
    if [ "$1" = "--force" ]; then _force=1; fi

    if ! geo_lock_acquire; then
        return 0
    fi
    trap 'geo_lock_release' EXIT INT TERM

    geo_sources_load

    _enabled="$(geo_enabled_categories)"
    if [ -z "${_enabled}" ]; then
        log_info "geo_sync: no enabled categories, skipping"
        _geo_ipsets_rebuild
        geo_lock_release
        trap - EXIT INT TERM
        return 0
    fi

    _parallel="$(state_get awg_geo_sync_parallel)"
    [ -z "${_parallel}" ] && _parallel=3
    case "${_parallel}" in 1|2|3|4|5|6|7|8) : ;; *) _parallel=3 ;; esac

    _stg="${TMPDIR:-/tmp}/amneziawg-geo-staging.$$"
    rm -rf "${_stg}"
    mkdir -p "${_stg}/ip" "${_stg}/domain" "${_stg}/dnsmasq.d"

    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" \
             "${AMNEZIAWG_GEO_ROOT}/domain" \
             "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d"

    : > "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log.tmp"

    _pids=""
    _running=0
    for _cat in ${_enabled}; do
        # Semaphore: cap concurrent background fetches at _parallel
        while [ "${_running}" -ge "${_parallel}" ]; do
            wait -n 2>/dev/null || {
                # busybox wait lacks -n; fall back: wait for the oldest
                _first_pid="${_pids%% *}"
                [ -n "${_first_pid}" ] && wait "${_first_pid}" 2>/dev/null || true
                _pids="${_pids#${_first_pid} }"
            }
            _running=$(( _running - 1 ))
        done
        (
            if ! _geo_fetch_category "${_cat}" "${_stg}"; then
                printf '%s %s\n' "$(date +%s)" "${_cat}" \
                    >> "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log.tmp"
            fi
        ) &
        _pids="${_pids}$! "
        _running=$(( _running + 1 ))
    done
    wait

    # Move successful categories into live root (atomic per-file)
    for _cat in ${_enabled}; do
        if [ -s "${_stg}/ip/${_cat}.txt" ]; then
            mv -f "${_stg}/ip/${_cat}.txt"       "${AMNEZIAWG_GEO_ROOT}/ip/${_cat}.txt"
            mv -f "${_stg}/domain/${_cat}.txt"   "${AMNEZIAWG_GEO_ROOT}/domain/${_cat}.txt"   2>/dev/null || true
            mv -f "${_stg}/dnsmasq.d/${_cat}.conf" "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/${_cat}.conf" 2>/dev/null || true
        fi
    done

    # Cleanup pass: drop files for disabled categories
    _geo_cleanup_disabled "${_enabled}"

    # Hash-compare dnsmasq.d/ → conditionally restart_dnsmasq
    _geo_dnsmasq_reload_if_changed "${_force}"

    # Rebuild ipsets from all ip/*.txt + manual entries
    _geo_ipsets_rebuild

    # Rotate errors log
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
        case " ${_keep} " in *" ${_cat} "*) ;; *)
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
    # Emit a single ipset restore script:
    #   - destroy + create both sets
    #   - add all entries from ip/*.txt (routed by category mode)
    #   - add manual entries awg_geo_entries → VPN set,
    #                        awg_geo_entries_direct → DIRECT set.
    _tmp="$(mktemp)"
    {
        printf 'destroy %s\n' "${GEO_IPSET_VPN}"
        printf 'destroy %s\n' "${GEO_IPSET_DIRECT}"
    } 2>/dev/null | ipset restore -! 2>/dev/null || true

    {
        printf 'create %s hash:net family inet maxelem 65536 -exist\n' "${GEO_IPSET_VPN}"
        printf 'create %s hash:net family inet maxelem 65536 -exist\n' "${GEO_IPSET_DIRECT}"
        printf 'flush %s\n' "${GEO_IPSET_VPN}"
        printf 'flush %s\n' "${GEO_IPSET_DIRECT}"

        for _f in "${AMNEZIAWG_GEO_ROOT}/ip/"*.txt; do
            [ -s "${_f}" ] || continue
            _cat="$(basename "${_f}" .txt)"
            _m="$(geo_category_mode "${_cat}")"
            [ "${_m}" = "off" ] && continue
            _set="${GEO_IPSET_VPN}"
            [ "${_m}" = "direct" ] && _set="${GEO_IPSET_DIRECT}"
            while IFS= read -r _cidr; do
                [ -n "${_cidr}" ] || continue
                case "${_cidr}" in '#'*|' '*|'') continue ;; esac
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
```

Note: busybox `wait -n` is not always available. The fallback in the semaphore loop handles that by waiting for the first PID in the list.

- [ ] **Step 4: Run tests**

```bash
bats addon/tests/geo_test.bats 2>&1 | tail -10
```
All 5 new tests must pass.

- [ ] **Step 5: Commit**

```bash
git add addon/lib/geo.sh addon/tests/geo_test.bats
git commit -m "feat(geo): implement geo_sync with parallel fetch + atomic replace + hash-compare reload"
```

### Task 11: `geo_list`, `geo_status`, `geo_clear`, `geo_categories`

**Files:**
- Modify: `addon/lib/geo.sh`
- Modify: `addon/tests/geo_test.bats`

- [ ] **Step 1: Append failing tests**

```bash

@test "geo_categories prints curated + enabled custom" {
    state_set "awg_geo_categories_custom" "custom-a,custom-b"
    run geo_categories
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^google$'
    echo "$output" | grep -q '^custom-a$'
}

@test "geo_list with arg prints ip+domain for that cat" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" "${AMNEZIAWG_GEO_ROOT}/domain"
    echo "1.2.3.0/24" > "${AMNEZIAWG_GEO_ROOT}/ip/foo.txt"
    echo "foo.com"    > "${AMNEZIAWG_GEO_ROOT}/domain/foo.txt"
    run geo_list foo
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '1.2.3.0/24'
    echo "$output" | grep -q 'foo.com'
}

@test "geo_list (no arg) prints enabled cats" {
    state_set "awg_geo_google_mode" "vpn"
    state_set "awg_geo_ru_mode" "direct"
    run geo_list
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^google$'
    echo "$output" | grep -q '^ru$'
}

@test "geo_status emits JSON with last_sync, enabled, errors" {
    state_set "awg_geo_google_mode" "vpn"
    echo "1729550000" > "${AMNEZIAWG_GEO_ROOT}/last-sync"
    echo "1729550001 ru" > "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log"
    run geo_status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"last_sync":1729550000'
    echo "$output" | grep -q '"enabled":\["google"\]'
    echo "$output" | grep -q '"errors":\[.*"ru".*\]'
}

@test "geo_clear --all removes all category files + flushes ipsets" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" "${AMNEZIAWG_GEO_ROOT}/domain" "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d"
    touch "${AMNEZIAWG_GEO_ROOT}/ip/google.txt"
    touch "${AMNEZIAWG_GEO_ROOT}/domain/google.txt"
    touch "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/google.conf"
    run geo_clear --all
    [ "$status" -eq 0 ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    grep -q "flush ${GEO_IPSET_VPN}" "${TMPDIR_TEST}/ipset.log"
}

@test "geo_clear <cat> removes only that category" {
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/ip" "${AMNEZIAWG_GEO_ROOT}/domain" "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d"
    touch "${AMNEZIAWG_GEO_ROOT}/ip/google.txt"
    touch "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt"
    run geo_clear google
    [ "$status" -eq 0 ]
    [ ! -f "${AMNEZIAWG_GEO_ROOT}/ip/google.txt" ]
    [ -f "${AMNEZIAWG_GEO_ROOT}/ip/ru.txt" ]
}
```

- [ ] **Step 2: Run — 6 fail**

- [ ] **Step 3: Replace stubs in `addon/lib/geo.sh`**

Replace the 5 `geo_*` stubs at the bottom with full implementations:

```sh
geo_categories() {
    for _cat in ${GEO_CURATED}; do printf '%s\n' "${_cat}"; done
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
}

geo_status() {
    _ls=0
    [ -f "${AMNEZIAWG_GEO_ROOT}/last-sync" ] && _ls="$(cat "${AMNEZIAWG_GEO_ROOT}/last-sync")"
    _enabled_csv=""
    for _cat in $(geo_enabled_categories); do
        [ -z "${_enabled_csv}" ] && _enabled_csv="\"${_cat}\"" \
            || _enabled_csv="${_enabled_csv},\"${_cat}\""
    done
    _errs_csv=""
    if [ -f "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log" ]; then
        while IFS=' ' read -r _ts _c; do
            [ -n "${_c}" ] || continue
            [ -z "${_errs_csv}" ] && _errs_csv="\"${_c}\"" \
                || _errs_csv="${_errs_csv},\"${_c}\""
        done < "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log"
    fi
    printf '{"last_sync":%s,"enabled":[%s],"errors":[%s]}\n' \
        "${_ls}" "${_enabled_csv}" "${_errs_csv}"
}

geo_clear() {
    _target="$1"
    if [ "${_target}" = "--all" ] || [ -z "${_target}" ]; then
        rm -rf "${AMNEZIAWG_GEO_ROOT}/ip/"*.txt \
               "${AMNEZIAWG_GEO_ROOT}/domain/"*.txt \
               "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/"*.conf \
               "${AMNEZIAWG_GEO_ROOT}/last-sync" \
               "${AMNEZIAWG_GEO_ROOT}/fetch-errors.log" \
               "${AMNEZIAWG_GEO_ROOT}/.dnsmasq-hash" 2>/dev/null
        {
            printf 'flush %s\n' "${GEO_IPSET_VPN}"
            printf 'flush %s\n' "${GEO_IPSET_DIRECT}"
        } | ipset restore -! 2>/dev/null || true
    else
        rm -f "${AMNEZIAWG_GEO_ROOT}/ip/${_target}.txt" \
              "${AMNEZIAWG_GEO_ROOT}/domain/${_target}.txt" \
              "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/${_target}.conf"
    fi
}
```

- [ ] **Step 4: Run — 6 pass**

- [ ] **Step 5: Commit**

```bash
git add addon/lib/geo.sh addon/tests/geo_test.bats
git commit -m "feat(geo): implement geo_categories, geo_list, geo_status, geo_clear"
```

### Task 12: `geo_cron_install` / `geo_cron_remove`

**Files:**
- Modify: `addon/lib/geo.sh`
- Modify: `addon/tests/geo_test.bats`

- [ ] **Step 1: Append failing tests**

```bash

@test "geo_cron_install registers cron with cru using state schedule" {
    state_set "awg_geo_sync_weekday" "1"
    state_set "awg_geo_sync_hour" "5"
    run geo_cron_install
    [ "$status" -eq 0 ]
    grep -q "^a ${AMNEZIAWG_GEO_CRON_ID} 0 5 \* \* 1" "${MOCK_CRU_LOG}"
}

@test "geo_cron_install uses defaults when state unset (Sun 04:00)" {
    run geo_cron_install
    [ "$status" -eq 0 ]
    grep -q "^a ${AMNEZIAWG_GEO_CRON_ID} 0 4 \* \* 0" "${MOCK_CRU_LOG}"
}

@test "geo_cron_remove calls cru with 'd'" {
    run geo_cron_remove
    [ "$status" -eq 0 ]
    grep -q "^d ${AMNEZIAWG_GEO_CRON_ID}" "${MOCK_CRU_LOG}"
}
```

- [ ] **Step 2: Run — 3 fail**

- [ ] **Step 3: Replace `geo_cron_*` stubs**

```sh
geo_cron_install() {
    _wd="$(state_get awg_geo_sync_weekday)"
    _hr="$(state_get awg_geo_sync_hour)"
    [ -z "${_wd}" ] && _wd=0
    [ -z "${_hr}" ] && _hr=4
    cru a "${AMNEZIAWG_GEO_CRON_ID}" "0 ${_hr} * * ${_wd} ${AMNEZIAWG_GEO_CRON_CMD}" || \
        log_warn "geo_cron_install: cru unavailable"
}

geo_cron_remove() {
    cru d "${AMNEZIAWG_GEO_CRON_ID}" 2>/dev/null || true
}
```

- [ ] **Step 4: Run — 3 pass**

- [ ] **Step 5: Commit**

```bash
git add addon/lib/geo.sh addon/tests/geo_test.bats
git commit -m "feat(geo): implement geo_cron_install + geo_cron_remove via cru"
```

---

## Phase 6 — Dispatcher & install integration

### Task 13: `amneziawg.sh geo` subcommand + `start_awggeosync` hook

**Files:**
- Modify: `addon/amneziawg.sh`

- [ ] **Step 1: Inspect existing dispatcher layout**

```bash
grep -n '^    pbr)\|^    import)\|start_awg\|case "$1"' addon/amneziawg.sh | head -20
```

- [ ] **Step 2: Add `geo` subcommand to the top-level dispatcher in `addon/amneziawg.sh`**

Locate the big `case "$1"` (or `case "${_cmd}"`) block that dispatches `start|stop|restart|reload|status|watchdog|import|pbr`. Add a new arm **before** the final `*)` default:

```sh
    geo)
        shift
        . "${_AWG_LIB}/log.sh"
        . "${_AWG_LIB}/state.sh"
        . "${_AWG_LIB}/geo_parse.sh"
        . "${_AWG_LIB}/geo.sh"
        case "$1" in
            sync)       shift; geo_sync "$@" ;;
            list)       shift; geo_list "$@" ;;
            categories) shift; geo_categories ;;
            status)     shift; geo_status ;;
            clear)      shift; geo_clear "$@" ;;
            *)          echo "usage: $0 geo {sync|list|categories|status|clear}" >&2; exit 2 ;;
        esac
        ;;
```

Replace `_AWG_LIB` with whatever the existing file uses (check via `grep -n '_AWG_LIB\|addon/lib' addon/amneziawg.sh | head -5`).

- [ ] **Step 3: Add `start_awggeosync` service-event hook**

Locate the service-event handler (search for `start_awg|service-event|notify_rc`). The handler already dispatches `start_awgtunnel` etc. Add:

```sh
    start_awggeosync|restart_awggeosync)
        . "${_AWG_LIB}/log.sh"
        . "${_AWG_LIB}/state.sh"
        . "${_AWG_LIB}/geo_parse.sh"
        . "${_AWG_LIB}/geo.sh"
        geo_sync
        ;;
```

- [ ] **Step 4: Smoke-test manually**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bash -n addon/amneziawg.sh && echo "syntax ok"
./addon/amneziawg.sh geo categories 2>/dev/null | head -3
```
Expected: `syntax ok`; `geo categories` prints at least `google`, `youtube`, `netflix`.

- [ ] **Step 5: Commit**

```bash
git add addon/amneziawg.sh
git commit -m "feat(amneziawg): add 'geo' subcommand + start_awggeosync service hook"
```

### Task 14: `install_run` creates `/opt/etc/amneziawg/geo/`, copies `sources.env`, registers cron

**Files:**
- Modify: `addon/lib/install.sh`
- Modify: `addon/tests/*` (if there's an install test suite)

- [ ] **Step 1: Check if an install test exists**

```bash
ls addon/tests/install_test.bats 2>/dev/null && echo "exists" || echo "missing"
```

If present, extend it; otherwise create one.

- [ ] **Step 2: Create or extend install tests (`addon/tests/install_test.bats`)**

Append (or create with the full setup from `geo_test.bats`):

```bash

@test "install_run creates /opt/etc/amneziawg/geo tree and copies sources.env" {
    # Harness: AMNEZIAWG_ADDON_DIR points to an addon mock with etc/amneziawg/sources.env
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/opt/etc/amneziawg/geo"
    mkdir -p "${TMPDIR_TEST}/addon_mock/etc/amneziawg"
    cp "${BATS_TEST_DIRNAME}/../etc/amneziawg/sources.env" \
       "${TMPDIR_TEST}/addon_mock/etc/amneziawg/sources.env"
    export AMNEZIAWG_ADDON_DIR="${TMPDIR_TEST}/addon_mock"

    install_run
    [ -d "${AMNEZIAWG_GEO_ROOT}/ip" ]
    [ -d "${AMNEZIAWG_GEO_ROOT}/domain" ]
    [ -d "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d" ]
    [ -s "${AMNEZIAWG_GEO_ROOT}/sources.env" ]
    grep -q "V2FLY_GEOIP_URL_BASE" "${AMNEZIAWG_GEO_ROOT}/sources.env"
}

@test "install_run registers awggeosync cron" {
    install_run
    grep -q "^a ${AMNEZIAWG_GEO_CRON_ID}" "${MOCK_CRU_LOG}"
}

@test "uninstall_run deregisters awggeosync cron" {
    install_run
    uninstall_run
    grep -q "^d ${AMNEZIAWG_GEO_CRON_ID}" "${MOCK_CRU_LOG}"
}
```

- [ ] **Step 3: Run — 3 fail**

- [ ] **Step 4: Modify `addon/lib/install.sh`**

Inside `install_run()`, after existing hook installation, insert:

```sh
    log_info "install_run: initialising geo state"
    _geo_root="${AMNEZIAWG_GEO_ROOT:-/opt/etc/amneziawg/geo}"
    mkdir -p "${_geo_root}/ip" "${_geo_root}/domain" "${_geo_root}/dnsmasq.d"
    _src="${AMNEZIAWG_ADDON_DIR:-/jffs/addons/amneziawg}/etc/amneziawg/sources.env"
    if [ -f "${_src}" ] && [ ! -f "${_geo_root}/sources.env" ]; then
        cp "${_src}" "${_geo_root}/sources.env"
    fi

    log_info "install_run: registering geo sync cron"
    if command -v geo_cron_install >/dev/null 2>&1; then
        geo_cron_install
    else
        . "${AMNEZIAWG_ADDON_DIR:-/jffs/addons/amneziawg}/lib/geo.sh" 2>/dev/null && geo_cron_install
    fi
```

Inside `uninstall_run()`, before hook removal:

```sh
    log_info "uninstall_run: removing geo sync cron"
    if command -v geo_cron_remove >/dev/null 2>&1; then
        geo_cron_remove
    else
        . "${AMNEZIAWG_ADDON_DIR:-/jffs/addons/amneziawg}/lib/geo.sh" 2>/dev/null && geo_cron_remove
    fi
```

- [ ] **Step 5: Run — 3 pass**

- [ ] **Step 6: Commit**

```bash
git add addon/lib/install.sh addon/tests/install_test.bats
git commit -m "feat(install): create geo state tree + install cron on install, reverse on uninstall"
```

---

## Phase 7 — DNS + status integration

### Task 15: DNS postconf concat + status JSON geo extension

**Files:**
- Modify: `addon/lib/dns.sh`
- Modify: `addon/lib/status.sh`
- Modify: `addon/tests/dns_test.bats`
- Modify: `addon/tests/status_test.bats`

- [ ] **Step 1: Append failing test to `addon/tests/dns_test.bats`**

```bash

@test "dns_dnsmasq_postconf_generate concatenates geo/dnsmasq.d/*.conf" {
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/geo"
    mkdir -p "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d"
    printf 'ipset=/google.com/awg_geo_dst\n'   > "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/google.conf"
    printf 'ipset=/yandex.ru/awg_geo_direct\n' > "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/ru.conf"
    dns_dnsmasq_postconf_generate
    grep -q 'ipset=/google.com/awg_geo_dst'   "${AMNEZIAWG_DNSMASQ_CONF}"
    grep -q 'ipset=/yandex.ru/awg_geo_direct' "${AMNEZIAWG_DNSMASQ_CONF}"
}
```

- [ ] **Step 2: Append failing test to `addon/tests/status_test.bats`**

```bash

@test "status_emit_json includes geo{} with last_sync and enabled" {
    export AMNEZIAWG_GEO_ROOT="${TMPDIR_TEST}/geo"
    mkdir -p "${AMNEZIAWG_GEO_ROOT}"
    echo "1729550000" > "${AMNEZIAWG_GEO_ROOT}/last-sync"
    state_set "awg_geo_google_mode" "vpn"
    status_emit_json
    grep -q '"geo":{' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"last_sync":1729550000' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"enabled":\["google"\]' "${AMNEZIAWG_RUNTIME}/status.json"
}
```

- [ ] **Step 3: Run — 2 fail**

- [ ] **Step 4: Modify `addon/lib/dns.sh` `dns_dnsmasq_postconf_generate`**

Find the function (around line 64). Identify where it writes to `AMNEZIAWG_DNSMASQ_CONF`. After the existing postconf body is written, append a concat step:

```sh
    : "${AMNEZIAWG_GEO_ROOT:=/opt/etc/amneziawg/geo}"
    if [ -d "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d" ]; then
        for _conf in "${AMNEZIAWG_GEO_ROOT}/dnsmasq.d/"*.conf; do
            [ -f "${_conf}" ] || continue
            cat "${_conf}" >> "${AMNEZIAWG_DNSMASQ_CONF}"
        done
    fi
```

- [ ] **Step 5: Modify `addon/lib/status.sh` `status_emit_json`**

Near the top of the function (alongside `_enabled`, `_leases_json` etc.), add:

```sh
    _geo_last=0
    _geo_enabled_csv=""
    : "${AMNEZIAWG_GEO_ROOT:=/opt/etc/amneziawg/geo}"
    [ -f "${AMNEZIAWG_GEO_ROOT}/last-sync" ] && \
        _geo_last="$(cat "${AMNEZIAWG_GEO_ROOT}/last-sync" 2>/dev/null)"
    [ -z "${_geo_last}" ] && _geo_last=0

    # Enumerate enabled categories (inline; avoid circular source of geo.sh)
    _curated="google youtube netflix telegram cloudflare github discord twitter meta tiktok cn ru by ua private tor"
    _custom="$(state_get awg_geo_categories_custom 2>/dev/null | tr ',' ' ')"
    for _cat in ${_curated} ${_custom}; do
        [ -z "${_cat}" ] && continue
        _m="$(state_get "awg_geo_${_cat}_mode" 2>/dev/null)"
        if [ -n "${_m}" ] && [ "${_m}" != "off" ]; then
            [ -z "${_geo_enabled_csv}" ] && _geo_enabled_csv="\"${_cat}\"" \
                || _geo_enabled_csv="${_geo_enabled_csv},\"${_cat}\""
        fi
    done
```

Then in the JSON emission section (look for the printf that assembles the output), add a `geo` field before the closing `}`:

```sh
    printf ',"geo":{"last_sync":%s,"enabled":[%s]}' \
        "${_geo_last}" "${_geo_enabled_csv}" >> "${_tmp}"
```

Place it adjacent to the existing fields (e.g., after `killswitch_armed`). Make sure the bracketing remains valid JSON.

- [ ] **Step 6: Run — 2 pass**

```bash
bats addon/tests/dns_test.bats addon/tests/status_test.bats 2>&1 | tail -5
```

- [ ] **Step 7: Commit**

```bash
git add addon/lib/dns.sh addon/lib/status.sh addon/tests/dns_test.bats addon/tests/status_test.bats
git commit -m "feat(dns,status): concat geo/dnsmasq.d into postconf; expose geo{} in status JSON"
```

---

## Phase 8 — WebUI

### Task 16: `AWG.geo` IIFE module + rendering helpers

**Files:**
- Modify: `addon/webui/amneziawg.js`
- Create: `addon/webui/tests/geo.test.js`

- [ ] **Step 1: Create `addon/webui/tests/geo.test.js`**

```javascript
// addon/webui/tests/geo.test.js — unit tests for AWG.geo helpers + AWG.validator mode enum.
const { test } = require('node:test');
const assert = require('node:assert');
const { loadWindow } = require('./helpers.js');

test('AWG.geo.CURATED has 16 fixed categories', () => {
    const w = loadWindow();
    assert.strictEqual(w.AWG.geo.CURATED.length, 16);
    assert.ok(w.AWG.geo.CURATED.includes('google'));
    assert.ok(w.AWG.geo.CURATED.includes('ru'));
});

test('AWG.geo.modeToIpset routes modes to correct ipsets', () => {
    const w = loadWindow();
    assert.strictEqual(w.AWG.geo.modeToIpset('vpn'),    'awg_geo_dst');
    assert.strictEqual(w.AWG.geo.modeToIpset('direct'), 'awg_geo_direct');
    assert.strictEqual(w.AWG.geo.modeToIpset('off'),    null);
});

test('AWG.geo.modeKey builds state key name', () => {
    const w = loadWindow();
    assert.strictEqual(w.AWG.geo.modeKey('ru'),     'awg_geo_ru_mode');
    assert.strictEqual(w.AWG.geo.modeKey('google'), 'awg_geo_google_mode');
});

test('AWG.validator accepts vpn_except_geo policy', () => {
    const w = loadWindow();
    assert.ok(w.AWG.validator.validatePolicy('vpn_except_geo'));
    assert.ok(w.AWG.validator.validatePolicy('vpn_all'));
    assert.ok(w.AWG.validator.validatePolicy('direct'));
});

test('AWG.validator rejects unknown mode/policy', () => {
    const w = loadWindow();
    assert.ok(!w.AWG.validator.validateGeoMode('bypass'));
    assert.ok(w.AWG.validator.validateGeoMode('off'));
    assert.ok(w.AWG.validator.validateGeoMode('vpn'));
    assert.ok(w.AWG.validator.validateGeoMode('direct'));
    assert.ok(!w.AWG.validator.validatePolicy('whatever'));
});
```

- [ ] **Step 2: Run — 5 fail**

```bash
bash addon/webui/tests/run.sh 2>&1 | tail -10
```

- [ ] **Step 3: Add `AWG.geo` module to `addon/webui/amneziawg.js`**

Inside the file, after `AWG.pbr` IIFE and before `AWG.import`, append:

```javascript
// ============================================================
// AWG.geo — GeoIP/GeoSite category management
// ============================================================
AWG.geo = (function() {
    var CURATED = [
        'google','youtube','netflix','telegram','cloudflare','github',
        'discord','twitter','meta','tiktok','cn','ru','by','ua',
        'private','tor'
    ];
    var MODES = ['off', 'vpn', 'direct'];

    function modeKey(cat)        { return 'awg_geo_' + cat + '_mode'; }
    function modeToIpset(mode)   {
        if (mode === 'vpn')    return 'awg_geo_dst';
        if (mode === 'direct') return 'awg_geo_direct';
        return null;
    }
    function categoryMode(state, cat) {
        var v = state[modeKey(cat)];
        return (v === 'vpn' || v === 'direct') ? v : 'off';
    }

    function renderCategoryRow(state, cat) {
        // Returns a <tr> element: [name] [mode-select]
        var tr = document.createElement('tr');
        var tdName = document.createElement('td');
        tdName.textContent = cat;
        var tdMode = document.createElement('td');
        var sel = document.createElement('select');
        sel.name = modeKey(cat);
        sel.className = 'awg-geo-mode';
        MODES.forEach(function(m) {
            var opt = document.createElement('option');
            opt.value = m;
            opt.textContent = m;
            if (categoryMode(state, cat) === m) opt.selected = true;
            sel.appendChild(opt);
        });
        tdMode.appendChild(sel);
        tr.appendChild(tdName);
        tr.appendChild(tdMode);
        return tr;
    }

    function renderAll(tbody, state) {
        while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
        CURATED.forEach(function(cat) {
            tbody.appendChild(renderCategoryRow(state, cat));
        });
        var custom = (state.awg_geo_categories_custom || '')
            .split(',').map(function(s){return s.trim();}).filter(Boolean);
        custom.forEach(function(cat) {
            tbody.appendChild(renderCategoryRow(state, cat));
        });
    }

    function syncNow(onResult) {
        // POST start_awggeosync via Merlin convention.
        var form = new FormData();
        form.append('action_mode', ' Restart ');
        form.append('action_script', 'start_awggeosync');
        fetch('/apply.cgi', { method: 'POST', body: form, credentials: 'same-origin' })
            .then(function(r) { onResult(r.ok, null); })
            .catch(function(e) { onResult(false, String(e)); });
    }

    function renderStatus(el, geoJson) {
        // geoJson shape: { last_sync, enabled: [...], errors: [...] }
        if (!geoJson) { el.textContent = 'n/a'; return; }
        var parts = [];
        if (geoJson.last_sync && geoJson.last_sync > 0) {
            parts.push('last sync: ' + new Date(geoJson.last_sync * 1000).toISOString());
        } else {
            parts.push('last sync: never');
        }
        parts.push('enabled: ' + (geoJson.enabled || []).length);
        if (geoJson.errors && geoJson.errors.length > 0) {
            parts.push('errors: ' + geoJson.errors.join(', '));
        }
        el.textContent = parts.join(' · ');
    }

    return {
        CURATED:       CURATED,
        MODES:         MODES,
        modeKey:       modeKey,
        modeToIpset:   modeToIpset,
        categoryMode:  categoryMode,
        renderCategoryRow: renderCategoryRow,
        renderAll:     renderAll,
        syncNow:       syncNow,
        renderStatus:  renderStatus
    };
})();
```

- [ ] **Step 4: Update `AWG.validator` in `addon/webui/amneziawg.js`**

Find the `AWG.validator` IIFE. Add `validatePolicy` and `validateGeoMode` to the returned object:

```javascript
    function validatePolicy(p) {
        return p === 'vpn_all' || p === 'vpn_geo'
            || p === 'vpn_except_geo' || p === 'direct';
    }
    function validateGeoMode(m) {
        return m === 'off' || m === 'vpn' || m === 'direct';
    }
```

And add them to the return object.

- [ ] **Step 5: Run — 5 pass**

```bash
bash addon/webui/tests/run.sh 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add addon/webui/amneziawg.js addon/webui/tests/geo.test.js
git commit -m "feat(webui): add AWG.geo module + validator mode/policy enums"
```

### Task 17: `AWG.pbr` accepts `vpn_except_geo` option in device table

**Files:**
- Modify: `addon/webui/amneziawg.js`
- Modify: `addon/webui/tests/parser.test.js` or a new ad-hoc test

- [ ] **Step 1: Find `AWG.pbr` policy options**

```bash
grep -n "vpn_all\|vpn_geo\|policySelect\|policies" addon/webui/amneziawg.js | head -10
```

- [ ] **Step 2: Edit the policy list inside `AWG.pbr`**

Find the array like:

```javascript
var POLICIES = ['vpn_all', 'vpn_geo', 'direct'];
```

Replace with:

```javascript
var POLICIES = ['vpn_all', 'vpn_geo', 'vpn_except_geo', 'direct'];
```

If the policy select is built dynamically, verify it's driven by this list. Otherwise, locate each hard-coded `<option>` and extend.

- [ ] **Step 3: Append a test to `addon/webui/tests/geo.test.js`**

```javascript
test('AWG.pbr.POLICIES contains vpn_except_geo in declared order', () => {
    const w = loadWindow();
    assert.ok(w.AWG.pbr.POLICIES);
    assert.deepStrictEqual(w.AWG.pbr.POLICIES,
        ['vpn_all','vpn_geo','vpn_except_geo','direct']);
});
```

Ensure `AWG.pbr` exposes `POLICIES` on its return object (add if missing).

- [ ] **Step 4: Run — passes**

```bash
bash addon/webui/tests/run.sh 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add addon/webui/amneziawg.js addon/webui/tests/geo.test.js
git commit -m "feat(webui): expose vpn_except_geo policy in AWG.pbr"
```

### Task 18: New "GeoIP" fieldset in `amneziawg_page.asp` + CSS

**Files:**
- Modify: `addon/webui/amneziawg_page.asp`
- Modify: `addon/webui/amneziawg.css`

- [ ] **Step 1: Add fieldset to `addon/webui/amneziawg_page.asp`**

Locate the existing section-7 `</fieldset>` (the PBR fieldset). After it, insert:

```html
<fieldset>
  <legend>GeoIP / GeoSite</legend>

  <div class="awg-row">
    <label>Category modes</label>
    <table class="awg-geo-table" id="awg-geo-table">
      <thead><tr><th>Category</th><th>Mode</th></tr></thead>
      <tbody></tbody>
    </table>
  </div>

  <div class="awg-row">
    <label for="awg_geo_entries">Manual VPN CIDRs (one per line or comma)</label>
    <textarea id="awg_geo_entries" name="awg_geo_entries" rows="3"></textarea>
  </div>

  <div class="awg-row">
    <label for="awg_geo_entries_direct">Manual Direct CIDRs (bypass VPN)</label>
    <textarea id="awg_geo_entries_direct" name="awg_geo_entries_direct" rows="3"></textarea>
  </div>

  <div class="awg-row">
    <label for="awg_geo_categories_custom">Custom categories (comma-separated)</label>
    <input id="awg_geo_categories_custom" name="awg_geo_categories_custom" type="text" />
  </div>

  <div class="awg-row">
    <button type="button" id="awg-geo-sync-btn">Sync now</button>
    <span id="awg-geo-status"></span>
  </div>
</fieldset>
```

- [ ] **Step 2: Wire the fieldset from `AWG.init` (in `amneziawg.js`)**

Locate `AWG.init`. In the `DOMContentLoaded` callback, after PBR setup, add:

```javascript
    var geoTbody = document.querySelector('#awg-geo-table tbody');
    if (geoTbody) {
        AWG.geo.renderAll(geoTbody, AWG.config.current());
    }
    var geoBtn = document.getElementById('awg-geo-sync-btn');
    var geoStatus = document.getElementById('awg-geo-status');
    if (geoBtn) {
        geoBtn.addEventListener('click', function() {
            geoBtn.disabled = true;
            geoStatus.textContent = 'syncing…';
            AWG.geo.syncNow(function(ok, err) {
                geoBtn.disabled = false;
                geoStatus.textContent = ok ? 'sync started' : ('error: ' + (err || 'unknown'));
            });
        });
    }
```

Also ensure `AWG.status.poll` is extended to render geo status. Find where `AWG.status` renders other widgets (or the callback that consumes JSON) and add:

```javascript
    if (status.geo && geoStatus) {
        AWG.geo.renderStatus(geoStatus, status.geo);
    }
```

- [ ] **Step 3: Extend `addon/webui/amneziawg.css`**

Append:

```css
.awg-geo-table { border-collapse: collapse; margin-top: 4px; }
.awg-geo-table th, .awg-geo-table td { padding: 2px 8px; border: 1px solid #444; }
.awg-geo-table .awg-geo-mode { padding: 1px 4px; }
#awg-geo-status { margin-left: 12px; color: #ccc; font-size: 0.9em; }
```

- [ ] **Step 4: Lint ASP + smoke-test**

```bash
python3 build/ci/lint_asp.py addon/webui/amneziawg_page.asp
```
Expected: no violations.

```bash
bash addon/webui/tests/run.sh 2>&1 | tail -5
```
Expected: all node tests pass.

- [ ] **Step 5: Commit**

```bash
git add addon/webui/amneziawg_page.asp addon/webui/amneziawg.js addon/webui/amneziawg.css
git commit -m "feat(webui): add GeoIP fieldset with category modes + manual lists + sync button"
```

---

## Phase 9 — Release prep

### Task 19: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Insert M5 section under Unreleased**

Open `CHANGELOG.md`. Under the `## [Unreleased]` section, add:

```markdown
### Features

- GeoIP/GeoSite auto-population driven by v2fly public text lists
  (`v2fly/geoip` + `v2fly/domain-list-community`). 16 curated categories
  (google, youtube, netflix, telegram, cloudflare, github, discord,
  twitter, meta, tiktok, cn, ru, by, ua, private, tor) plus arbitrary
  user-defined categories.
- Per-category `mode` setting: `off` (disabled), `vpn` (contents land
  in `awg_geo_dst`), `direct` (contents land in `awg_geo_direct`).
  Manual CIDR lists for both pools remain editable via
  `awg_geo_entries` (VPN) and `awg_geo_entries_direct` (bypass).
- New PBR policy `vpn_except_geo` — device routes everything through
  the VPN *except* destinations matched by `awg_geo_direct` (inverse of
  `vpn_geo`). Enables "all sites via VPN, RU via direct" scenarios.
- Weekly sync via `cru` cron (`awggeosync`, default Sun 04:00), plus
  on-demand WebUI "Sync now" button. Parallel curl fetches (default
  N=3, tunable via `awg_geo_sync_parallel`).
- Per-category atomic file replace: one failed fetch never corrupts
  last-known-good data for other categories. `fetch-errors.log`
  records per-category failures.
- `dnsmasq.d/<cat>.conf` generation emits `ipset=/<domain>/awg_geo_dst`
  (or `awg_geo_direct`) per category. `dnsmasq.postconf` concatenates
  them. Domain list filters drop unsupported `regexp:` prefixes; `include:`
  directives resolve recursively (depth ≤ 3, cycle-guarded).
- PID lock (`/tmp/amneziawg/geo.lock`) coalesces concurrent cron+WebUI
  sync calls.
- `amneziawg.sh geo {sync|list|categories|status|clear}` CLI.
- `awg_geo_dst` ipset type migrated from `hash:ip` → `hash:net` so that
  CIDR ranges are stored natively (fixes v1's implicit /32 expansion).

### Build

- Module 5 — GeoIP/v2fly (see
  `docs/superpowers/specs/2026-04-20-module-5-geoip-design.md`).
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): document Module 5 (GeoIP + vpn_except_geo)"
```

### Task 20: Full green run + size check

**Files:** none modified.

- [ ] **Step 1: Full test suite**

```bash
cd /Users/r00t/Desktop/AmneziaGo
make test 2>&1 | tail -30
```
Expected: all bats pass (≈205 prior + 33 new = ~238), all Node tests pass (≈21 prior + 5 new = ~26).

- [ ] **Step 2: Full cross-arch build**

```bash
make build-all 2>&1 | tail -20
```
Expected: both `dist/aarch64/*.ipk` and `dist/armv7/*.ipk` present.

- [ ] **Step 3: Size check**

```bash
make check-size
ls -la dist/aarch64/*.ipk
```
Expected: `amneziawg-merlin-addon_*.ipk` ≤ 200 KB (target ~45-50 KB after M5).

- [ ] **Step 4: Lint all**

```bash
make lint 2>&1 | tail -10
```
Expected: no shellcheck errors, no yamllint errors, `lint_asp.py` green.

- [ ] **Step 5: Final commit if any doc/lint tweaks**

If nothing to commit, skip. Otherwise:

```bash
git add -A
git commit -m "chore(m5): final polish after full-run verification"
```

---

## Self-review checklist

| Spec requirement | Task covering it |
|---|---|
| v2fly source (decision #1) | Task 8 `sources.env`, Task 9 `_geo_fetch_category` |
| 16 curated categories (#2) | Task 8 `GEO_CURATED` constant |
| Weekly cron + Sync now (#3) | Task 12 `geo_cron_install`, Task 18 WebUI button |
| dnsmasq ipset=/ directive (#4) | Task 9 dnsmasq.conf emit, Task 15 postconf concat |
| Per-category mode routing (#5) | Task 1 validator, Task 9 routing, Task 10 ipsets rebuild |
| TLS + graceful fallback (#6) | Task 9 curl flags, Task 10 per-cat atomic |
| 4th policy vpn_except_geo (#7) | Task 2 + Task 3 PBR rules |
| Parallelism N=3 (#8) | Task 10 semaphore |
| include: depth=3 + cycle (#9) | Task 6 `geo_resolve_includes` |
| Filter regexp:/domain:/full: (#10) | Task 5 `geo_filter_domain` |
| On-disk layout (§3.1) | Task 14 install creates dirs, Task 10 populates |
| State schema (§3.2) | Task 1 validators |
| `awg_geo_dst` hash:net migration | Task 2 |
| `awg_geo_direct` ipset (§3.3) | Task 2 |
| Sync flow with staging (§3.4) | Task 10 |
| `sources.env` pinning (§3.5) | Task 8 |
| `addon/lib/geo.sh` subcommands (§5.1) | Tasks 8-12 |
| `start_awggeosync` hook (§5.2) | Task 13 |
| bats: geo/geo_parse/pbr_except_geo (§6.1) | Tasks 3, 5, 6, 8-12 |
| Node AWG.geo tests (§6.2) | Task 16 |
| `mock_curl.sh` / `mock_cru.sh` (§6.3) | Task 7 |
| DoD `make test` green (§7) | Task 20 |
| `addon_all.ipk` ≤ 200 KB (§7) | Task 20 |
| CHANGELOG updated (§7) | Task 19 |

All spec items have a mapped task.

**Type/naming consistency** (spot-check):
- `GEO_IPSET_VPN="awg_geo_dst"` / `GEO_IPSET_DIRECT="awg_geo_direct"` used consistently in Tasks 2, 9, 10, 11.
- `AMNEZIAWG_GEO_ROOT` default `/opt/etc/amneziawg/geo` consistent across Tasks 8-15.
- `vpn_except_geo` policy name identical in Tasks 1, 3, 16, 17, 19.
- `awg_geo_<cat>_mode` with `_mode` suffix consistent in Tasks 1, 8, 9, 11, 15, 16.
- `awg_geo_entries_direct` (not `entries_bypass` or similar) consistent in Tasks 1, 2, 10, 18.
- Cron ID `awggeosync` consistent in Tasks 8, 12, 13, 14.

**Placeholder scan:** no `TBD`, `TODO`, "similar to", or "appropriate error handling" in steps — each step contains the actual code.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-20-module-5-geoip-plan.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — Fresh subagent per task, two-stage review (spec compliance → code quality), fast iteration.
2. **Inline Execution** — Batch execution with checkpoints via `executing-plans`.
