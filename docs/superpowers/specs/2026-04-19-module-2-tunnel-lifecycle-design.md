# Module 2 — Tunnel Lifecycle · Design Spec

**Status:** Draft for user review
**Date:** 2026-04-19
**Project:** AmneziaGo (v2 of `asuswrt-merlin-amneziawg`)
**Depends on:** Module 1 (build & packaging, `docs/superpowers/specs/2026-04-18-module-1-build-packaging-design.md`)
**Repo branch:** `main`, latest HEAD `bf051cb` (Module 1 complete)
**Working directory:** `/Users/r00t/Desktop/AmneziaGo/`

## 1. Scope

Module 2 makes the AmneziaWG tunnel work. It owns the life-cycle of the
`awg0` interface and the `amneziawg-go` daemon, the generation and validation
of `/opt/etc/amneziawg/awg0.conf`, periodic health checks, and migration
from v1 onto the v2 filesystem layout.

By the end of M2 the user can:

1. Import an Amnezia 2.0 `.conf` (with H1-H4 ranges and I1-I5 custom packets)
   through the Merlin WebUI; backend validates strictly and persists.
2. Hit Save+Start; tunnel comes up; `awg show awg0` shows a live handshake.
3. Browse the internet through the tunnel (full-tunnel — `AllowedIPs=0.0.0.0/0`
   written by the UI is respected by `awg-quick` routing; selective / PBR
   comes in M3).
4. Watch a status JSON refresh every ~60 seconds via a cron watchdog; a dead
   daemon or stale handshake auto-restarts within one minute.
5. Upgrade from v1 via `install-online.sh` and keep the tunnel working on v2
   without manual reconfiguration; v1 state is backed up.

Module 2 is **the last** milestone before the tunnel is usable end-to-end.
M3 (PBR), M4 (WebUI rewrite), M5 (GeoIP), M6 (observability) are polish layers
on top.

## 2. Decisions taken during brainstorming

| # | Topic | Choice |
|---|---|---|
| 1 | Tunnel lifecycle tool | `awg-quick up/down` (upstream) + own `PostUp`/`PostDown` hook scripts |
| 2 | Config source | UI-only. `custom_settings.txt` → `generate_config()` → `awg0.conf` on every start. |
| 3 | Watchdog strategy | Handshake-based, cron every 60 s, stale threshold 180 s. |
| 4 | `wan-event` response | Debounce 5 s. Act only on `connected/disconnected/stopped` for `unit=0`. |
| 5 | v1 migration | Auto-migrate on consent (installer prompt). Backup tarball into `/opt/etc/amneziawg/backups/`. |
| 6 | Stock Merlin WG coexistence | Detect `wgcN_enable=1` → warn (in log and status JSON). Do not block. |
| 7 | Scope: peers | Single peer only in M2. Multi-peer → v2.x. |
| 8 | Validation strictness | Fail-fast. `tunnel_start` refuses to run on invalid config. |
| 9 | service-event actions in M2 | `awgstart`, `awgstop`, `awgrestart`, `awgsaveconf`. `update_geo`/`check_update`/`update` deferred. |

## 3. File structure

### 3.1 New library modules in `addon/lib/`

| File | Responsibility | Depends on |
|---|---|---|
| `config.sh` | Parse, validate, emit `awg0.conf`. Knows every field (`[Interface]`, AmneziaWG Jc/S/H/I, `[Peer]`). Validates H1-range (`N` or `N-M`), I1-I5 tagged syntax, 44-char base64 keys, IP/CIDR, `host:port`. Atomic tmp+mv write. | `log.sh` |
| `tunnel.sh` | `tunnel_start`, `tunnel_stop`, `tunnel_restart`, `tunnel_reload`, `tunnel_is_up`. Wraps `awg-quick up/down`. | `log.sh`, `config.sh`, `state.sh` |
| `status.sh` | `status_emit_json` — reads `awg show awg0 dump`, `pidof`, `ip link`, composes JSON into `/tmp/amneziawg/status.json` and mirrors to `/www/user/awg_status.htm` for UI polling. | `log.sh`, `tunnel.sh` |
| `watchdog.sh` | `watchdog_tick` — periodic health check. Daemon liveness + handshake freshness + rate-limited auto-restart. | `log.sh`, `tunnel.sh`, `status.sh` |
| `events.sh` | `event_service`, `event_wan`, `event_firewall`, `event_services_start` handlers. Debounce for wan. JSON decode of `amng_custom` from UI. | `log.sh`, `tunnel.sh`, `state.sh` |
| `postup.sh` | Called by `awg-quick` from the `PostUp = …` line in the generated `awg0.conf`. In M2 it is a stub that logs and marks the M3 hook point. | `log.sh` |
| `postdown.sh` | Counterpart to PostUp. Reverse-order stub. | `log.sh` |

