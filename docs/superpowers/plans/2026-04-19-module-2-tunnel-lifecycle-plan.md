# Module 2 — Tunnel Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Module 1's stubs into a working AmneziaWG tunnel lifecycle: `amneziawg.sh start` brings `awg0` up with a live handshake; a cron watchdog keeps it alive; `wan-event` reacts with debounced restarts; v1 users can upgrade with their config preserved.

**Architecture:** POSIX-shell libs under `addon/lib/`, each with one responsibility. `config.sh` handles schema + emit, `tunnel.sh` wraps `awg-quick`, `watchdog.sh` ticks every minute from `cru`, `events.sh` dispatches Merlin hooks, `state.sh` migrates v1 data. Strict fail-fast validation (malformed config never reaches `awg-quick`). TDD via `bats-core` with PATH-injected mocks for `awg-quick`/`awg`/`ip`/`pidof`/`nvram`/`cru`.

**Tech Stack:** POSIX shell (busybox ash on Merlin), bats-core, awk, `awg-quick` (upstream vendored as `amneziawg-tools`), `awg` CLI, `cru` (Merlin cron wrapper).

**Spec:** `docs/superpowers/specs/2026-04-19-module-2-tunnel-lifecycle-design.md`

**Starting point:** Module 1 complete at commit `261c68f` on `main`.

---

## File structure

### Created in M2

- `addon/lib/config.sh` — parse, validate, emit `awg0.conf`
- `addon/lib/tunnel.sh` — `awg-quick` wrapper + lifecycle verbs
- `addon/lib/status.sh` — JSON status producer
- `addon/lib/watchdog.sh` — `watchdog_tick` periodic health
- `addon/lib/events.sh` — hook dispatchers (`event_service/wan/firewall/services_start`)
- `addon/lib/postup.sh` — `awg-quick` PostUp hook (M2 stub, M3 hook point)
- `addon/lib/postdown.sh` — counterpart to postup
- `addon/tests/config_test.bats`
- `addon/tests/tunnel_test.bats`
- `addon/tests/status_test.bats`
- `addon/tests/watchdog_test.bats`
- `addon/tests/events_test.bats`
- `addon/tests/state_migrate_test.bats`
- `addon/tests/fixtures/v1-custom-settings.txt`
- `addon/tests/fixtures/v1-awg0.conf`
- `addon/tests/fixtures/amnezia-2.0-import.conf`
- `addon/tests/fixtures/bad-h1.conf`
- `addon/tests/fixtures/bad-key.conf`
- `addon/tests/fixtures/bad-endpoint.conf`
- `addon/tests/fixtures/expected-emit-full.conf`

### Modified in M2

- `addon/lib/state.sh` — real `migrate_from_v1` + `backup_before_remove`
- `addon/amneziawg.sh` — dispatcher real handlers
- `addon/lib/install.sh` — cron `cru` registration on install/uninstall

All new shell files are POSIX (busybox target). No bashisms. Atomic tmp+mv writes for every file mutation.

---

## Tooling prerequisites

Same as M1: `bats-core`, `shellcheck`, `shfmt`, `jq`. All installed from M1 execution.

Extra conventions:

- **Private functions** prefixed `_` (e.g. `_config_validate_key`).
- **Variables local to functions** use `_name` prefix (busybox has no `local`).
- **All public env vars** prefixed `AMNEZIAWG_` or `AWG_` (dispatcher uses `AWG_`, libs use `AMNEZIAWG_`).
- **All log output** goes through `log_info/warn/error/debug` (from M1 `log.sh`).

---

## Phase 1 — Fixtures and `config.sh`

Foundation module. Tests-first — TDD applies strictly here.

### Task 1: Create fixture files

**Files:**
- Create: `addon/tests/fixtures/v1-custom-settings.txt`
- Create: `addon/tests/fixtures/v1-awg0.conf`
- Create: `addon/tests/fixtures/amnezia-2.0-import.conf`
- Create: `addon/tests/fixtures/bad-h1.conf`
- Create: `addon/tests/fixtures/bad-key.conf`
- Create: `addon/tests/fixtures/bad-endpoint.conf`
- Create: `addon/tests/fixtures/expected-emit-full.conf`

These are data files used by later tests. Self-contained task.

- [ ] **Step 1: Write v1 fixtures**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/fixtures/v1-custom-settings.txt`:
```
amneziawg_enabled 1
amneziawg_privatekey aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=
amneziawg_publickey Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM=
amneziawg_address 10.8.0.2/24
amneziawg_dns 1.1.1.1
amneziawg_endpoint example.com:51820
amneziawg_allowedips 0.0.0.0/0
amneziawg_persistent_keepalive 25
amneziawg_mtu 1280
amneziawg_jc 4
amneziawg_jmin 40
amneziawg_jmax 70
amneziawg_s1 0
amneziawg_s2 0
amneziawg_h1 1
amneziawg_h2 2
amneziawg_h3 3
amneziawg_h4 4
amneziawg_devices {"policy":"all"}
unrelated_key leave_me_alone
```

`/Users/r00t/Desktop/AmneziaGo/addon/tests/fixtures/v1-awg0.conf`:
```
[Interface]
PrivateKey = aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=
Address = 10.8.0.2/24
DNS = 1.1.1.1
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM=
Endpoint = example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

- [ ] **Step 2: Write Amnezia 2.0 import fixture**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/fixtures/amnezia-2.0-import.conf`:
```
[Interface]
PrivateKey = aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=
Address = 10.8.0.2/24
DNS = 1.1.1.1
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 2072158144-2145681082
H2 = 1234
H3 = 5678
H4 = 9012
I1 = <b 0xabcd><r 8><t>
I2 = <rd 6>
I3 = <rc 10>

[Peer]
PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM=
PresharedKey = cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHM=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0,::/0
PersistentKeepalive = 25
```

- [ ] **Step 3: Write negative fixtures**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/fixtures/bad-h1.conf`:
```
[Interface]
PrivateKey = aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=
Address = 10.8.0.2/24
Jc = 4
Jmin = 40
Jmax = 70
H1 = not-a-number
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM=
Endpoint = example.com:51820
AllowedIPs = 0.0.0.0/0
```

`/Users/r00t/Desktop/AmneziaGo/addon/tests/fixtures/bad-key.conf`:
```
[Interface]
PrivateKey = too-short
Address = 10.8.0.2/24
Jc = 4
Jmin = 40
Jmax = 70
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM=
Endpoint = example.com:51820
AllowedIPs = 0.0.0.0/0
```

`/Users/r00t/Desktop/AmneziaGo/addon/tests/fixtures/bad-endpoint.conf`:
```
[Interface]
PrivateKey = aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=
Address = 10.8.0.2/24
Jc = 4
Jmin = 40
Jmax = 70
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM=
Endpoint = no-port-here
AllowedIPs = 0.0.0.0/0
```

- [ ] **Step 4: Write golden-output fixture**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/fixtures/expected-emit-full.conf`:
```
# Generated by amneziawg.sh — do not edit manually.
# Changes must go through the WebUI (VPN → AmneziaWG).

[Interface]
PrivateKey = aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=
Address = 10.8.0.2/24
DNS = 1.1.1.1
MTU = 1280

Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 2072158144-2145681082
H2 = 1234
H3 = 5678
H4 = 9012
I1 = <b 0xabcd><r 8><t>
I2 = <rd 6>
I3 = <rc 10>

PostUp = /jffs/addons/amneziawg/lib/postup.sh %i
PostDown = /jffs/addons/amneziawg/lib/postdown.sh %i

[Peer]
PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM=
PresharedKey = cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHM=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0,::/0
PersistentKeepalive = 25
```

Note: no `# Generated: <timestamp>` line — per spec §4.5, default emit omits it for determinism.

- [ ] **Step 5: Commit**

```bash
cd /Users/r00t/Desktop/AmneziaGo
git add addon/tests/fixtures/
git commit -m "test(m2): add config fixtures for config.sh validation and emit tests"
```

---

### Task 2: `config.sh` scalar validators (keys, IPs, endpoints, ints)

Start with the smallest unit — validators that take a single string and return 0/1.

**Files:**
- Create: `addon/lib/config.sh`
- Create: `addon/tests/config_test.bats`

- [ ] **Step 1: Write failing bats tests for scalar validators**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/config_test.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

# --- _config_validate_key ---

@test "validate_key accepts 44-char base64" {
    _config_validate_key "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
}

@test "validate_key rejects short string" {
    ! _config_validate_key "too-short"
}

@test "validate_key rejects non-base64 alphabet" {
    ! _config_validate_key "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}

@test "validate_key rejects empty string" {
    ! _config_validate_key ""
}

# --- _config_validate_addr ---

@test "validate_addr accepts 10.8.0.2/24" {
    _config_validate_addr "10.8.0.2/24"
}

@test "validate_addr accepts 192.168.1.1/32" {
    _config_validate_addr "192.168.1.1/32"
}

@test "validate_addr rejects missing prefix" {
    ! _config_validate_addr "10.8.0.2"
}

@test "validate_addr rejects bad octet" {
    ! _config_validate_addr "999.0.0.1/24"
}

@test "validate_addr rejects prefix >32" {
    ! _config_validate_addr "10.8.0.2/33"
}

# --- _config_validate_endpoint ---

@test "validate_endpoint accepts host:port" {
    _config_validate_endpoint "example.com:51820"
}

@test "validate_endpoint accepts IP:port" {
    _config_validate_endpoint "1.2.3.4:443"
}

@test "validate_endpoint rejects missing port" {
    ! _config_validate_endpoint "example.com"
}

@test "validate_endpoint rejects port=0" {
    ! _config_validate_endpoint "example.com:0"
}

@test "validate_endpoint rejects port>65535" {
    ! _config_validate_endpoint "example.com:70000"
}

# --- _config_validate_cidr_list ---

@test "validate_cidr_list accepts single cidr" {
    _config_validate_cidr_list "0.0.0.0/0"
}

@test "validate_cidr_list accepts multiple cidrs" {
    _config_validate_cidr_list "10.0.0.0/8,192.168.0.0/16"
}

@test "validate_cidr_list accepts IPv6" {
    _config_validate_cidr_list "0.0.0.0/0,::/0"
}

@test "validate_cidr_list rejects empty" {
    ! _config_validate_cidr_list ""
}

@test "validate_cidr_list rejects bad entry" {
    ! _config_validate_cidr_list "10.0.0.0/8,garbage"
}

# --- _config_validate_int_range ---

@test "validate_int_range accepts value in range" {
    _config_validate_int_range "500" 100 1000
}

@test "validate_int_range rejects below min" {
    ! _config_validate_int_range "50" 100 1000
}

@test "validate_int_range rejects above max" {
    ! _config_validate_int_range "1500" 100 1000
}

@test "validate_int_range rejects non-numeric" {
    ! _config_validate_int_range "abc" 100 1000
}
```

- [ ] **Step 2: Run tests to verify all fail**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/config_test.bats
```
Expected: all 22 tests fail (`config.sh` does not exist yet).

- [ ] **Step 3: Create minimal `addon/lib/config.sh` with scalar validators**

`/Users/r00t/Desktop/AmneziaGo/addon/lib/config.sh`:
```sh
#!/bin/sh
# addon/lib/config.sh — parse, validate, emit awg0.conf.
#
# Schema: custom_settings.txt v2 keys prefixed `awg_`. See spec §4.1.
# Public API:
#   config_load                    — read awg_* keys into _cfg_<key> vars
#   config_validate                — validate loaded vars, logs errors
#   config_emit <path>             — atomic tmp+mv write of awg0.conf
#   config_import_from_stdin       — parse .conf, validate, persist
#   config_export                  — emit current custom_settings as .conf
#
# All private functions prefixed `_config_`.

# Guard: requires log.sh and state.sh sourced first.
if ! command -v log_info >/dev/null 2>&1; then
    echo "config.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v state_get >/dev/null 2>&1; then
    echo "config.sh: state.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

# ------------------------------ scalar validators ------------------------------

_config_validate_key() {
    # 44-char base64 (32-byte key + `=` padding).
    _val="$1"
    [ -n "${_val}" ] || return 1
    [ "${#_val}" -eq 44 ] || return 1
    # Base64 alphabet: A-Z a-z 0-9 + / and trailing =
    printf '%s' "${_val}" | grep -Eq '^[A-Za-z0-9+/]{43}=$' || return 1
    return 0
}

_config_validate_addr() {
    # IPv4/prefix (IPv6 support: v2.x).
    _val="$1"
    printf '%s' "${_val}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || return 1
    _ip="${_val%/*}"
    _prefix="${_val##*/}"
    _i=1
    for _octet in $(printf '%s\n' "${_ip}" | tr '.' ' '); do
        [ "${_octet}" -ge 0 ] 2>/dev/null && [ "${_octet}" -le 255 ] || return 1
        _i=$((_i + 1))
    done
    [ "${_prefix}" -ge 0 ] 2>/dev/null && [ "${_prefix}" -le 32 ] || return 1
    return 0
}

_config_validate_endpoint() {
    # host:port where host is DNS name or IP, port is 1..65535.
    _val="$1"
    case "${_val}" in
        *:*) ;;
        *) return 1 ;;
    esac
    _host="${_val%:*}"
    _port="${_val##*:}"
    [ -n "${_host}" ] || return 1
    [ "${_port}" -ge 1 ] 2>/dev/null && [ "${_port}" -le 65535 ] || return 1
    return 0
}

_config_validate_cidr_list() {
    # Comma-separated CIDRs (IPv4 or IPv6).
    _val="$1"
    [ -n "${_val}" ] || return 1
    _IFS_save="${IFS}"
    IFS=','
    for _entry in ${_val}; do
        case "${_entry}" in
            *:*/*)
                # IPv6: must contain at least one `:` in host part.
                printf '%s' "${_entry}" | grep -Eq '^[0-9A-Fa-f:]+/[0-9]+$' || {
                    IFS="${_IFS_save}"
                    return 1
                }
                ;;
            *.*.*.*/*)
                printf '%s' "${_entry}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || {
                    IFS="${_IFS_save}"
                    return 1
                }
                ;;
            *)
                IFS="${_IFS_save}"
                return 1
                ;;
        esac
    done
    IFS="${_IFS_save}"
    return 0
}

_config_validate_int_range() {
    _val="$1"; _min="$2"; _max="$3"
    printf '%s' "${_val}" | grep -Eq '^[0-9]+$' || return 1
    [ "${_val}" -ge "${_min}" ] && [ "${_val}" -le "${_max}" ] || return 1
    return 0
}
```

- [ ] **Step 4: Run tests to verify passing**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/config_test.bats
```
Expected: all 22 tests pass.

- [ ] **Step 5: Commit**

```bash
git add addon/lib/config.sh addon/tests/config_test.bats
git commit -m "feat(config): add scalar validators (key/addr/endpoint/cidr_list/int_range)"
```

---

### Task 3: H1-range and I1-I5 tagged-syntax validators

**Files:**
- Modify: `addon/lib/config.sh`
- Modify: `addon/tests/config_test.bats`

- [ ] **Step 1: Append H1 and I-tag tests to `config_test.bats`**

Append to `/Users/r00t/Desktop/AmneziaGo/addon/tests/config_test.bats`:
```bash

# --- _config_validate_h_value (AmneziaWG 2.0 range syntax) ---

@test "validate_h_value accepts single int" {
    _config_validate_h_value "12345"
}

@test "validate_h_value accepts range" {
    _config_validate_h_value "2072158144-2145681082"
}

@test "validate_h_value rejects range with min>max" {
    ! _config_validate_h_value "100-50"
}

@test "validate_h_value rejects non-numeric" {
    ! _config_validate_h_value "abc"
}

@test "validate_h_value rejects empty" {
    ! _config_validate_h_value ""
}

@test "validate_h_value accepts range with equal bounds" {
    _config_validate_h_value "100-100"
}

# --- _config_validate_i_sequence (I1-I5 tagged syntax) ---

@test "validate_i_sequence accepts empty (field absent)" {
    _config_validate_i_sequence ""
}

@test "validate_i_sequence accepts static bytes tag" {
    _config_validate_i_sequence "<b 0xabcd>"
}

@test "validate_i_sequence accepts random bytes tag" {
    _config_validate_i_sequence "<r 8>"
}

@test "validate_i_sequence accepts random digits tag" {
    _config_validate_i_sequence "<rd 6>"
}

@test "validate_i_sequence accepts random chars tag" {
    _config_validate_i_sequence "<rc 10>"
}

@test "validate_i_sequence accepts timestamp tag" {
    _config_validate_i_sequence "<t>"
}

@test "validate_i_sequence accepts compound sequence" {
    _config_validate_i_sequence "<b 0xabcd><r 8><t>"
}

@test "validate_i_sequence rejects odd-length hex in b tag" {
    ! _config_validate_i_sequence "<b 0xabc>"
}

@test "validate_i_sequence rejects unknown tag" {
    ! _config_validate_i_sequence "<x 5>"
}

@test "validate_i_sequence rejects stray text between tags" {
    ! _config_validate_i_sequence "<t>garbage<r 8>"
}

@test "validate_i_sequence rejects unclosed tag" {
    ! _config_validate_i_sequence "<t"
}
```

- [ ] **Step 2: Run tests to verify new tests fail**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/config_test.bats 2>&1 | tail -20
```
Expected: 22 prior pass, 17 new fail ("command not found" or similar).

- [ ] **Step 3: Append H1/I-validators to `config.sh`**

Append to `/Users/r00t/Desktop/AmneziaGo/addon/lib/config.sh`:
```sh

_config_validate_h_value() {
    # AmneziaWG 2.0: single int or range "N-M" with M>=N.
    _val="$1"
    [ -n "${_val}" ] || return 1
    case "${_val}" in
        *-*)
            _lo="${_val%-*}"
            _hi="${_val#*-}"
            printf '%s' "${_lo}" | grep -Eq '^[0-9]+$' || return 1
            printf '%s' "${_hi}" | grep -Eq '^[0-9]+$' || return 1
            [ "${_lo}" -le "${_hi}" ] || return 1
            ;;
        *)
            printf '%s' "${_val}" | grep -Eq '^[0-9]+$' || return 1
            ;;
    esac
    return 0
}

_config_validate_i_sequence() {
    # AmneziaWG 2.0 tagged signature packet value.
    # Empty string OK — means "field absent".
    _val="$1"
    [ -z "${_val}" ] && return 0
    # Consume tags from left. Each iteration strips one valid tag.
    _rest="${_val}"
    while [ -n "${_rest}" ]; do
        case "${_rest}" in
            "<t>"*)
                _rest="${_rest#<t>}"
                ;;
            "<b 0x"*">"*)
                # <b 0x[even-length-hex]>
                _tag="${_rest%%>*}>"
                _hex="${_tag#<b 0x}"
                _hex="${_hex%>}"
                # Even-length hex
                _hexlen=${#_hex}
                [ "$((_hexlen % 2))" -eq 0 ] || return 1
                printf '%s' "${_hex}" | grep -Eq '^[0-9a-fA-F]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            "<r "*">"*)
                _tag="${_rest%%>*}>"
                _size="${_tag#<r }"
                _size="${_size%>}"
                printf '%s' "${_size}" | grep -Eq '^[0-9]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            "<rd "*">"*)
                _tag="${_rest%%>*}>"
                _size="${_tag#<rd }"
                _size="${_size%>}"
                printf '%s' "${_size}" | grep -Eq '^[0-9]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            "<rc "*">"*)
                _tag="${_rest%%>*}>"
                _size="${_tag#<rc }"
                _size="${_size%>}"
                printf '%s' "${_size}" | grep -Eq '^[0-9]+$' || return 1
                _rest="${_rest#*>}"
                ;;
            *)
                return 1
                ;;
        esac
    done
    return 0
}
```

- [ ] **Step 4: Run tests — all 39 pass**

```bash
bats addon/tests/config_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/config.sh addon/tests/config_test.bats
git commit -m "feat(config): add H1-range and I1-I5 tagged-syntax validators (Amnezia 2.0)"
```

---

### Task 4: `config_load` and `config_validate`

**Files:**
- Modify: `addon/lib/config.sh`
- Modify: `addon/tests/config_test.bats`

- [ ] **Step 1: Append config_load + config_validate tests**

Append to `addon/tests/config_test.bats`:
```bash

# --- config_load ---

@test "config_load populates _cfg vars from custom_settings" {
    state_set "awg_enabled" "1"
    state_set "awg_privatekey" "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address" "10.8.0.2/24"
    state_set "awg_peer_endpoint" "example.com:51820"
    config_load
    [ "${_cfg_enabled}" = "1" ]
    [ "${_cfg_address}" = "10.8.0.2/24" ]
    [ "${_cfg_peer_endpoint}" = "example.com:51820" ]
}

@test "config_load sets empty for missing keys" {
    config_load
    [ -z "${_cfg_privatekey}" ]
    [ -z "${_cfg_peer_endpoint}" ]
}

# --- config_validate (integration) ---

_set_minimal_valid_config() {
    state_set "awg_enabled" "1"
    state_set "awg_privatekey"     "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"        "10.8.0.2/24"
    state_set "awg_jc"             "4"
    state_set "awg_jmin"           "40"
    state_set "awg_jmax"           "70"
    state_set "awg_h1"             "1"
    state_set "awg_h2"             "2"
    state_set "awg_h3"             "3"
    state_set "awg_h4"             "4"
    state_set "awg_peer_publickey" "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM="
    state_set "awg_peer_endpoint"  "example.com:51820"
    state_set "awg_peer_allowed_ips" "0.0.0.0/0"
}

@test "config_validate accepts minimal valid config" {
    _set_minimal_valid_config
    config_load
    config_validate
}

@test "config_validate rejects missing privatekey" {
    _set_minimal_valid_config
    state_delete "awg_privatekey"
    config_load
    ! config_validate
    grep -q "privatekey" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate rejects bad H1" {
    _set_minimal_valid_config
    state_set "awg_h1" "abc"
    config_load
    ! config_validate
    grep -q "h1" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate rejects jmax < jmin" {
    _set_minimal_valid_config
    state_set "awg_jmin" "100"
    state_set "awg_jmax" "50"
    config_load
    ! config_validate
    grep -q "jmax" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate accepts H1 range" {
    _set_minimal_valid_config
    state_set "awg_h1" "2072158144-2145681082"
    config_load
    config_validate
}

@test "config_validate accepts optional I1" {
    _set_minimal_valid_config
    state_set "awg_i1" "<b 0xabcd><r 8><t>"
    config_load
    config_validate
}

@test "config_validate rejects bad I1" {
    _set_minimal_valid_config
    state_set "awg_i1" "garbage"
    config_load
    ! config_validate
    grep -q "i1" "${AMNEZIAWG_LOG_FILE}"
}

@test "config_validate rejects bad MTU" {
    _set_minimal_valid_config
    state_set "awg_mtu" "100"
    config_load
    ! config_validate
    grep -q "mtu" "${AMNEZIAWG_LOG_FILE}"
}
```

- [ ] **Step 2: Run — 10 new tests fail**

```bash
bats addon/tests/config_test.bats 2>&1 | tail -15
```

- [ ] **Step 3: Append config_load + config_validate to config.sh**

Append to `/Users/r00t/Desktop/AmneziaGo/addon/lib/config.sh`:
```sh

# ------------------------------ config_load ------------------------------

# List of all known awg_* keys. Kept in sync with spec §4.1.
_CFG_KEYS="
    enabled
    privatekey
    address
    dns
    mtu
    jc
    jmin
    jmax
    s1 s2 s3 s4
    h1 h2 h3 h4
    i1 i2 i3 i4 i5
    peer_publickey
    peer_presharedkey
    peer_endpoint
    peer_allowed_ips
    peer_keepalive
"

config_load() {
    for _key in ${_CFG_KEYS}; do
        _val="$(state_get "awg_${_key}")"
        eval "_cfg_${_key}=\"\${_val}\""
    done
}

# ------------------------------ config_validate ------------------------------

_config_err() { log_error "config: $*"; _config_bad=1; }

config_validate() {
    _config_bad=0

    # enabled: 0 or 1 (default 0)
    case "${_cfg_enabled:-0}" in
        0|1) ;;
        *) _config_err "enabled must be 0 or 1" ;;
    esac

    # Required: privatekey, address, peer_publickey, peer_endpoint, peer_allowed_ips
    if ! _config_validate_key "${_cfg_privatekey}"; then
        _config_err "privatekey invalid (must be 44-char base64)"
    fi
    if ! _config_validate_addr "${_cfg_address}"; then
        _config_err "address invalid (must be IP/prefix, e.g. 10.8.0.2/24)"
    fi
    if ! _config_validate_key "${_cfg_peer_publickey}"; then
        _config_err "peer_publickey invalid"
    fi
    if ! _config_validate_endpoint "${_cfg_peer_endpoint}"; then
        _config_err "peer_endpoint invalid (must be host:port)"
    fi
    if ! _config_validate_cidr_list "${_cfg_peer_allowed_ips}"; then
        _config_err "peer_allowed_ips invalid (CIDR list required)"
    fi

    # Optional: presharedkey
    if [ -n "${_cfg_peer_presharedkey}" ]; then
        _config_validate_key "${_cfg_peer_presharedkey}" \
            || _config_err "peer_presharedkey invalid"
    fi

    # Optional: dns (comma-separated IPs)
    if [ -n "${_cfg_dns}" ]; then
        _IFS_save="${IFS}"; IFS=','
        for _ip in ${_cfg_dns}; do
            printf '%s' "${_ip}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                || _config_err "dns entry '${_ip}' invalid"
        done
        IFS="${_IFS_save}"
    fi

    # MTU: default 1280, range 576..1500
    _mtu="${_cfg_mtu:-1280}"
    if ! _config_validate_int_range "${_mtu}" 576 1500; then
        _config_err "mtu invalid (range 576..1500, got '${_mtu}')"
    fi

    # Jc: 1..128
    _config_validate_int_range "${_cfg_jc:-0}" 1 128 \
        || _config_err "jc invalid (range 1..128)"
    _config_validate_int_range "${_cfg_jmin:-0}" 0 1500 \
        || _config_err "jmin invalid"
    _config_validate_int_range "${_cfg_jmax:-0}" 0 1500 \
        || _config_err "jmax invalid"
    if [ "${_cfg_jmax:-0}" -lt "${_cfg_jmin:-0}" ] 2>/dev/null; then
        _config_err "jmax (${_cfg_jmax}) must be >= jmin (${_cfg_jmin})"
    fi

    # S1..S4: optional, 0..1500 each
    for _s in s1 s2 s3 s4; do
        eval "_val=\"\${_cfg_${_s}}\""
        [ -z "${_val}" ] && continue
        _config_validate_int_range "${_val}" 0 1500 \
            || _config_err "${_s} invalid"
    done

    # H1..H4: required, range syntax
    for _h in h1 h2 h3 h4; do
        eval "_val=\"\${_cfg_${_h}}\""
        _config_validate_h_value "${_val}" \
            || _config_err "${_h} invalid (int or int-int, got '${_val}')"
    done

    # I1..I5: optional, tagged syntax
    for _i in i1 i2 i3 i4 i5; do
        eval "_val=\"\${_cfg_${_i}}\""
        _config_validate_i_sequence "${_val}" \
            || _config_err "${_i} invalid tagged sequence"
    done

    # peer_keepalive: optional, 0..65535
    if [ -n "${_cfg_peer_keepalive}" ]; then
        _config_validate_int_range "${_cfg_peer_keepalive}" 0 65535 \
            || _config_err "peer_keepalive invalid"
    fi

    [ "${_config_bad}" -eq 0 ]
}
```

- [ ] **Step 4: Run — all 49 tests pass**

```bash
bats addon/tests/config_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/config.sh addon/tests/config_test.bats
git commit -m "feat(config): add config_load and config_validate with full field schema"
```

---

### Task 5: `config_emit` — atomic deterministic writer

**Files:**
- Modify: `addon/lib/config.sh`
- Modify: `addon/tests/config_test.bats`

- [ ] **Step 1: Append emit tests**

Append to `addon/tests/config_test.bats`:
```bash

# --- config_emit ---

_set_full_config_from_amnezia2() {
    state_set "awg_enabled"         "1"
    state_set "awg_privatekey"      "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"         "10.8.0.2/24"
    state_set "awg_dns"             "1.1.1.1"
    state_set "awg_mtu"             "1280"
    state_set "awg_jc"              "4"
    state_set "awg_jmin"            "40"
    state_set "awg_jmax"            "70"
    state_set "awg_s1"              "0"
    state_set "awg_s2"              "0"
    state_set "awg_h1"              "2072158144-2145681082"
    state_set "awg_h2"              "1234"
    state_set "awg_h3"              "5678"
    state_set "awg_h4"              "9012"
    state_set "awg_i1"              "<b 0xabcd><r 8><t>"
    state_set "awg_i2"              "<rd 6>"
    state_set "awg_i3"              "<rc 10>"
    state_set "awg_peer_publickey"    "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM="
    state_set "awg_peer_presharedkey" "cHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHNrcHM="
    state_set "awg_peer_endpoint"     "vpn.example.com:51820"
    state_set "awg_peer_allowed_ips"  "0.0.0.0/0,::/0"
    state_set "awg_peer_keepalive"    "25"
}

@test "config_emit writes to target path" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    [ -f "${TMPDIR_TEST}/awg0.conf" ]
}

@test "config_emit matches golden fixture" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    diff -u "${BATS_TEST_DIRNAME}/fixtures/expected-emit-full.conf" \
            "${TMPDIR_TEST}/awg0.conf"
}

@test "config_emit is deterministic (two runs = byte-identical)" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/one.conf"
    config_emit "${TMPDIR_TEST}/two.conf"
    cmp -s "${TMPDIR_TEST}/one.conf" "${TMPDIR_TEST}/two.conf"
}

@test "config_emit uses tmp+mv (no leftover .tmp file)" {
    _set_full_config_from_amnezia2
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    ! ls "${TMPDIR_TEST}/awg0.conf.tmp."* 2>/dev/null
}

@test "config_emit omits empty optional fields" {
    state_set "awg_enabled"           "1"
    state_set "awg_privatekey"        "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"           "10.8.0.2/24"
    state_set "awg_jc"                "4"
    state_set "awg_jmin"              "40"
    state_set "awg_jmax"              "70"
    state_set "awg_h1"                "1"
    state_set "awg_h2"                "2"
    state_set "awg_h3"                "3"
    state_set "awg_h4"                "4"
    state_set "awg_peer_publickey"    "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM="
    state_set "awg_peer_endpoint"     "example.com:51820"
    state_set "awg_peer_allowed_ips"  "0.0.0.0/0"
    config_load
    config_emit "${TMPDIR_TEST}/awg0.conf"
    ! grep -q '^DNS '            "${TMPDIR_TEST}/awg0.conf"
    ! grep -q '^I1 '             "${TMPDIR_TEST}/awg0.conf"
    ! grep -q '^PresharedKey '   "${TMPDIR_TEST}/awg0.conf"
}
```

- [ ] **Step 2: Run — 5 new tests fail**

```bash
bats addon/tests/config_test.bats 2>&1 | tail -10
```

- [ ] **Step 3: Append config_emit to config.sh**

Append to `addon/lib/config.sh`:
```sh

# ------------------------------ config_emit ------------------------------

# Emit generated awg0.conf to $1 (atomic tmp+mv).
# Precondition: config_load was called.
config_emit() {
    _target="$1"
    _tmp="${_target}.tmp.$$"
    _dir="$(dirname "${_target}")"
    mkdir -p "${_dir}"

    {
        printf '# Generated by amneziawg.sh — do not edit manually.\n'
        printf '# Changes must go through the WebUI (VPN → AmneziaWG).\n'
        printf '\n'
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "${_cfg_privatekey}"
        printf 'Address = %s\n'    "${_cfg_address}"
        [ -n "${_cfg_dns}" ] && printf 'DNS = %s\n' "${_cfg_dns}"
        printf 'MTU = %s\n' "${_cfg_mtu:-1280}"
        printf '\n'
        printf 'Jc = %s\n'   "${_cfg_jc}"
        printf 'Jmin = %s\n' "${_cfg_jmin}"
        printf 'Jmax = %s\n' "${_cfg_jmax}"
        for _s in s1 s2 s3 s4; do
            eval "_val=\"\${_cfg_${_s}}\""
            [ -n "${_val}" ] && printf '%s = %s\n' "$(printf '%s' "${_s}" | tr a-z A-Z)" "${_val}"
        done
        for _h in h1 h2 h3 h4; do
            eval "_val=\"\${_cfg_${_h}}\""
            printf '%s = %s\n' "$(printf '%s' "${_h}" | tr a-z A-Z)" "${_val}"
        done
        for _i in i1 i2 i3 i4 i5; do
            eval "_val=\"\${_cfg_${_i}}\""
            [ -n "${_val}" ] && printf '%s = %s\n' "$(printf '%s' "${_i}" | tr a-z A-Z)" "${_val}"
        done
        printf '\n'
        printf 'PostUp = /jffs/addons/amneziawg/lib/postup.sh %%i\n'
        printf 'PostDown = /jffs/addons/amneziawg/lib/postdown.sh %%i\n'
        printf '\n'
        printf '[Peer]\n'
        printf 'PublicKey = %s\n' "${_cfg_peer_publickey}"
        [ -n "${_cfg_peer_presharedkey}" ] && printf 'PresharedKey = %s\n' "${_cfg_peer_presharedkey}"
        printf 'Endpoint = %s\n'     "${_cfg_peer_endpoint}"
        printf 'AllowedIPs = %s\n'   "${_cfg_peer_allowed_ips}"
        printf 'PersistentKeepalive = %s\n' "${_cfg_peer_keepalive:-25}"
    } > "${_tmp}"

    chmod 600 "${_tmp}"
    mv "${_tmp}" "${_target}"
}
```

- [ ] **Step 4: Run — all 54 tests pass**

```bash
bats addon/tests/config_test.bats
```

If `config_emit matches golden fixture` fails, open the diff output and ensure the golden fixture matches your emit output exactly (trailing whitespace, blank lines, field order). Adjust either the fixture or the emit function — the emit function is the source of truth.

- [ ] **Step 5: Commit**

```bash
git add addon/lib/config.sh addon/tests/config_test.bats
git commit -m "feat(config): add config_emit with deterministic atomic writer"
```

---

### Task 6: `config_import_from_stdin` — parse .conf back into custom_settings

**Files:**
- Modify: `addon/lib/config.sh`
- Modify: `addon/tests/config_test.bats`

- [ ] **Step 1: Append import tests**

Append to `addon/tests/config_test.bats`:
```bash

# --- config_import_from_stdin ---

@test "config_import_from_stdin parses valid Amnezia 2.0 conf" {
    config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/amnezia-2.0-import.conf"
    run state_get "awg_privatekey"
    [ "$output" = "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=" ]
    run state_get "awg_h1"
    [ "$output" = "2072158144-2145681082" ]
    run state_get "awg_i1"
    [ "$output" = "<b 0xabcd><r 8><t>" ]
    run state_get "awg_peer_endpoint"
    [ "$output" = "vpn.example.com:51820" ]
    run state_get "awg_peer_allowed_ips"
    [ "$output" = "0.0.0.0/0,::/0" ]
}

@test "config_import_from_stdin fails on bad H1" {
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-h1.conf"
}

@test "config_import_from_stdin fails on bad key" {
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-key.conf"
}

@test "config_import_from_stdin fails on bad endpoint" {
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-endpoint.conf"
}

@test "config_import_from_stdin fails on non-conf garbage" {
    ! printf "random text\nno sections\n" | config_import_from_stdin
}

@test "config_import_from_stdin sets awg_enabled=1 after successful import" {
    state_delete "awg_enabled"
    config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/amnezia-2.0-import.conf"
    run state_get "awg_enabled"
    [ "$output" = "1" ]
}

@test "config_import_from_stdin does not partially persist on validation error" {
    state_set "awg_privatekey" "preexisting"
    ! config_import_from_stdin < "${BATS_TEST_DIRNAME}/fixtures/bad-h1.conf"
    run state_get "awg_privatekey"
    [ "$output" = "preexisting" ]
}
```

- [ ] **Step 2: Run — 7 new fail**

```bash
bats addon/tests/config_test.bats 2>&1 | tail -12
```

- [ ] **Step 3: Append `config_import_from_stdin` to config.sh**

Append to `addon/lib/config.sh`:
```sh

# ------------------------------ config_import_from_stdin ------------------------------

# Parse an Amnezia .conf from stdin. On success, persist into custom_settings
# and set awg_enabled=1. On validation failure, state is untouched.
config_import_from_stdin() {
    _tmp="$(mktemp)"
    cat > "${_tmp}"

    # Parse into _imp_<key> vars. awk emits "key=value" lines, then eval here.
    # Two sections: [Interface] and [Peer]. Case-insensitive keys.
    _parsed="$(
        awk -F'=' '
            /^\[Interface\]/ { section="interface"; next }
            /^\[Peer\]/      { section="peer"; next }
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { next }
            NF < 2 { next }
            {
                k=$1; v=$0
                sub(/^[^=]*=[[:space:]]*/,"",v)
                sub(/[[:space:]]*$/,"",v)
                sub(/[[:space:]]*$/,"",k)
                sub(/^[[:space:]]*/,"",k)
                k=tolower(k)
                if (section=="interface") {
                    if (k=="privatekey")   print "_imp_privatekey="v
                    else if (k=="address") print "_imp_address="v
                    else if (k=="dns")     print "_imp_dns="v
                    else if (k=="mtu")     print "_imp_mtu="v
                    else if (k=="jc")      print "_imp_jc="v
                    else if (k=="jmin")    print "_imp_jmin="v
                    else if (k=="jmax")    print "_imp_jmax="v
                    else if (k~/^s[1-4]$/) print "_imp_"k"="v
                    else if (k~/^h[1-4]$/) print "_imp_"k"="v
                    else if (k~/^i[1-5]$/) print "_imp_"k"="v
                } else if (section=="peer") {
                    if      (k=="publickey")          print "_imp_peer_publickey="v
                    else if (k=="presharedkey")       print "_imp_peer_presharedkey="v
                    else if (k=="endpoint")           print "_imp_peer_endpoint="v
                    else if (k=="allowedips")         print "_imp_peer_allowed_ips="v
                    else if (k=="persistentkeepalive") print "_imp_peer_keepalive="v
                }
            }
        ' "${_tmp}"
    )"
    rm -f "${_tmp}"

    # Clear all _imp_ vars before eval (defensive)
    _imp_privatekey=""; _imp_address=""; _imp_dns=""; _imp_mtu=""
    _imp_jc=""; _imp_jmin=""; _imp_jmax=""
    _imp_s1=""; _imp_s2=""; _imp_s3=""; _imp_s4=""
    _imp_h1=""; _imp_h2=""; _imp_h3=""; _imp_h4=""
    _imp_i1=""; _imp_i2=""; _imp_i3=""; _imp_i4=""; _imp_i5=""
    _imp_peer_publickey=""; _imp_peer_presharedkey=""
    _imp_peer_endpoint=""; _imp_peer_allowed_ips=""; _imp_peer_keepalive=""

    # Each line is "_imp_key=value" — quote safely.
    printf '%s\n' "${_parsed}" | while IFS= read -r _line; do
        [ -z "${_line}" ] && continue
        _k="${_line%%=*}"
        _v="${_line#*=}"
        printf 'eval_%s\t%s\n' "${_k}" "${_v}"
    done > "${TMPDIR:-/tmp}/awg-import-$$.kv"
    while IFS="$(printf '\t')" read -r _marker _val; do
        _k="${_marker#eval_}"
        eval "${_k}=\"\${_val}\""
    done < "${TMPDIR:-/tmp}/awg-import-$$.kv"
    rm -f "${TMPDIR:-/tmp}/awg-import-$$.kv"

    # Pseudo-load into _cfg_* for validate step
    for _key in ${_CFG_KEYS}; do
        eval "_imp_val=\"\${_imp_${_key}}\""
        [ -n "${_imp_val}" ] && eval "_cfg_${_key}=\"\${_imp_val}\""
    done

    # If no privatekey was parsed, the file is not a valid conf.
    if [ -z "${_cfg_privatekey}" ]; then
        log_error "import: no PrivateKey found; is this a wg/awg .conf file?"
        return 1
    fi

    # Validate BEFORE persisting. On failure nothing is written.
    if ! config_validate; then
        log_error "import: validation failed, not persisting"
        return 1
    fi

    # Persist all imported fields.
    for _key in ${_CFG_KEYS}; do
        eval "_imp_val=\"\${_imp_${_key}}\""
        if [ -n "${_imp_val}" ]; then
            state_set "awg_${_key}" "${_imp_val}"
        fi
    done
    state_set "awg_enabled" "1"
    log_info "import: config saved, enabled"
    return 0
}
```

- [ ] **Step 4: Run — 61 tests pass**

```bash
bats addon/tests/config_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/config.sh addon/tests/config_test.bats
git commit -m "feat(config): add config_import_from_stdin with validate-before-persist"
```

---

## Phase 2 — `tunnel.sh`

Wraps `awg-quick`. Tests PATH-inject mocks for `awg-quick`, `awg`, `ip`, `pidof`, `nvram`, `flock`, `timeout`.

### Task 7: `tunnel.sh` skeleton + `tunnel_is_up` + start happy path

**Files:**
- Create: `addon/lib/tunnel.sh`
- Create: `addon/tests/tunnel_test.bats`

- [ ] **Step 1: Write failing tunnel_test.bats**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/tunnel_test.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_CONF="${TMPDIR_TEST}/awg0.conf"
    export AMNEZIAWG_INTERFACE="awg0"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    mkdir -p "${AMNEZIAWG_RUNTIME}"

    # Mock bin dir on PATH
    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_LOG="${TMPDIR_TEST}/mock.log"
    : > "${MOCK_LOG}"

    # Mock awg-quick
    cat > "${TMPDIR_TEST}/bin/awg-quick" <<EOF
#!/bin/sh
printf 'awg-quick %s\n' "\$*" >> "${MOCK_LOG}"
# Side-effect: create a fake "link" file so ip/pidof mocks can see it
case "\$1" in
    up)    touch "${TMPDIR_TEST}/link-up"
           touch "${TMPDIR_TEST}/daemon-pid"
           ;;
    down)  rm -f "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
           ;;