### 3.2 Modified existing modules

| File | Change |
|---|---|
| `addon/lib/state.sh` | Replace stubs `migrate_from_v1` and `backup_before_remove` with real implementations. Add `_V1_KEY_MAP` hardcoded rename table. Add helpers `state_list_v1_keys`, `state_ensure_backup_dir`. |
| `addon/amneziawg.sh` | Switch `_not_implemented` branches to real calls: `start`→`tunnel_start`, `stop`→`tunnel_stop`, `restart`→`tunnel_restart`, `reload`→`tunnel_reload`, `status`→`status_emit_json`, `watchdog`→`watchdog_tick`, `service_event`→`event_service`, `firewall_start`→`event_firewall`, `wan_event`→`event_wan`, `services_start`→`event_services_start`. `update_geo`/`check_update`/`update` remain `_not_implemented`. |
| `addon/lib/install.sh` | `install_run` adds cron entry via `cru a amneziawg_watchdog "* * * * * /jffs/addons/amneziawg/amneziawg.sh watchdog"`. `uninstall_run` calls `cru d amneziawg_watchdog`. |

### 3.3 Runtime layout (not in git)

```
/tmp/amneziawg/
├── status.json              # JSON, updated by status_emit_json
├── last-wan-action          # unixtime, debounce timestamp for event_wan
├── daemon.log               # stdout/stderr amneziawg-go (truncated each start)
├── watchdog-state           # last tick / restart rate-limit counters
└── tunnel.lock              # flock target for tunnel_start/stop/restart

/opt/etc/amneziawg/
├── awg0.conf                # generated target (atomic tmp+mv)
├── awg0.conf.example        # ships in addon ipk (conffiles)
└── backups/                 # M2 and M1 migration/pre-remove tarballs
    ├── backup-v1-<ts>.tar.gz
    ├── backup-v1-<ts>-keys.txt
    ├── backup-v2-<ts>.tar.gz
    └── backup-v2-<ts>-keys.txt
```

Backups live in `/opt/etc/amneziawg/backups/` (not `/jffs/addons/amneziawg/`)
so they survive `opkg remove amneziawg-merlin-addon`.

### 3.4 Tests

New bats files in `addon/tests/`:

- `config_test.bats` — parser, validator (positive/negative H1 ranges, I1-I5
  tags, base64 keys), emitter atomicity and determinism.
- `tunnel_test.bats` — mocked `awg-quick`, `pidof`, `awg`, `ip`. Start/stop/
  restart/reload/is_up.
- `status_test.bats` — mocked `awg show dump`, JSON shape stability, atomic
  write.
- `events_test.bats` — filters (unit=0, event=connected/disconnected/stopped),
  debounce, dispatch.
- `watchdog_test.bats` — handshake-age threshold, rate-limit window,
  enabled/disabled gating.
- `state_migrate_test.bats` — fixture-based full v1 layout; translate,
  backup, hook cleanup, idempotence.

Fixtures in `addon/tests/fixtures/`:

- `v1-custom-settings.txt`, `v1-awg0.conf`
- `amnezia-2.0-import.conf`
- `bad-h1.conf`, `bad-key.conf`, `bad-endpoint.conf`
- `expected-emit-full.conf` (golden output)

Total test count goal: **≥ 60 bats tests** (30 from M1 + ~30 new).

## 4. `config.sh` details

### 4.1 Schema for `custom_settings.txt` v2 keys

All keys prefixed `awg_`. Values stored as strings; structured fields (when
they arrive in v2.x) would be serialised as single-line JSON.