esac
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg-quick"

    # Mock ip link
    cat > "${TMPDIR_TEST}/bin/ip" <<EOF
#!/bin/sh
if [ "\$1" = "link" ] && [ "\$2" = "show" ]; then
    [ -f "${TMPDIR_TEST}/link-up" ] && exit 0 || exit 1
fi
if [ "\$1" = "link" ] && [ "\$2" = "del" ]; then
    rm -f "${TMPDIR_TEST}/link-up"
    exit 0
fi
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"

    # Mock pidof
    cat > "${TMPDIR_TEST}/bin/pidof" <<EOF
#!/bin/sh
if [ "\$1" = "-x" ]; then shift; fi
if [ "\$1" = "amneziawg-go" ]; then
    [ -f "${TMPDIR_TEST}/daemon-pid" ] && echo "1234" || exit 1
else
    exit 1
fi
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"

    # Mock pkill (harmless)
    cat > "${TMPDIR_TEST}/bin/pkill" <<EOF
#!/bin/sh
printf 'pkill %s\n' "\$*" >> "${MOCK_LOG}"
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/pkill"

    # Mock timeout: just run the wrapped command
    cat > "${TMPDIR_TEST}/bin/timeout" <<EOF
#!/bin/sh
shift  # drop timeout duration
exec "\$@"
EOF
    chmod +x "${TMPDIR_TEST}/bin/timeout"

    # Mock flock: act as no-op that just runs -c cmd
    cat > "${TMPDIR_TEST}/bin/flock" <<'EOF'
#!/bin/sh
# flock -x <file> -c 'cmd' — just run cmd
while [ $# -gt 0 ]; do
    case "$1" in
        -x|-s|-u|-n) shift ;;
        -c) shift; exec sh -c "$1" ;;
        *) shift ;;
    esac
done
EOF
    chmod +x "${TMPDIR_TEST}/bin/flock"

    # Mock nvram (no stock WG)
    cat > "${TMPDIR_TEST}/bin/nvram" <<EOF
#!/bin/sh
[ "\$1" = "get" ] && echo ""
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"

    # Load libs
    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"

    # Pre-populate valid config
    state_set "awg_enabled"           "1"
    state_set "awg_privatekey"        "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"           "10.8.0.2/24"
    state_set "awg_jc"                "4"
    state_set "awg_jmin"              "40"
    state_set "awg_jmax"              "70"
    state_set "awg_h1"                "1"
    state_set "awg_h2"                "2"
    state_set "awg_h3"                "3"
    state_set "awg_h4"                "4"
    state_set "awg_peer_publickey"    "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM="
    state_set "awg_peer_endpoint"     "example.com:51820"
    state_set "awg_peer_allowed_ips"  "0.0.0.0/0"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

# --- tunnel_is_up ---

@test "tunnel_is_up returns 0 when link and daemon present" {
    touch "${TMPDIR_TEST}/link-up"
    touch "${TMPDIR_TEST}/daemon-pid"
    tunnel_is_up
}

@test "tunnel_is_up returns 1 when link missing" {
    rm -f "${TMPDIR_TEST}/link-up"
    touch "${TMPDIR_TEST}/daemon-pid"
    ! tunnel_is_up
}

@test "tunnel_is_up returns 1 when daemon missing" {
    touch "${TMPDIR_TEST}/link-up"
    rm -f "${TMPDIR_TEST}/daemon-pid"
    ! tunnel_is_up
}

# --- tunnel_start ---

@test "tunnel_start with awg_enabled=0 is noop" {
    state_set "awg_enabled" "0"
    tunnel_start
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "tunnel_start invokes awg-quick up exactly once" {
    tunnel_start
    [ "$(grep -c '^awg-quick up' "${MOCK_LOG}")" -eq 1 ]
}

@test "tunnel_start emits awg0.conf via config_emit" {
    tunnel_start
    [ -f "${AMNEZIAWG_CONF}" ]
    grep -q '^PrivateKey = ' "${AMNEZIAWG_CONF}"
    grep -q '^Endpoint = example.com:51820' "${AMNEZIAWG_CONF}"
}

@test "tunnel_start returns 1 when config invalid" {
    state_set "awg_privatekey" "too-short"
    ! tunnel_start
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
}
```

- [ ] **Step 2: Run — 7 tests fail (tunnel.sh does not exist)**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/tunnel_test.bats 2>&1 | tail -10
```

- [ ] **Step 3: Write `addon/lib/tunnel.sh` with is_up + start**

`/Users/r00t/Desktop/AmneziaGo/addon/lib/tunnel.sh`:
```sh
#!/bin/sh
# addon/lib/tunnel.sh — awg-quick wrapper + lifecycle verbs.
# Public API: tunnel_start, tunnel_stop, tunnel_restart, tunnel_reload, tunnel_is_up

if ! command -v log_info     >/dev/null 2>&1; then echo "tunnel.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v state_get    >/dev/null 2>&1; then echo "tunnel.sh: state.sh first"  >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v config_load  >/dev/null 2>&1; then echo "tunnel.sh: config.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_CONF:=/opt/etc/amneziawg/awg0.conf}"
: "${AMNEZIAWG_INTERFACE:=awg0}"
: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"

tunnel_is_up() {
    ip link show "${AMNEZIAWG_INTERFACE}" >/dev/null 2>&1 || return 1
    pidof -x amneziawg-go >/dev/null 2>&1 || return 1
    return 0
}

_tunnel_stock_wg_check() {
    # Check stock Merlin WG client; warn but do not block (M2·decision №6).
    _wgc="$(nvram get wgc_unit 2>/dev/null)"
    if [ -n "${_wgc}" ] && [ "${_wgc}" != "0" ]; then
        _en="$(nvram get "wgc${_wgc}_enable" 2>/dev/null)"
        if [ "${_en}" = "1" ]; then
            log_warn "stock Merlin WG client wgc${_wgc} is active — routing may conflict"
        fi
    fi
}

tunnel_start() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    if [ "$(state_get awg_enabled)" != "1" ]; then
        log_info "tunnel: disabled (awg_enabled=0), not starting"
        return 0
    fi
    _tunnel_stock_wg_check
    config_load
    if ! config_validate; then
        log_error "tunnel: refusing to start with invalid config"
        return 1
    fi
    config_emit "${AMNEZIAWG_CONF}"

    : > "${AMNEZIAWG_RUNTIME}/daemon.log"

    flock -x "${AMNEZIAWG_RUNTIME}/tunnel.lock" \
        -c "awg-quick up ${AMNEZIAWG_INTERFACE}" \
        >> "${AMNEZIAWG_RUNTIME}/daemon.log" 2>&1

    # Verify: 3 retries × 1 s.
    _i=1
    while [ "${_i}" -le 3 ]; do
        if tunnel_is_up; then
            log_info "tunnel: up"
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    log_error "tunnel: failed to come up after 3 retries"
    return 1
}
```

- [ ] **Step 4: Run — 7 tests pass**

```bash
bats addon/tests/tunnel_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/tunnel.sh addon/tests/tunnel_test.bats
git commit -m "feat(tunnel): add tunnel_is_up and tunnel_start (awg-quick wrapper)"
```

---

### Task 8: `tunnel_stop`, `tunnel_restart`, `tunnel_reload`

**Files:**
- Modify: `addon/lib/tunnel.sh`
- Modify: `addon/tests/tunnel_test.bats`

- [ ] **Step 1: Append tests**

Append to `addon/tests/tunnel_test.bats`:
```bash

# --- tunnel_stop ---

@test "tunnel_stop invokes awg-quick down" {
    touch "${TMPDIR_TEST}/link-up"
    touch "${TMPDIR_TEST}/daemon-pid"
    tunnel_stop
    grep -q "^awg-quick down" "${MOCK_LOG}"
}

@test "tunnel_stop is idempotent (double call ok)" {
    tunnel_stop
    tunnel_stop
    [ "$(grep -c '^awg-quick down' "${MOCK_LOG}")" -eq 2 ]
}

@test "tunnel_stop calls pkill as safety net" {
    tunnel_stop
    grep -q "pkill" "${MOCK_LOG}"
}

# --- tunnel_restart ---

@test "tunnel_restart = stop + start in sequence" {
    tunnel_restart
    _down_line=$(grep -n "^awg-quick down" "${MOCK_LOG}" | head -1 | cut -d: -f1)
    _up_line=$(grep -n "^awg-quick up" "${MOCK_LOG}" | head -1 | cut -d: -f1)
    [ "${_down_line}" -lt "${_up_line}" ]
}

# --- tunnel_reload ---

@test "tunnel_reload is noop when config unchanged" {
    tunnel_start  # generate baseline conf
    : > "${MOCK_LOG}"
    tunnel_reload
    ! grep -q "^awg-quick down" "${MOCK_LOG}"
    ! grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "tunnel_reload restarts when config changes" {
    tunnel_start
    : > "${MOCK_LOG}"
    state_set "awg_peer_endpoint" "newhost.example:51820"
    tunnel_reload
    grep -q "^awg-quick down" "${MOCK_LOG}"
    grep -q "^awg-quick up"   "${MOCK_LOG}"
}
```

- [ ] **Step 2: Run — 6 new tests fail**

```bash
bats addon/tests/tunnel_test.bats 2>&1 | tail -10
```

- [ ] **Step 3: Append to `tunnel.sh`**

Append to `addon/lib/tunnel.sh`:
```sh

tunnel_stop() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    flock -x "${AMNEZIAWG_RUNTIME}/tunnel.lock" \
        -c "timeout 10 awg-quick down ${AMNEZIAWG_INTERFACE} 2>/dev/null || true" \
        >> "${AMNEZIAWG_RUNTIME}/daemon.log" 2>&1
    # Safety kill — awg-quick occasionally leaves daemon orphaned.
    pkill -TERM -x amneziawg-go 2>/dev/null || true
    sleep 1
    pkill -KILL -x amneziawg-go 2>/dev/null || true
    # Clean dangling link.
    ip link del "${AMNEZIAWG_INTERFACE}" 2>/dev/null || true
    log_info "tunnel: stopped"
}

tunnel_restart() {
    tunnel_stop
    tunnel_start
}

tunnel_reload() {
    # Emit a candidate conf into a temp file; compare to current.
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    config_load
    if ! config_validate; then
        log_error "tunnel_reload: invalid config, aborting"
        return 1
    fi
    _candidate="${AMNEZIAWG_RUNTIME}/awg0.candidate.$$"
    config_emit "${_candidate}"

    if [ -f "${AMNEZIAWG_CONF}" ] && cmp -s "${_candidate}" "${AMNEZIAWG_CONF}"; then
        log_info "tunnel_reload: config unchanged, noop"
        rm -f "${_candidate}"
        return 0
    fi
    rm -f "${_candidate}"
    log_info "tunnel_reload: config changed, restarting"
    tunnel_restart
}
```

- [ ] **Step 4: Run — all 13 tests pass**

```bash
bats addon/tests/tunnel_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/tunnel.sh addon/tests/tunnel_test.bats
git commit -m "feat(tunnel): add tunnel_stop, tunnel_restart, tunnel_reload"
```

---

## Phase 3 — `status.sh`

### Task 9: `status_emit_json`

**Files:**
- Create: `addon/lib/status.sh`
- Create: `addon/tests/status_test.bats`

- [ ] **Step 1: Write failing status_test.bats**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/status_test.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    export AMNEZIAWG_CONF="${TMPDIR_TEST}/awg0.conf"
    export AMNEZIAWG_WWW_USER="${TMPDIR_TEST}/www_user"
    export AMNEZIAWG_INTERFACE="awg0"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    mkdir -p "${AMNEZIAWG_RUNTIME}" "${AMNEZIAWG_WWW_USER}"

    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"

    # Default: tunnel not up
    cat > "${TMPDIR_TEST}/bin/ip"    <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
    cat > "${TMPDIR_TEST}/bin/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"
    cat > "${TMPDIR_TEST}/bin/awg"   <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"
    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"
    . "${BATS_TEST_DIRNAME}/../lib/status.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

_arm_running_state() {
    # Make tunnel_is_up return true
    cat > "${TMPDIR_TEST}/bin/ip"    <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
    cat > "${TMPDIR_TEST}/bin/pidof" <<'EOF'
#!/bin/sh
echo 1234
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"
    # awg show dump returns valid format
    cat > "${TMPDIR_TEST}/bin/awg" <<'EOF'
#!/bin/sh
if [ "$1" = "show" ] && [ "$3" = "dump" ]; then
    # Line 1: interface  (private, public, listen, fwmark)
    printf 'priv-interface-key\tpub-interface-key\t51820\toff\n'
    # Line 2: peer (pubkey, psk, endpoint, allowed_ips, latest_handshake, rx, tx, keepalive)
    printf 'pubkeypeer\t(none)\texample.com:51820\t0.0.0.0/0\t%s\t1024\t2048\t25\n' "$(( $(date +%s) - 42 ))"
fi
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"
}

@test "status_emit_json writes /tmp/amneziawg/status.json" {
    status_emit_json
    [ -f "${AMNEZIAWG_RUNTIME}/status.json" ]
}

@test "status_emit_json stopped state when tunnel down" {
    status_emit_json
    grep -q '"state":"stopped"' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json running state when tunnel up" {
    _arm_running_state
    status_emit_json
    grep -q '"state":"running"' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes handshake_age_seconds when running" {
    _arm_running_state
    status_emit_json
    grep -Eq '"handshake_age_seconds":[0-9]+' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes rx/tx bytes when running" {
    _arm_running_state
    status_emit_json
    grep -q '"rx_bytes":1024' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"tx_bytes":2048' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json mirrors to /www/user/awg_status.htm" {
    status_emit_json
    [ -f "${AMNEZIAWG_WWW_USER}/awg_status.htm" ]
    cmp -s "${AMNEZIAWG_WWW_USER}/awg_status.htm" "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json writes atomically (no .tmp leftovers)" {
    status_emit_json
    ! ls "${AMNEZIAWG_RUNTIME}"/status.json.tmp.* 2>/dev/null
}

@test "status_emit_json sets stock_wg_conflict=true when wgc1 active" {
    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
case "$2" in
    wgc_unit) echo 1 ;;
    wgc1_enable) echo 1 ;;
    *) echo "" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"
    status_emit_json
    grep -q '"stock_wg_conflict":true' "${AMNEZIAWG_RUNTIME}/status.json"
}
```

- [ ] **Step 2: Run — 8 fail**

```bash
bats addon/tests/status_test.bats 2>&1 | tail -10
```

- [ ] **Step 3: Write `addon/lib/status.sh`**

`/Users/r00t/Desktop/AmneziaGo/addon/lib/status.sh`:
```sh
#!/bin/sh
# addon/lib/status.sh — JSON status producer.
# Public: status_emit_json (writes /tmp/amneziawg/status.json and mirrors to /www/user/awg_status.htm)