| Key | Type | Notes |
|---|---|---|
| `awg_enabled` | `0` or `1` | Autostart toggle |
| `awg_privatekey` | 44-char base64 | Validated |
| `awg_address` | `IP/prefix` | e.g. `10.8.0.2/24` |
| `awg_dns` | comma-separated IPs | optional |
| `awg_mtu` | int | default 1280, range 576..1500 |
| `awg_jc` | int 1..128 | junk count |
| `awg_jmin`, `awg_jmax` | int | jmax ≥ jmin |
| `awg_s1`..`awg_s4` | int | padding sizes (v1.5+: s3/s4 optional) |
| `awg_h1`..`awg_h4` | int or `int-int` | AmneziaWG 2.0 range |
| `awg_i1`..`awg_i5` | tagged string | see 4.3 |
| `awg_peer_publickey` | 44-char base64 | |
| `awg_peer_presharedkey` | 44-char base64 | optional |
| `awg_peer_endpoint` | `host:port` | host can be DNS name |
| `awg_peer_allowed_ips` | comma-separated CIDRs | |
| `awg_peer_keepalive` | int | default 25 |
| `awg_ui_poll_interval` | int seconds | UI concern, M4 |
| `awg_last_migrated_from` | v1 semver string | set by migrate_from_v1 |

Limits from Merlin addon API: keys ≤29 chars, values ≤2999 chars.

### 4.2 v1 → v2 key rename map

```
amneziawg_privatekey             → awg_privatekey
amneziawg_publickey              → awg_peer_publickey
amneziawg_presharedkey           → awg_peer_presharedkey
amneziawg_address                → awg_address
amneziawg_endpoint               → awg_peer_endpoint
amneziawg_allowedips             → awg_peer_allowed_ips
amneziawg_dns                    → awg_dns
amneziawg_mtu                    → awg_mtu
amneziawg_jc                     → awg_jc
amneziawg_jmin                   → awg_jmin
amneziawg_jmax                   → awg_jmax
amneziawg_s1..s4                 → awg_s1..s4
amneziawg_h1..h4                 → awg_h1..h4
amneziawg_i1..i5                 → awg_i1..i5
amneziawg_persistent_keepalive   → awg_peer_keepalive
amneziawg_enabled                → awg_enabled
```

v1 keys outside this table (e.g. `amneziawg_devices` — per-device policy
for PBR) are written to `/opt/etc/amneziawg/backups/v1-unmigrated-keys.txt`
to be consumed by M3 when policy routing lands.

### 4.3 I1-I5 tagged syntax

Per upstream `amneziawg-go` README:

- `<b 0x[hex]>` — literal bytes (hex, even length)
- `<r [size]>` — random bytes of size N
- `<rd [size]>` — random digits 0-9
- `<rc [size]>` — random chars a-zA-Z
- `<t>` — 4-byte unix timestamp

Validator regex per-tag:
`<(b 0x[0-9a-fA-F]+|r [0-9]+|rd [0-9]+|rc [0-9]+|t)>`

Parsed left-to-right until end of value; any residue → fail. Empty value →
the field is omitted from `awg0.conf`.

### 4.4 Public API of `config.sh`

```sh
config_load                     # reads awg_* into _cfg_<key> vars
config_validate                 # returns 1 if any invalid, logs each error
config_emit    <target-path>    # atomic tmp+mv
config_import_from_stdin        # parse .conf, validate, persist into custom_settings
config_export                   # emit current custom_settings as .conf to stdout
```

### 4.5 Emitter output (deterministic)

```ini
# Generated by amneziawg.sh — do not edit manually.
# Changes must go through the WebUI (VPN → AmneziaWG).
# VERSION: <AWG_VERSION>

[Interface]
PrivateKey = <value>
Address    = <value>
DNS        = <value>                 ; omitted if empty
MTU        = <value>                 ; default 1280

Jc   = <value>
Jmin = <value>
Jmax = <value>
S1 = <value>
S2 = <value>
S3 = <value>                         ; omitted if zero/empty
S4 = <value>                         ; omitted if zero/empty
H1 = <value-or-range>
H2 = <value-or-range>
H3 = <value-or-range>
H4 = <value-or-range>
I1 = <tagged>                        ; omitted if empty
…

PostUp   = /jffs/addons/amneziawg/lib/postup.sh %i
PostDown = /jffs/addons/amneziawg/lib/postdown.sh %i

[Peer]
PublicKey    = <value>
PresharedKey = <value>               ; omitted if empty
Endpoint     = <host:port>
AllowedIPs   = <cidr,cidr,...>
PersistentKeepalive = 25
```

Same `custom_settings.txt` → byte-identical `awg0.conf` (excluding
`Generated:` timestamp which is not included in the default emit; set
`AWG_REPRO_BUILD=1` env to suppress version-line too for test determinism).

## 5. `tunnel.sh` details

### 5.1 `tunnel_start` sequence