if ! command -v log_info    >/dev/null 2>&1; then echo "status.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v tunnel_is_up >/dev/null 2>&1; then echo "status.sh: tunnel.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"
: "${AMNEZIAWG_WWW_USER:=/www/user}"
: "${AMNEZIAWG_INTERFACE:=awg0}"

# JSON-escape a string: escape " and \ and control chars as \n / \t.
_status_jsonq() {
    printf '%s' "$1" | awk '
        BEGIN { ORS="" }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/,  "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
        }
        { print; if (NR>1 || getline==1) printf "\\n" }
    ' | sed 's/\\n$//'
}

_status_stock_wg_conflict() {
    _wgc="$(nvram get wgc_unit 2>/dev/null)"
    [ -n "${_wgc}" ] && [ "${_wgc}" != "0" ] || { echo false; return; }
    _en="$(nvram get "wgc${_wgc}_enable" 2>/dev/null)"
    if [ "${_en}" = "1" ]; then echo true; else echo false; fi
}

status_emit_json() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    _ts="$(date +%s)"
    _state="stopped"
    _rx=0; _tx=0; _handshake_age=0
    _endpoint=""; _pubkey=""
    _enabled="false"
    _log_tail=""

    [ "$(state_get awg_enabled 2>/dev/null)" = "1" ] && _enabled="true"

    if tunnel_is_up; then
        _state="running"
        _dump="$(awg show "${AMNEZIAWG_INTERFACE}" dump 2>/dev/null)"
        if [ -n "${_dump}" ]; then
            # Line 2 = peer (tab-separated): pubkey, psk, endpoint, allowed_ips, handshake_at, rx, tx, keepalive
            _peer="$(printf '%s\n' "${_dump}" | sed -n '2p')"
            _pubkey="$(printf '%s' "${_peer}"   | cut -f1)"
            _endpoint="$(printf '%s' "${_peer}" | cut -f3)"
            _handshake_at="$(printf '%s' "${_peer}" | cut -f5)"
            _rx="$(printf '%s' "${_peer}" | cut -f6)"
            _tx="$(printf '%s' "${_peer}" | cut -f7)"
            if [ -n "${_handshake_at}" ] && [ "${_handshake_at}" -gt 0 ] 2>/dev/null; then
                _handshake_age=$((_ts - _handshake_at))
            fi
        fi
    fi

    _conflict="$(_status_stock_wg_conflict)"

    # Read last 20 lines of daemon.log for log tail.
    if [ -f "${AMNEZIAWG_RUNTIME}/daemon.log" ]; then
        _log_tail="$(tail -n 20 "${AMNEZIAWG_RUNTIME}/daemon.log" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g; s/\\/\\\\/g')"
    fi

    _tmp="${AMNEZIAWG_RUNTIME}/status.json.tmp.$$"
    {
        printf '{'
        printf '"version":"%s",'              "${AWG_VERSION:-0.0.0-dev}"
        printf '"timestamp":%s,'              "${_ts}"
        printf '"state":"%s",'                "${_state}"
        printf '"enabled":%s,'                "${_enabled}"
        printf '"interface":"%s",'            "${AMNEZIAWG_INTERFACE}"
        printf '"endpoint":"%s",'             "${_endpoint}"
        printf '"public_key":"%s",'           "${_pubkey}"
        printf '"rx_bytes":%s,'               "${_rx:-0}"
        printf '"tx_bytes":%s,'               "${_tx:-0}"
        printf '"handshake_age_seconds":%s,'  "${_handshake_age:-0}"
        printf '"stock_wg_conflict":%s,'      "${_conflict}"
        printf '"daemon_log_tail":"%s"'       "${_log_tail}"
        printf '}\n'
    } > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_RUNTIME}/status.json"

    # Mirror to WebUI polling location.
    if [ -d "${AMNEZIAWG_WWW_USER}" ]; then
        cp "${AMNEZIAWG_RUNTIME}/status.json" "${AMNEZIAWG_WWW_USER}/awg_status.htm" 2>/dev/null \
            || log_warn "status: cannot mirror to ${AMNEZIAWG_WWW_USER}/awg_status.htm"
    fi
}
```

- [ ] **Step 4: Run — all 8 tests pass**

```bash
bats addon/tests/status_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/status.sh addon/tests/status_test.bats
git commit -m "feat(status): add status_emit_json with running/stopped/conflict detection"
```

---

## Phase 4 — `watchdog.sh`

### Task 10: `watchdog.sh`

**Files:**
- Create: `addon/lib/watchdog.sh`
- Create: `addon/tests/watchdog_test.bats`

- [ ] **Step 1: Write failing bats tests**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/watchdog_test.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    export AMNEZIAWG_CONF="${TMPDIR_TEST}/awg0.conf"
    export AMNEZIAWG_WWW_USER="${TMPDIR_TEST}/www_user"
    export AMNEZIAWG_INTERFACE="awg0"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    mkdir -p "${AMNEZIAWG_RUNTIME}" "${AMNEZIAWG_WWW_USER}"

    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_LOG="${TMPDIR_TEST}/mock.log"
    : > "${MOCK_LOG}"

    # awg-quick & ip & pidof — drive tunnel_is_up and record calls
    cat > "${TMPDIR_TEST}/bin/awg-quick" <<EOF
#!/bin/sh
printf 'awg-quick %s\n' "\$*" >> "${MOCK_LOG}"
case "\$1" in
    up)   touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;;
    down) rm -f "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg-quick"
    cat > "${TMPDIR_TEST}/bin/ip" <<EOF
#!/bin/sh
[ "\$1" = "link" ] && [ "\$2" = "show" ] && {
    [ -f "${TMPDIR_TEST}/link-up" ] && exit 0 || exit 1
}
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
    cat > "${TMPDIR_TEST}/bin/pidof" <<EOF
#!/bin/sh
if [ "\$1" = "-x" ]; then shift; fi
[ "\$1" = "amneziawg-go" ] && { [ -f "${TMPDIR_TEST}/daemon-pid" ] && echo 1234 || exit 1; }
EOF
    chmod +x "${TMPDIR_TEST}/bin/pidof"
    cat > "${TMPDIR_TEST}/bin/pkill" <<EOF
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/pkill"
    cat > "${TMPDIR_TEST}/bin/timeout" <<EOF
#!/bin/sh
shift
exec "\$@"
EOF
    chmod +x "${TMPDIR_TEST}/bin/timeout"
    cat > "${TMPDIR_TEST}/bin/flock" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -x|-s|-u|-n) shift ;; -c) shift; exec sh -c "$1" ;; *) shift ;; esac; done
EOF
    chmod +x "${TMPDIR_TEST}/bin/flock"
    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"

    # awg show dump — parameterised by WATCHDOG_FAKE_HANDSHAKE_AGE env.
    cat > "${TMPDIR_TEST}/bin/awg" <<'EOF'
#!/bin/sh
if [ "$1" = "show" ] && [ "$3" = "dump" ]; then
    age="${WATCHDOG_FAKE_HANDSHAKE_AGE:-30}"
    handshake_at=$(( $(date +%s) - age ))
    printf 'priv\tpub\t51820\toff\n'
    printf 'peer-pk\t(none)\texample.com:51820\t0.0.0.0/0\t%s\t1024\t2048\t25\n' "${handshake_at}"
fi
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"
    . "${BATS_TEST_DIRNAME}/../lib/status.sh"
    . "${BATS_TEST_DIRNAME}/../lib/watchdog.sh"

    state_set "awg_enabled"           "1"
    state_set "awg_privatekey"        "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"           "10.8.0.2/24"
    state_set "awg_jc"                "4"
    state_set "awg_jmin"              "40"
    state_set "awg_jmax"              "70"
    state_set "awg_h1"                "1"
    state_set "awg_h2"                "2"
    state_set "awg_h3"                "3"
    state_set "awg_h4"                "4"
    state_set "awg_peer_publickey"    "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM="
    state_set "awg_peer_endpoint"     "example.com:51820"
    state_set "awg_peer_allowed_ips"  "0.0.0.0/0"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "watchdog_tick noop when awg_enabled=0" {
    state_set "awg_enabled" "0"
    watchdog_tick
    ! grep -q "^awg-quick" "${MOCK_LOG}"
    [ -f "${AMNEZIAWG_RUNTIME}/status.json" ]
}

@test "watchdog_tick starts tunnel when enabled but down" {
    watchdog_tick
    grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "watchdog_tick noop when tunnel up and handshake fresh" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    export WATCHDOG_FAKE_HANDSHAKE_AGE=30
    watchdog_tick
    ! grep -q "^awg-quick down" "${MOCK_LOG}"
    ! grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "watchdog_tick restarts when handshake stale (>180s)" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    export WATCHDOG_FAKE_HANDSHAKE_AGE=300
    watchdog_tick
    grep -q "^awg-quick down" "${MOCK_LOG}"
    grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "watchdog_tick rate-limits: 4th restart in 10min window is skipped" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    export WATCHDOG_FAKE_HANDSHAKE_AGE=300
    # Simulate 3 prior restarts in current window
    printf 'last_tick=%s\nrestart_win_start=%s\nrestart_count=3\n' \
        "$(( $(date +%s) - 40 ))" "$(( $(date +%s) - 60 ))" \
        > "${AMNEZIAWG_RUNTIME}/watchdog-state"
    : > "${MOCK_LOG}"
    watchdog_tick
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
    grep -q "rate-limited" "${AMNEZIAWG_LOG_FILE}"
}

@test "watchdog_tick skips overlap if called within 30s" {
    # Set last_tick to 10s ago
    printf 'last_tick=%s\n' "$(( $(date +%s) - 10 ))" \
        > "${AMNEZIAWG_RUNTIME}/watchdog-state"
    : > "${MOCK_LOG}"
    watchdog_tick
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}
```

- [ ] **Step 2: Run — 6 fail**

```bash
bats addon/tests/watchdog_test.bats 2>&1 | tail -8
```

- [ ] **Step 3: Write `addon/lib/watchdog.sh`**

`/Users/r00t/Desktop/AmneziaGo/addon/lib/watchdog.sh`:
```sh
#!/bin/sh
# addon/lib/watchdog.sh — periodic health check.
# Public: watchdog_tick (called every 60s from cru cron).

if ! command -v log_info        >/dev/null 2>&1; then echo "watchdog.sh: log.sh first"    >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v tunnel_is_up    >/dev/null 2>&1; then echo "watchdog.sh: tunnel.sh first" >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v status_emit_json >/dev/null 2>&1; then echo "watchdog.sh: status.sh first" >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"
: "${AMNEZIAWG_INTERFACE:=awg0}"

_HANDSHAKE_STALE_THRESHOLD=180
_OVERLAP_GUARD_SECONDS=30
_RESTART_WINDOW_SECONDS=600
_RESTART_WINDOW_MAX=3

_wd_read_state() {
    _last_tick=0
    _restart_win_start=0
    _restart_count=0
    if [ -f "${AMNEZIAWG_RUNTIME}/watchdog-state" ]; then
        while IFS='=' read -r _k _v; do
            case "${_k}" in
                last_tick)         _last_tick="${_v}" ;;
                restart_win_start) _restart_win_start="${_v}" ;;
                restart_count)     _restart_count="${_v}" ;;
            esac
        done < "${AMNEZIAWG_RUNTIME}/watchdog-state"
    fi
}

_wd_write_state() {
    _tmp="${AMNEZIAWG_RUNTIME}/watchdog-state.tmp.$$"
    {
        printf 'last_tick=%s\n'         "${_last_tick}"
        printf 'restart_win_start=%s\n' "${_restart_win_start}"
        printf 'restart_count=%s\n'     "${_restart_count}"
    } > "${_tmp}"
    mv "${_tmp}" "${AMNEZIAWG_RUNTIME}/watchdog-state"
}

# Increment restart counter. Returns 0 if allowed, 1 if rate-limited.
_wd_try_restart_allowed() {
    _now="$1"
    if [ "$((_now - _restart_win_start))" -gt "${_RESTART_WINDOW_SECONDS}" ]; then
        _restart_win_start="${_now}"
        _restart_count=1
        return 0
    fi
    if [ "${_restart_count}" -ge "${_RESTART_WINDOW_MAX}" ]; then
        return 1
    fi
    _restart_count=$((_restart_count + 1))
    return 0
}

watchdog_tick() {
    mkdir -p "${AMNEZIAWG_RUNTIME}"
    _now="$(date +%s)"
    _wd_read_state

    # Overlap guard
    if [ "$((_now - _last_tick))" -lt "${_OVERLAP_GUARD_SECONDS}" ]; then
        log_debug "watchdog: overlap guard, skip"
        return 0
    fi
    _last_tick="${_now}"
    _wd_write_state

    if [ "$(state_get awg_enabled)" != "1" ]; then
        status_emit_json
        return 0
    fi

    if tunnel_is_up; then
        _dump="$(awg show "${AMNEZIAWG_INTERFACE}" dump 2>/dev/null)"
        _handshake_at="$(printf '%s\n' "${_dump}" | sed -n '2p' | cut -f5)"
        if [ -z "${_handshake_at}" ] || [ "${_handshake_at}" -eq 0 ] 2>/dev/null; then
            _handshake_age=0
        else
            _handshake_age=$((_now - _handshake_at))
        fi
        if [ "${_handshake_age}" -gt "${_HANDSHAKE_STALE_THRESHOLD}" ]; then
            if _wd_try_restart_allowed "${_now}"; then
                log_warn "watchdog: stale handshake (${_handshake_age}s), restarting"
                tunnel_restart
            else
                log_warn "watchdog: rate-limited, skip restart (count=${_restart_count})"
            fi
            _wd_write_state
        fi
    else
        if _wd_try_restart_allowed "${_now}"; then
            log_warn "watchdog: tunnel down despite enabled, starting"
            tunnel_start
        else
            log_warn "watchdog: rate-limited, skip start"
        fi
        _wd_write_state
    fi

    status_emit_json
}
```

- [ ] **Step 4: Run — all 6 tests pass**

```bash
bats addon/tests/watchdog_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/watchdog.sh addon/tests/watchdog_test.bats
git commit -m "feat(watchdog): add watchdog_tick with handshake-freshness + rate-limit"
```

---

## Phase 5 — `events.sh`

### Task 11: `event_wan` with debounce + `event_service`

**Files:**
- Create: `addon/lib/events.sh`
- Create: `addon/tests/events_test.bats`

- [ ] **Step 1: Write bats tests**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/events_test.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"
    export AMNEZIAWG_RUNTIME="${TMPDIR_TEST}/runtime"
    export AMNEZIAWG_CONF="${TMPDIR_TEST}/awg0.conf"
    export AMNEZIAWG_WWW_USER="${TMPDIR_TEST}/www_user"
    export AMNEZIAWG_INTERFACE="awg0"
    : > "${AMNEZIAWG_CUSTOM_SETTINGS}"
    mkdir -p "${AMNEZIAWG_RUNTIME}" "${AMNEZIAWG_WWW_USER}"

    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_LOG="${TMPDIR_TEST}/mock.log"
    : > "${MOCK_LOG}"

    # Mocks as in tunnel tests
    for m in awg-quick ip pidof pkill; do
        case "$m" in
            awg-quick) cat > "${TMPDIR_TEST}/bin/awg-quick" <<EOF
#!/bin/sh
printf 'awg-quick %s\n' "\$*" >> "${MOCK_LOG}"
case "\$1" in up) touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;; down) rm -f "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid" ;; esac
EOF
;;
            ip) cat > "${TMPDIR_TEST}/bin/ip" <<EOF
#!/bin/sh
[ "\$1" = "link" ] && [ "\$2" = "show" ] && { [ -f "${TMPDIR_TEST}/link-up" ] && exit 0 || exit 1; }
exit 0
EOF
;;
            pidof) cat > "${TMPDIR_TEST}/bin/pidof" <<EOF
#!/bin/sh
if [ "\$1" = "-x" ]; then shift; fi
[ "\$1" = "amneziawg-go" ] && { [ -f "${TMPDIR_TEST}/daemon-pid" ] && echo 1234 || exit 1; }
EOF
;;
            pkill) cat > "${TMPDIR_TEST}/bin/pkill" <<'EOF'
#!/bin/sh
exit 0
EOF
;;
        esac
        chmod +x "${TMPDIR_TEST}/bin/$m"
    done

    cat > "${TMPDIR_TEST}/bin/timeout" <<EOF
#!/bin/sh
shift
exec "\$@"
EOF
    chmod +x "${TMPDIR_TEST}/bin/timeout"
    cat > "${TMPDIR_TEST}/bin/flock" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -x|-s|-u|-n) shift ;; -c) shift; exec sh -c "$1" ;; *) shift ;; esac; done
EOF
    chmod +x "${TMPDIR_TEST}/bin/flock"
    cat > "${TMPDIR_TEST}/bin/nvram" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/nvram"
    cat > "${TMPDIR_TEST}/bin/awg" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"
    cat > "${TMPDIR_TEST}/bin/cru" <<EOF
#!/bin/sh
printf 'cru %s\n' "\$*" >> "${MOCK_LOG}"
EOF
    chmod +x "${TMPDIR_TEST}/bin/cru"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
    . "${BATS_TEST_DIRNAME}/../lib/hooks.sh"
    . "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    . "${BATS_TEST_DIRNAME}/../lib/config.sh"
    . "${BATS_TEST_DIRNAME}/../lib/tunnel.sh"
    . "${BATS_TEST_DIRNAME}/../lib/status.sh"
    . "${BATS_TEST_DIRNAME}/../lib/events.sh"

    state_set "awg_enabled"           "1"
    state_set "awg_privatekey"        "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE="
    state_set "awg_address"           "10.8.0.2/24"
    state_set "awg_jc"                "4"
    state_set "awg_jmin"              "40"
    state_set "awg_jmax"              "70"
    state_set "awg_h1"                "1"
    state_set "awg_h2"                "2"
    state_set "awg_h3"                "3"
    state_set "awg_h4"                "4"
    state_set "awg_peer_publickey"    "Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWM="
    state_set "awg_peer_endpoint"     "example.com:51820"
    state_set "awg_peer_allowed_ips"  "0.0.0.0/0"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

# --- event_wan ---

@test "event_wan ignores unit=1" {
    event_wan 1 connected
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan ignores init/connecting types" {
    event_wan 0 init
    event_wan 0 connecting
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan connected triggers tunnel_restart" {
    event_wan 0 connected
    grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan disconnected triggers tunnel_stop" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    event_wan 0 disconnected
    grep -q "^awg-quick down" "${MOCK_LOG}"
}

@test "event_wan debounce: second call within 5s is noop" {
    event_wan 0 connected
    : > "${MOCK_LOG}"
    event_wan 0 connected
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

@test "event_wan debounce: second call after 6s is honored" {
    event_wan 0 connected
    # Back-date the debounce stamp by 10s
    printf '%s\n' "$(( $(date +%s) - 10 ))" > "${AMNEZIAWG_RUNTIME}/last-wan-action"
    : > "${MOCK_LOG}"
    event_wan 0 connected
    grep -q "^awg-quick" "${MOCK_LOG}"
}

# --- event_service ---

@test "event_service start awgstart triggers tunnel_start" {
    event_service start awgstart
    grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "event_service start awgstop triggers tunnel_stop" {
    touch "${TMPDIR_TEST}/link-up" "${TMPDIR_TEST}/daemon-pid"
    event_service start awgstop
    grep -q "^awg-quick down" "${MOCK_LOG}"
}

@test "event_service start awgrestart triggers stop+start" {
    event_service start awgrestart
    grep -q "^awg-quick down" "${MOCK_LOG}"
    grep -q "^awg-quick up"   "${MOCK_LOG}"
}

@test "event_service unknown target is noop" {
    event_service start other-addon
    ! grep -q "^awg-quick" "${MOCK_LOG}"
}

# --- event_firewall ---

@test "event_firewall is stub (M3 will extend)" {
    event_firewall eth0
    # Just confirms no crash
}

# --- event_services_start ---

@test "event_services_start installs cron entry" {
    event_services_start
    grep -q "^cru a amneziawg_watchdog" "${MOCK_LOG}"
}

@test "event_services_start starts tunnel when awg_enabled=1" {
    event_services_start
    grep -q "^awg-quick up" "${MOCK_LOG}"
}

@test "event_services_start skips tunnel_start when awg_enabled=0" {
    state_set "awg_enabled" "0"
    event_services_start
    ! grep -q "^awg-quick up" "${MOCK_LOG}"
}
```

- [ ] **Step 2: Run — 14 fail**

```bash
bats addon/tests/events_test.bats 2>&1 | tail -8
```

- [ ] **Step 3: Write `addon/lib/events.sh`**

`/Users/r00t/Desktop/AmneziaGo/addon/lib/events.sh`:
```sh
#!/bin/sh
# addon/lib/events.sh — hook dispatchers for Merlin user-scripts.
# Public: event_service, event_wan, event_firewall, event_services_start

if ! command -v log_info       >/dev/null 2>&1; then echo "events.sh: log.sh first"      >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v tunnel_start   >/dev/null 2>&1; then echo "events.sh: tunnel.sh first"   >&2; return 1 2>/dev/null || exit 1; fi

: "${AMNEZIAWG_RUNTIME:=/tmp/amneziawg}"

_EVENTS_WAN_DEBOUNCE_SEC=5

event_service() {
    _event="$1"; _target="$2"
    case "${_event},${_target}" in
        start,awgstart|restart,awgstart)    tunnel_start ;;
        start,awgstop)                      tunnel_stop ;;
        start,awgrestart)                   tunnel_restart ;;
        start,awgsaveconf)                  tunnel_reload ;;
        *) log_debug "event_service: ignoring ${_event}/${_target}" ;;
    esac
}

event_wan() {
    _unit="$1"; _type="$2"
    [ "${_unit}" = "0" ] || return 0
    case "${_type}" in
        connected|disconnected|stopped) ;;
        *) return 0 ;;
    esac

    mkdir -p "${AMNEZIAWG_RUNTIME}"
    _now="$(date +%s)"
    _last="$(cat "${AMNEZIAWG_RUNTIME}/last-wan-action" 2>/dev/null || echo 0)"
    if [ "$((_now - _last))" -lt "${_EVENTS_WAN_DEBOUNCE_SEC}" ]; then
        log_debug "event_wan: debounced (${_type})"
        return 0
    fi
    printf '%s\n' "${_now}" > "${AMNEZIAWG_RUNTIME}/last-wan-action"

    case "${_type}" in
        connected)
            if [ "$(state_get awg_enabled)" = "1" ]; then
                tunnel_restart
            fi
            ;;
        disconnected|stopped)
            tunnel_stop
            ;;
    esac
}

event_firewall() {
    _wan_if="$1"
    log_debug "event_firewall: ${_wan_if} (stub — M3 will setup PBR here)"
    # M3 hook point
}

event_services_start() {
    # Re-apply WebUI mount (idempotent).
    if command -v ui_mount >/dev/null 2>&1; then
        ui_mount
    fi
    # Install cron (idempotent via cru).
    cru a amneziawg_watchdog "* * * * * /jffs/addons/amneziawg/amneziawg.sh watchdog"
    # Boot-time autostart if enabled.
    if [ "$(state_get awg_enabled)" = "1" ]; then
        _i=1
        while [ "${_i}" -le 3 ]; do
            if tunnel_start; then
                break
            fi
            log_warn "event_services_start: tunnel_start retry ${_i}/3 (likely DNS not ready)"
            sleep 10
            _i=$((_i + 1))
        done
    fi
}
```

- [ ] **Step 4: Run — all 14 tests pass**

```bash
bats addon/tests/events_test.bats
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/events.sh addon/tests/events_test.bats
git commit -m "feat(events): add service/wan/firewall/services_start dispatchers with debounce"
```

---

## Phase 6 — `postup.sh` + `postdown.sh` stubs

### Task 12: PostUp/PostDown scripts

**Files:**
- Create: `addon/lib/postup.sh`
- Create: `addon/lib/postdown.sh`

No TDD — these are trivial stubs. Just need correct exit code and an M3 hook comment.

- [ ] **Step 1: Write `postup.sh`**

`/Users/r00t/Desktop/AmneziaGo/addon/lib/postup.sh`:
```sh
#!/bin/sh
# addon/lib/postup.sh — called by awg-quick from the `PostUp = …` line in
# awg0.conf, with $1 = interface name (e.g. "awg0").
#
# Module 2 stub. Module 3 will add here:
#   - ipset create + populate (per-policy)
#   - iptables FORWARD/INPUT/POSTROUTING rules
#   - ip rule add fwmark 0x100 lookup 300
#   - kill-switch drop rule
#   - DNS-leak protection (DNAT/REJECT)
#
# Keep output to stderr only (awg-quick will log our stdout as its own).

INTERFACE="${1:-awg0}"

# shellcheck source=/dev/null
. /jffs/addons/amneziawg/lib/log.sh 2>/dev/null || {
    # Running outside addon context (e.g. manual awg-quick), degrade silently.
    :
}

if command -v log_info >/dev/null 2>&1; then
    log_info "postup: ${INTERFACE} up (M2 stub)"
fi