1. `[ "$(state_get awg_enabled)" = "1" ]` or log+return 0.
2. Stock WG conflict check: `nvram get wgc_unit` and `wgcN_enable` — warn in
   log + status JSON `stock_wg_conflict: true`.
3. `config_load && config_validate` — fail-fast on invalid.
4. `config_emit "$AMNEZIAWG_CONF"` (tmp+mv).
5. `mkdir -p $AMNEZIAWG_RUNTIME`; `: > $AMNEZIAWG_RUNTIME/daemon.log`.
6. `flock -x $AMNEZIAWG_RUNTIME/tunnel.lock -c 'awg-quick up awg0'`. Log
   stdout+stderr to `daemon.log`.
7. Verify up: `tunnel_is_up` with 3 retries × 1 s.
8. `status_emit_json`.

### 5.2 `tunnel_stop`

1. `timeout 10 awg-quick down awg0 2>/dev/null || true`.
2. Safety kill: `pkill -TERM -x amneziawg-go 2>/dev/null || true`; if still
   running after 2 s → `pkill -KILL`.
3. `ip link del awg0 2>/dev/null || true` (tolerate, awg-quick usually does
   this).
4. `status_emit_json`.

### 5.3 `tunnel_reload`

Compare byte-equality between current `awg0.conf` and freshly-emitted
candidate. If equal: no-op (log debug). If different: `tunnel_stop`,
overwrite, `tunnel_start`.

### 5.4 `tunnel_is_up`

```
ip link show awg0 >/dev/null 2>&1 && \
pidof amneziawg-go >/dev/null 2>&1
```

## 6. `status.sh` — JSON shape

```json
{
  "version":               "<AWG_VERSION>",
  "timestamp":             1713540000,
  "state":                 "running" | "stopped" | "failed",
  "enabled":               true | false,
  "interface":             "awg0",
  "endpoint":              "example.com:51820",
  "public_key":            "<base64>",
  "rx_bytes":              123456,
  "tx_bytes":              654321,
  "handshake_age_seconds": 42,
  "stock_wg_conflict":     false,
  "last_error":            "optional string",
  "daemon_log_tail":       "last 20 lines, newline-joined"
}
```

Field semantics:

- `state` = `failed` when `tunnel_start` returned non-zero last time.
- `handshake_age_seconds` = 0 if never handshaked (fresh start).
- `last_error` populated only when state ≠ running; cleared on successful
  start.

Writing: tmp+mv to `/tmp/amneziawg/status.json`, then copy to fixed path
`/www/user/awg_status.htm` (UI fetches this path for AJAX polling — stable
name, independent of the `userN.asp` slot that `am_get_webui_page`
allocated). If `/www/user/` is read-only in some context, log a warning
and keep `status.json` as the authoritative source; UI degrades gracefully.

## 7. `watchdog.sh`

### 7.1 `watchdog_tick` logic

```
1. Respect own rate-limit: read /tmp/amneziawg/watchdog-state
   If now - last_tick < 30  → return 0   (prevent overlap during slow restart)
2. Write now to last_tick
3. config_load || { status_emit_json; return 0 }  # nothing configured yet
4. [ "$(state_get awg_enabled)" = "1" ] || { status_emit_json; return 0 }
5. If tunnel_is_up:
     dump=$(awg show awg0 dump 2>/dev/null)
     handshake_at=$(awk 'NR==2 {print $5}' <<<"$dump")
     handshake_age=$((now - handshake_at))
     If handshake_age > 180:
        If restart_count_in_last_10min >= 3:
           log_warn "rate-limited, skip"
        Else:
           log_warn "stale handshake, restart"
           tunnel_restart
           increment restart counter
   Else:
     log_warn "down despite enabled, start"
     tunnel_start
     increment restart counter
6. status_emit_json
```

### 7.2 Rate-limit counters

`/tmp/amneziawg/watchdog-state` plain-text:

```
last_tick=1713540000
restart_win_start=1713539400
restart_count=2
```

Window rolls every 10 minutes. On each restart, if `now -
restart_win_start > 600` then reset window start + count=1, else
count++.

## 8. `events.sh`

### 8.1 `event_service $event $target`

Merlin fires with `$1=event` (`start`/`restart`/`stop`), `$2=target` (e.g.
`awgstart`).

```sh
case "$1,$2" in
  start,awgstart    | restart,awgstart)    tunnel_start ;;
  start,awgstop)                           tunnel_stop ;;
  start,awgrestart)                        tunnel_restart ;;
  start,awgsaveconf)                       tunnel_reload ;;
  *) : ;;
esac
```