# M3 hook point — end
exit 0
```

- [ ] **Step 2: Write `postdown.sh`**

`/Users/r00t/Desktop/AmneziaGo/addon/lib/postdown.sh`:
```sh
#!/bin/sh
# addon/lib/postdown.sh — called by awg-quick from the `PostDown = …` line in
# awg0.conf, with $1 = interface name. Reverse of postup.sh.
#
# Module 2 stub. Module 3 will undo what postup.sh set up: ip rule del,
# iptables -D, ipset destroy, etc.

INTERFACE="${1:-awg0}"

# shellcheck source=/dev/null
. /jffs/addons/amneziawg/lib/log.sh 2>/dev/null || :

if command -v log_info >/dev/null 2>&1; then
    log_info "postdown: ${INTERFACE} down (M2 stub)"
fi

# M3 hook point — end
exit 0
```

- [ ] **Step 3: Verify syntax + chmod**

```bash
cd /Users/r00t/Desktop/AmneziaGo
chmod +x addon/lib/postup.sh addon/lib/postdown.sh
sh -n addon/lib/postup.sh
sh -n addon/lib/postdown.sh
shellcheck -S style addon/lib/postup.sh addon/lib/postdown.sh
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add addon/lib/postup.sh addon/lib/postdown.sh
git commit -m "feat(hooks): add PostUp/PostDown stubs (M2 stub, M3 hook points)"
```

---

## Phase 7 — `state.sh` real migration

### Task 13: v1→v2 key map + `_state_ensure_backup_dir`

**Files:**
- Modify: `addon/lib/state.sh`

- [ ] **Step 1: Read current state.sh**

```bash
cd /Users/r00t/Desktop/AmneziaGo
cat addon/lib/state.sh
```

Confirm presence of two stubs: `migrate_from_v1`, `backup_before_remove`.

- [ ] **Step 2: Prepend `_V1_KEY_MAP` constant and `_state_ensure_backup_dir` helper**

Edit `addon/lib/state.sh`: locate the section `# --- v1 migration (real logic: Module 2) ---` at the bottom. Replace from that marker to end-of-file with:

```sh
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
amneziawg_enabled:awg_enabled"

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
    # Keep 5 newest tar.gz matching prefix.
    _state_ensure_backup_dir
    find "${AMNEZIAWG_BACKUP_DIR}" -maxdepth 1 -name "${_prefix}*.tar.gz" -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null \
        | awk 'NR>5' \
        | xargs rm -f 2>/dev/null || true
}

migrate_from_v1() {
    # Detect
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

    # Translate keys
    _translated=0
    printf '%s\n' "${_V1_KEY_MAP}" | while IFS=':' read -r _v1 _v2; do
        [ -n "${_v1}" ] || continue
        _val="$(state_get "${_v1}")"
        if [ -n "${_val}" ]; then
            state_set "${_v2}" "${_val}"
            state_delete "${_v1}"
        fi
    done

    # Save remaining unmigrated amneziawg_* keys
    _state_ensure_backup_dir
    awk '/^amneziawg_/ { print }' "${AMNEZIAWG_CUSTOM_SETTINGS}" \
        > "${AMNEZIAWG_UNMIGRATED_KEYS}" 2>/dev/null || :

    # Remove v1 hook invocations from /jffs/scripts/* (strict line pattern).
    for _hook in service-event firewall-start wan-event services-start; do
        _f="${AMNEZIAWG_JFFS_SCRIPTS}/${_hook}"
        [ -f "${_f}" ] || continue
        sed -i '\|^[[:space:]]*/jffs/addons/amneziawg/amneziawg\.sh|d' "${_f}" 2>/dev/null || :
    done

    # Write migration flag
    {
        printf 'migrated_at=%s\n' "${_ts}"
        printf 'v2_version=%s\n'  "${AWG_VERSION}"
        printf 'backup=%s\n'      "${_bkp}"
    } > "${AMNEZIAWG_MIGRATED_FLAG}"

    state_set "awg_last_migrated_from" "v1"
    log_info "migrate_from_v1: complete"
    return 0
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
```

- [ ] **Step 3: shellcheck + sh -n**

```bash
cd /Users/r00t/Desktop/AmneziaGo
shellcheck -S style addon/lib/state.sh
sh -n addon/lib/state.sh
```
Expected: clean (info-level SC2317 OK for pre-existing dual-use guard).

- [ ] **Step 4: Confirm existing state tests still pass**

```bash
bats addon/tests/state_test.bats
```
Expected: all 9 pass (prior tests, which covered scalar state_set/get etc., untouched).

- [ ] **Step 5: Commit**

```bash
git add addon/lib/state.sh
git commit -m "feat(state): replace migration stubs with real implementation"
```

---

### Task 14: `state_migrate_test.bats` — integration test for migration

**Files:**
- Create: `addon/tests/state_migrate_test.bats`

- [ ] **Step 1: Write full bats test**

`/Users/r00t/Desktop/AmneziaGo/addon/tests/state_migrate_test.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_CUSTOM_SETTINGS="${TMPDIR_TEST}/cs.txt"

    # Simulate v1 layout under TMPDIR so tar/rm doesn't touch real root.
    export AMNEZIAWG_V1_ADDON_DIR="${TMPDIR_TEST}/jffs/addons/amneziawg"
    export AMNEZIAWG_V1_OPT_DIR="${TMPDIR_TEST}/opt/amneziawg"
    export AMNEZIAWG_BACKUP_DIR="${TMPDIR_TEST}/opt/etc/amneziawg/backups"
    export AMNEZIAWG_V2_CONF="${TMPDIR_TEST}/opt/etc/amneziawg/awg0.conf"
    export AMNEZIAWG_UNMIGRATED_KEYS="${TMPDIR_TEST}/opt/etc/amneziawg/backups/v1-unmigrated-keys.txt"
    export AMNEZIAWG_MIGRATED_FLAG="${TMPDIR_TEST}/jffs/addons/amneziawg/.migrated-from-v1"
    export AMNEZIAWG_JFFS_SCRIPTS="${TMPDIR_TEST}/jffs/scripts"
    export AWG_VERSION="0.0.0-dev"

    mkdir -p "${AMNEZIAWG_V1_ADDON_DIR}" "${AMNEZIAWG_V1_OPT_DIR}" \
             "${AMNEZIAWG_JFFS_SCRIPTS}" \
             "$(dirname "${AMNEZIAWG_V2_CONF}")"

    # Create v1 amneziawg.sh (marker for detection)
    cat > "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh" <<'EOF'
#!/bin/sh
# Fake v1 dispatcher
case "$1" in
    stop) exit 0 ;;
esac
EOF
    chmod +x "${AMNEZIAWG_V1_ADDON_DIR}/amneziawg.sh"

    # Create v1 awg0.conf
    cp "${BATS_TEST_DIRNAME}/fixtures/v1-awg0.conf" \
       "${AMNEZIAWG_V1_OPT_DIR}/awg0.conf"

    # Pre-populate custom_settings with v1 keys (from fixture)
    cp "${BATS_TEST_DIRNAME}/fixtures/v1-custom-settings.txt" \
       "${AMNEZIAWG_CUSTOM_SETTINGS}"

    # Create hook files with v1 entries mixed in with other lines
    for h in service-event firewall-start wan-event services-start; do
        cat > "${AMNEZIAWG_JFFS_SCRIPTS}/${h}" <<EOF
#!/bin/sh
# user script
echo "user line 1"
/jffs/addons/amneziawg/amneziawg.sh ${h}_handler "\$@"
echo "user line 2 referencing amneziawg in comment"
EOF
    done

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/state.sh"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

@test "migrate_from_v1 detects v1 and proceeds" {
    run migrate_from_v1
    [ "$status" -eq 0 ]
    grep -q "v1 detected" "${AMNEZIAWG_LOG_FILE}"
}

@test "migrate_from_v1 creates backup tarball" {
    migrate_from_v1
    ls "${AMNEZIAWG_BACKUP_DIR}"/backup-v1-*.tar.gz >/dev/null
}

@test "migrate_from_v1 copies awg0.conf to v2 path" {
    migrate_from_v1
    [ -f "${AMNEZIAWG_V2_CONF}" ]
    grep -q '^PrivateKey = ' "${AMNEZIAWG_V2_CONF}"
}

@test "migrate_from_v1 translates known keys" {
    migrate_from_v1
    run state_get "awg_privatekey"
    [ "$output" = "aGFhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=" ]
    run state_get "awg_peer_endpoint"
    [ "$output" = "example.com:51820" ]
    run state_get "awg_jc"
    [ "$output" = "4" ]
}

@test "migrate_from_v1 deletes v1 keys after translation" {
    migrate_from_v1
    run state_get "amneziawg_privatekey"
    [ -z "$output" ]
}

@test "migrate_from_v1 preserves non-amneziawg keys" {
    migrate_from_v1
    run state_get "unrelated_key"
    [ "$output" = "leave_me_alone" ]
}

@test "migrate_from_v1 saves unmigrated v1 keys" {
    migrate_from_v1
    [ -f "${AMNEZIAWG_UNMIGRATED_KEYS}" ]
    grep -q "amneziawg_devices" "${AMNEZIAWG_UNMIGRATED_KEYS}"
}

@test "migrate_from_v1 removes v1 hook invocation line" {
    migrate_from_v1
    ! grep -q "/jffs/addons/amneziawg/amneziawg.sh" \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "migrate_from_v1 preserves user lines and unrelated comments" {
    migrate_from_v1
    grep -q "user line 1" "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
    grep -q "user line 2 referencing amneziawg in comment" \
        "${AMNEZIAWG_JFFS_SCRIPTS}/service-event"
}

@test "migrate_from_v1 writes migration flag" {
    migrate_from_v1
    [ -f "${AMNEZIAWG_MIGRATED_FLAG}" ]
    grep -q "migrated_at=" "${AMNEZIAWG_MIGRATED_FLAG}"
    grep -q "v2_version=" "${AMNEZIAWG_MIGRATED_FLAG}"
}

@test "migrate_from_v1 is idempotent (second call is noop)" {
    migrate_from_v1
    _ts_first=$(stat -f %m "${AMNEZIAWG_MIGRATED_FLAG}" 2>/dev/null \
                || stat -c %Y "${AMNEZIAWG_MIGRATED_FLAG}")
    sleep 1
    migrate_from_v1
    _ts_second=$(stat -f %m "${AMNEZIAWG_MIGRATED_FLAG}" 2>/dev/null \
                || stat -c %Y "${AMNEZIAWG_MIGRATED_FLAG}")
    [ "${_ts_first}" = "${_ts_second}" ]
    grep -q "no v1 detected, skipping" "${AMNEZIAWG_LOG_FILE}"
}

@test "backup_before_remove creates v2 backup tarball" {
    state_set "awg_privatekey" "xxx"
    backup_before_remove
    ls "${AMNEZIAWG_BACKUP_DIR}"/backup-v2-*.tar.gz >/dev/null
}
```

- [ ] **Step 2: Run tests — all 12 should pass**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/state_migrate_test.bats
```

If any test fails on file paths — check that the env-var defaults in `state.sh` properly take the test's override. They do (pattern `: "${VAR:=default}"`). If `stat` flag differs (macOS: `-f %m`, Linux: `-c %Y`) — the test already tries both; no fix needed.

- [ ] **Step 3: Run full suite to ensure no regression**

```bash
bats addon/tests/
```
Expected: count ≥ 30 (M1) + 61 (config) + 13 (tunnel) + 8 (status) + 6 (watchdog) + 14 (events) + 12 (migrate) = **144 total**, all green.

- [ ] **Step 4: Commit**

```bash
git add addon/tests/state_migrate_test.bats
git commit -m "test(state): add migrate_from_v1 integration tests with v1 fixture layout"
```

---

## Phase 8 — Dispatcher + install wiring

### Task 15: `amneziawg.sh` — switch `_not_implemented` → real handlers

**Files:**
- Modify: `addon/amneziawg.sh`

- [ ] **Step 1: Read current dispatcher**

```bash
cd /Users/r00t/Desktop/AmneziaGo
cat addon/amneziawg.sh
```

Confirm source order: `log → state → hooks → ui → install → firewall → pbr → geo`. Four new libs (`config`, `tunnel`, `status`, `watchdog`, `events`) must be added **after** `ui` (they depend on it indirectly via state/log) and **before** `install`.

Also verify `_not_implemented` case branches for `start|stop|restart|…`.

- [ ] **Step 2: Patch the source chain**

Edit `/Users/r00t/Desktop/AmneziaGo/addon/amneziawg.sh`:

Find this block:
```sh
. "${AWG_ADDON_DIR}/lib/log.sh"
. "${AWG_ADDON_DIR}/lib/state.sh"
. "${AWG_ADDON_DIR}/lib/hooks.sh"
. "${AWG_ADDON_DIR}/lib/ui.sh"
. "${AWG_ADDON_DIR}/lib/install.sh"
. "${AWG_ADDON_DIR}/lib/firewall.sh"
. "${AWG_ADDON_DIR}/lib/pbr.sh"
. "${AWG_ADDON_DIR}/lib/geo.sh"
```

Replace with:
```sh
. "${AWG_ADDON_DIR}/lib/log.sh"
. "${AWG_ADDON_DIR}/lib/state.sh"
. "${AWG_ADDON_DIR}/lib/hooks.sh"
. "${AWG_ADDON_DIR}/lib/ui.sh"
. "${AWG_ADDON_DIR}/lib/config.sh"
. "${AWG_ADDON_DIR}/lib/tunnel.sh"
. "${AWG_ADDON_DIR}/lib/status.sh"
. "${AWG_ADDON_DIR}/lib/watchdog.sh"
. "${AWG_ADDON_DIR}/lib/events.sh"
. "${AWG_ADDON_DIR}/lib/install.sh"
. "${AWG_ADDON_DIR}/lib/firewall.sh"
. "${AWG_ADDON_DIR}/lib/pbr.sh"
. "${AWG_ADDON_DIR}/lib/geo.sh"
```

- [ ] **Step 3: Patch the case statement**

Find:
```sh
    install)        install_run ;;
    uninstall)      uninstall_run ;;
    version)        printf '%s\n' "${AWG_VERSION}" ;;

    service_event)  _not_implemented service_event ;;
    firewall_start) _not_implemented firewall_start ;;
    wan_event)      _not_implemented wan_event ;;
    services_start) _not_implemented services_start ;;

    start|stop|restart|status|update_geo|mount_ui|watchdog|check_update|update)
        _not_implemented "${cmd}"
        ;;
```

Replace with:
```sh
    install)        install_run ;;
    uninstall)      uninstall_run ;;
    version)        printf '%s\n' "${AWG_VERSION}" ;;

    service_event)  event_service "$@" ;;
    firewall_start) event_firewall "$@" ;;
    wan_event)      event_wan "$@" ;;
    services_start) event_services_start ;;

    start)          tunnel_start ;;
    stop)           tunnel_stop ;;
    restart)        tunnel_restart ;;
    reload)         tunnel_reload ;;
    status)         status_emit_json; cat "${AMNEZIAWG_RUNTIME:-/tmp/amneziawg}/status.json" ;;
    watchdog)       watchdog_tick ;;
    mount_ui)       ui_mount ;;

    import)         config_import_from_stdin ;;

    update_geo|check_update|update)
        _not_implemented "${cmd}"
        ;;
```

- [ ] **Step 4: Patch print_usage**

Find the `print_usage()` function and replace its heredoc body with:
```sh
    cat <<EOF
Usage: ${0##*/} <subcommand> [args]

Lifecycle:
  install           - register hooks + mount webui (used from .ipk postinst)
  uninstall         - reverse install (used from .ipk prerm)
  version           - print AWG_VERSION

Tunnel:
  start             - bring awg0 up
  stop              - bring awg0 down
  restart           - stop + start
  reload            - restart only if config changed
  status            - emit status JSON and print it
  watchdog          - one periodic tick (called from cron every 60s)
  import            - parse a .conf from stdin and persist into custom_settings

Hook handlers (invoked by /jffs/scripts/* demarcated blocks):
  service_event EVENT TARGET
  firewall_start WAN_IF
  wan_event UNIT STATE
  services_start

Not implemented yet (M5/v2.x):
  update_geo, check_update, update
EOF
```

- [ ] **Step 5: Smoke-test dispatcher**

```bash
cd /Users/r00t/Desktop/AmneziaGo
chmod +x addon/amneziawg.sh
./build/version.sh

# version
AWG_ADDON_DIR="$(pwd)/addon" \
AMNEZIAWG_CUSTOM_SETTINGS=/tmp/cs-smoke.txt \
AMNEZIAWG_LOG_FILE=/tmp/log-smoke.txt \
    sh addon/amneziawg.sh version

# help
AWG_ADDON_DIR="$(pwd)/addon" \
AMNEZIAWG_CUSTOM_SETTINGS=/tmp/cs-smoke.txt \
AMNEZIAWG_LOG_FILE=/tmp/log-smoke.txt \
    sh addon/amneziawg.sh help | head -5

rm -f /tmp/cs-smoke.txt /tmp/log-smoke.txt
```
Expected: `version` prints `0.0.0-dev`. `help` prints the usage starting with `Usage:` and ends with the `update_geo, check_update, update` line.

- [ ] **Step 6: Run full bats suite — no regressions**

```bash
bats addon/tests/
```
Expected: all tests still pass (≥144).

- [ ] **Step 7: Commit**

```bash
git add addon/amneziawg.sh
git commit -m "feat(dispatcher): wire M2 handlers into amneziawg.sh

- source 5 new libs (config, tunnel, status, watchdog, events)
- replace _not_implemented with real calls for start/stop/restart/reload/
  status/watchdog/mount_ui/service_event/firewall_start/wan_event/
  services_start
- add 'import' subcommand (reads .conf from stdin)
- keep update_geo/check_update/update as _not_implemented (M5/v2.x)"
```

---

### Task 16: `install.sh` — add cron registration on install/uninstall

**Files:**
- Modify: `addon/lib/install.sh`

- [ ] **Step 1: Read current install.sh**

```bash
cat addon/lib/install.sh
```

- [ ] **Step 2: Edit install.sh**

Replace the entire file content of `/Users/r00t/Desktop/AmneziaGo/addon/lib/install.sh` with:

```sh
#!/bin/sh
# addon/lib/install.sh — install/uninstall orchestrator.

if ! command -v log_info       >/dev/null 2>&1; then echo "install.sh: log.sh first" >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v hooks_register >/dev/null 2>&1; then echo "install.sh: hooks.sh first" >&2; return 1 2>/dev/null || exit 1; fi
if ! command -v ui_mount       >/dev/null 2>&1; then echo "install.sh: ui.sh first" >&2; return 1 2>/dev/null || exit 1; fi

_CRON_ID="amneziawg_watchdog"
_CRON_SPEC="* * * * * /jffs/addons/amneziawg/amneziawg.sh watchdog"

_install_cron() {
    # cru is idempotent (replaces entry with same id)
    cru a "${_CRON_ID}" "${_CRON_SPEC}" 2>/dev/null || log_warn "install: cru unavailable, cron not installed"
}

_uninstall_cron() {
    cru d "${_CRON_ID}" 2>/dev/null || true
}

install_run() {
    log_info "install_run: registering hooks"
    hooks_register
    log_info "install_run: mounting webui"
    ui_mount
    log_info "install_run: installing cron watchdog"
    _install_cron
    log_info "install_run: migrating from v1 (if present)"
    migrate_from_v1 || true
    log_info "install complete"
}

uninstall_run() {
    log_info "uninstall_run: backing up state"
    backup_before_remove || true
    log_info "uninstall_run: stopping tunnel"
    if command -v tunnel_stop >/dev/null 2>&1; then
        tunnel_stop || true
    fi
    log_info "uninstall_run: removing cron"
    _uninstall_cron
    log_info "uninstall_run: unmounting webui"
    ui_unmount
    log_info "uninstall_run: unregistering hooks"
    hooks_unregister
    log_info "uninstall complete"
}
```

- [ ] **Step 3: Verify syntax + shellcheck**

```bash
shellcheck -S style addon/lib/install.sh
sh -n addon/lib/install.sh
bats addon/tests/
```
Expected: shellcheck clean; bats still ≥144.

- [ ] **Step 4: Commit**

```bash
git add addon/lib/install.sh
git commit -m "feat(install): wire cron (cru) registration + tunnel_stop on uninstall"
```

---

## Phase 9 — Verification and packaging

### Task 17: Full local build verification

**Files:** none (verification only)

- [ ] **Step 1: Run full bats suite**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/
```
Expected: all tests green. Record total count.

- [ ] **Step 2: Run lint suite**

```bash
shellcheck -S style \
    addon/amneziawg.sh \
    addon/lib/*.sh \
    addon/scripts/*.sh \
    build/*.sh build/ci/*.sh build/docker/build-in-container.sh \
    scripts/*.sh tools/*.sh
shfmt -d -i 2 -ci addon/ build/ scripts/ tools/
```
Expected: clean (info-level SC1091 / SC2317 notices OK — they were accepted in M1).

- [ ] **Step 3: `make lint` (CI equivalent)**

```bash
make lint
```
Expected: exit 0.

- [ ] **Step 4: Render version and rebuild ipks for aarch64**

```bash
./build/version.sh
make clean
make build-docker-aarch64
ls -la dist/aarch64/
./build/ci/check_size.sh dist
```
Expected: 3 .ipk in dist/aarch64, all within caps. merlin-addon ipk is ≤ 200 KB (new libs add ~15 KB; start point was 20 KB → expect ~35 KB).

- [ ] **Step 5: Spot-check addon ipk contents**

```bash
cd /tmp
cp /Users/r00t/Desktop/AmneziaGo/dist/aarch64/amneziawg-merlin-addon_*.ipk ./addon.ipk
mkdir addon-extract
cd addon-extract
tar xzf ../addon.ipk
tar xzf data.tar.gz
ls jffs/addons/amneziawg/lib/
```
Expected: `config.sh`, `tunnel.sh`, `status.sh`, `watchdog.sh`, `events.sh`, `postup.sh`, `postdown.sh`, plus the M1 files (`log.sh`, `state.sh`, `hooks.sh`, `ui.sh`, `install.sh`, `firewall.sh`, `pbr.sh`, `geo.sh`).

```bash
cd /
rm -rf /tmp/addon-extract /tmp/addon.ipk
```

- [ ] **Step 6: Rebuild armv7 and check**

```bash
cd /Users/r00t/Desktop/AmneziaGo
make build-docker-armv7
ls -la dist/armv7/
./build/ci/check_size.sh dist
```
Expected: same shape as aarch64, all caps OK.

- [ ] **Step 7: If any step failed — fix and re-run**

If `make build-docker-*` fails on the addon package because tar includes the new lib files but they're not executable — check `make_ipk.sh`. For M2 we keep lib files at 644 (sourced, not executed), `postup.sh`/`postdown.sh` at 755 (executed by awg-quick). If `postup/postdown` are 644 in the ipk, fix `make_ipk.sh` to chmod 755 those two files explicitly. See lines in `build/ci/make_ipk.sh` where `amneziawg-merlin-addon` case handles chmods.

- [ ] **Step 8: Commit any fixes made**

```bash
# If make_ipk.sh needed fixes:
git add build/ci/make_ipk.sh
git commit -m "fix(ipk): make postup.sh/postdown.sh executable in addon package"
```

---

### Task 18: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Edit CHANGELOG.md**

Append a new section at the top of `[Unreleased]` block:

Replace the current `## [Unreleased]` section:
```markdown
## [Unreleased]

### Build

- v2 rewrite of the build & packaging subsystem (see
  `docs/superpowers/specs/2026-04-18-module-1-build-packaging-design.md`).
```

With:
```markdown
## [Unreleased]

### Features

- Tunnel lifecycle — `amneziawg.sh start/stop/restart/reload` backed by
  `awg-quick`; custom config generator supporting AmneziaWG 2.0 range headers
  and I1-I5 signature packets; strict fail-fast validation.
- Handshake-based cron watchdog with rate-limit.
- `wan-event` handler with 5-second debounce.
- Auto-migration from v1 (with tarball backup to
  `/opt/etc/amneziawg/backups/`).
- Stock Merlin WG client detection (warn, non-blocking).

### Build

- Module 1 — v2 rewrite of the build & packaging subsystem (see
  `docs/superpowers/specs/2026-04-18-module-1-build-packaging-design.md`).
- Module 2 — tunnel lifecycle design + implementation (see
  `docs/superpowers/specs/2026-04-19-module-2-tunnel-lifecycle-design.md`).
```

- [ ] **Step 2: Commit**

```bash
cd /Users/r00t/Desktop/AmneziaGo
git add CHANGELOG.md
git commit -m "docs(changelog): document Module 2 (tunnel lifecycle) unreleased features"
```

---

## Self-review

### Spec coverage

- §2 decisions — all 9 locked in the plan: §3 (awg-quick via tunnel.sh Task 7-8), §4 (UI-only via config.sh Task 2-6), §3 (watchdog.sh Task 10), §4 (event_wan debounce Task 11), §5 (migrate_from_v1 Task 13-14), §6 (stock WG warn in tunnel_start Task 7 and status_emit_json Task 9), §7 (single peer — generator schema Task 4), §8 (fail-fast — refuse in tunnel_start Task 7), §9 (service-event actions — events.sh Task 11).
- §3 file structure — all files listed appear in Tasks 1-16.
- §4.1 schema — Task 4 `config_validate` covers every key.
- §4.2 v1→v2 map — Task 13 `_V1_KEY_MAP`.
- §4.3 I1-I5 syntax — Task 3 `_config_validate_i_sequence`.
- §4.4 public API — Tasks 2-6.
- §4.5 emitter format — Task 5 + golden fixture Task 1.
- §5 tunnel.sh — Tasks 7-8.
- §6 status JSON shape — Task 9.
- §7 watchdog — Task 10 (overlap guard, rate-limit).
- §8 events — Task 11.
- §9 migration algorithm — Task 13-14 (9 steps mapped 1:1).
- §11 DoD criteria 1-7 — covered by Tasks 2-16 and Task 17 verification. Criteria 8 & 9 are manual and out of the automated plan.
- §12 out-of-scope — respected (postup/postdown stubs stay stubs, no PBR).
- §13 risks — mitigations present (retry-on-DNS in event_services_start Task 11, timeout on awg-quick down Task 8, flock for concurrent start Task 7, backup rotation Task 13).

### Placeholder scan

No "TBD", "TODO", "implement later", "add appropriate error handling", "similar to Task N" — checked all sections.

### Type consistency

- `tunnel_is_up` consistent everywhere.
- `status_emit_json` same signature across status_test, watchdog, events.
- `config_load` / `config_validate` / `config_emit` / `config_import_from_stdin` names consistent.
- `_CFG_KEYS` used in config_load (Task 4) and config_import_from_stdin (Task 6).
- `_V1_KEY_MAP` defined Task 13, used nowhere else (only in migrate_from_v1 same file).
- `AMNEZIAWG_*` env var names consistent across libs.
- `AMNEZIAWG_INTERFACE`, `AMNEZIAWG_CONF`, `AMNEZIAWG_RUNTIME`, `AMNEZIAWG_WWW_USER`, `AMNEZIAWG_CUSTOM_SETTINGS`, `AMNEZIAWG_LOG_FILE` used identically everywhere.

No inconsistencies found.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-19-module-2-tunnel-lifecycle-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review (spec compliance then code quality) after each task. Same workflow used successfully for Module 1 (47 commits, 30 tests green).

2. **Inline Execution** — batch execution with checkpoints for review; stays in this session.

Which approach?