Note: the UI's `amng_custom` JSON has already been persisted into
`custom_settings.txt` by Merlin httpd before this hook fires (Merlin's own
handling). We do not re-parse it here.

### 8.2 `event_wan $unit $type`

```sh
[ "$1" = "0" ] || return 0
case "$2" in connected|disconnected|stopped) ;; *) return 0 ;; esac

last=$(cat /tmp/amneziawg/last-wan-action 2>/dev/null || echo 0)
now=$(date +%s)
[ "$((now - last))" -ge 5 ] || return 0
printf '%s\n' "$now" > /tmp/amneziawg/last-wan-action

case "$2" in
  connected)                 [ "$(state_get awg_enabled)" = "1" ] && tunnel_restart ;;
  disconnected|stopped)      tunnel_stop ;;
esac
```

### 8.3 `event_firewall $wan_if`

M2 stub — log debug only. M3 adds `firewall_setup && pbr_setup`.

### 8.4 `event_services_start`

1. `ui_mount` (re-apply M1 bind-mount, idempotent).
2. `cru a amneziawg_watchdog "* * * * * /jffs/addons/amneziawg/amneziawg.sh watchdog"` (idempotent).
3. `[ "$(state_get awg_enabled)" = "1" ] && tunnel_start` (boot autostart).

Retry-on-DNS: if `tunnel_start` fails with a `Name or service not known`-class
error, retry up to 3× with 10 s sleep (WAN may not have finished DHCP yet).

## 9. Migration from v1 (`state.migrate_from_v1`)

Gate: installer already prompts (or `--yes`). This function executes once the
user has consented.

```
1. Detect: /jffs/addons/amneziawg/amneziawg.sh exists
           AND NOT -d /jffs/addons/amneziawg/lib
           AND NOT -f /jffs/addons/amneziawg/.migrated-from-v1
   Else: log_info "no v1 detected, skip"; return 0

2. Best-effort stop: /jffs/addons/amneziawg/amneziawg.sh stop 2>/dev/null || true
   pkill -TERM -x amneziawg-go 2>/dev/null || true
   sleep 1

3. Backup to /opt/etc/amneziawg/backups/:
   - tar czf backup-v1-<ts>.tar.gz /opt/amneziawg /jffs/addons/amneziawg
   - dump amneziawg_* keys to backup-v1-<ts>-keys.txt
   - Rotate old backups: keep 5 newest, delete older.

4. If -f /opt/amneziawg/awg0.conf:
     mkdir -p /opt/etc/amneziawg
     cp /opt/amneziawg/awg0.conf /opt/etc/amneziawg/awg0.conf
     chmod 600 /opt/etc/amneziawg/awg0.conf

5. Translate keys per _V1_KEY_MAP.

6. Save unmigrated v1 keys to /opt/etc/amneziawg/backups/v1-unmigrated-keys.txt.

7. Delete v1 hook lines from /jffs/scripts/*:
   sed -i '\|^[[:space:]]*/jffs/addons/amneziawg/amneziawg\.sh|d' …
   (pattern strict — matches only the v1 invocation line, not arbitrary
    user comments containing "amneziawg").

8. Write /jffs/addons/amneziawg/.migrated-from-v1 with timestamp and v2
   version.
```

Idempotent: second call sees the flag and returns immediately.

`backup_before_remove` (called from `prerm`):

```
TS=$(date +%Y%m%d-%H%M%S)
BKP=/opt/etc/amneziawg/backups/backup-v2-${TS}.tar.gz
mkdir -p "$(dirname "$BKP")"
tar czf "$BKP" -C / opt/etc/amneziawg jffs/addons/amneziawg 2>/dev/null || true
awk '/^awg_/ { print }' /jffs/addons/custom_settings.txt \
    > /opt/etc/amneziawg/backups/backup-v2-${TS}-keys.txt
# Rotate: keep 5 newest.
```

## 10. Testing

See §3.4 for file breakdown. Total target ≥ 60 bats tests (30 from M1 + ~30
new).

Mock strategy: PATH-inject for `awg-quick`, `awg`, `ip`, `pidof`, `cru`,
`nvram`. Pattern established in M1 `ui_test.bats`.

Integration / on-hardware verification is manual for M2 (see §11 criteria
14–15). Automated VM smoke test — backlog.

## 11. Definition of Done

1. `config.sh`, `tunnel.sh`, `status.sh`, `watchdog.sh`, `events.sh`,
   `postup.sh`, `postdown.sh` created; all bats tests green.
2. `state.sh` migration + backup functions are real; `state_migrate_test.bats`
   green with a real v1 fixture.
3. `amneziawg.sh` dispatcher delegates every M2 subcommand to the real
   handler (no `_not_implemented` for `start`/`stop`/`restart`/`reload`/
   `status`/`watchdog`/`service_event`/`firewall_start`/`wan_event`/
   `services_start`).
4. `install_run`/`uninstall_run` manage the cron entry through `cru`.
5. M1's 30 bats tests still pass; total ≥ 60 tests green.
6. `make lint` clean on all shell/yml/py files.
7. `make build-all` produces 6 `.ipk`, all under cap (`amneziawg-merlin-addon`
   ≤ 200 KB — expected growth ~15 KB).
8. Smoke test on real AArch64 router: import Amnezia 2.0 `.conf` → start →
   `awg show` shows valid handshake → `ping -I awg0 <allowed-ip>` works.
9. Migration test on real router: v1 installed → upgrade through
   `install-online.sh` → tunnel stays working on v2 with the same config.

Criteria 8 and 9 are manual verification checkpoints; they gate M2 release
but are not automated in CI.

## 12. Out of scope

- PBR, iptables, ipset, fwmark, kill-switch, DNS-leak protection — **M3**.
- WebUI JS rewrite, client-side strict validation, H1-range UI picker,
  import-parser overhaul — **M4**.
- GeoIP / v2fly domain-based selective routing — **M5**.
- Structured logging beyond INFO/WARN/ERROR, Chart.js graphs, `/health`
  endpoint, metrics export — **M6**.
- Multi-peer, multi-tunnel, server mode, in-addon self-update, amtm menu —
  **v2.x**.
- IPv6 tunnel endpoints — **v2.x** (M2 supports IPv4 endpoints only).
- Automated on-hardware integration test / QEMU smoke test — **backlog**.

## 13. Risks and mitigations

| Risk | P | Mitigation |
|---|---|---|
| `awg-quick` lacks userspace backend on Merlin busybox | Med | Smoke-test on router early. Fallback: custom tunnel.sh impl. Tracked as M2.1 refactor option. |
| Endpoint DNS not resolvable at boot time (before WAN ready) | Med | `event_services_start` retries `tunnel_start` up to 3× with 10 s sleep on NXDOMAIN. |
| `awg-quick` auto-MTU on PPPoE picks 1420 → fragmented | High | Default `awg_mtu=1280` in generator if user leaves empty; `awg-quick` respects explicit MTU. |
| `cru`-cron tick CPU on slow CPU | Low | ~2 ms on Cortex-A9; acceptable. |
| v1 hook `sed` removing wrong lines | Low | Strict pattern, only v1 invocation line. Backup tarball exists. |
| `awg-quick down` hangs | Low | `timeout 10 awg-quick down`; fallback `pkill -KILL` + `ip link del`. |
| Concurrent `tunnel_start` invocations (double-click) | Med | `flock` on `/tmp/amneziawg/tunnel.lock`. Second call waits or exits "busy". |
| Backup tarball dir growth | Low | Keep 5 newest, delete older on each migrate/backup. |

## 14. Backlog (v2.x or post-M2)

- Surface config-validation errors in status JSON for UI (M2 logs only).
- Export-config button in UI → `config_export` + download.
- Key-rotation helper (`amneziawg.sh rotate-keys`).
- Prometheus / InfluxDB metric export (M6).
- `awg0.conf.pre` overrides that merge into generated config.
- Multi-peer failover for mobile use cases.

## 15. Cross-references

- Merlin User-scripts wiki: https://github.com/RMerl/asuswrt-merlin.ng/wiki/User-scripts
- Merlin Addons API: https://github.com/RMerl/asuswrt-merlin.ng/wiki/Addons-API
- Upstream amneziawg-go README (AmneziaWG 2.0 params): in the repo root.
- Upstream wireguard-tools `wg-quick` source: `tools/src/src/wg-quick/linux.bash`.
- Module 1 spec: `docs/superpowers/specs/2026-04-18-module-1-build-packaging-design.md`.
- Module 1 plan: `docs/superpowers/plans/2026-04-18-module-1-build-packaging-plan.md`.
