# Module 5 — GeoIP / v2fly auto-population · Design Spec

**Status:** Draft for user review
**Date:** 2026-04-20
**Project:** AmneziaGo (v2 of `asuswrt-merlin-amneziawg`)
**Depends on:** M1 (build/packaging), M2 (tunnel lifecycle), M3 (PBR/firewall/kill-switch/DNS), M4 (WebUI).
**Repo branch:** `main`, HEAD `b7af4ab` (M4 CHANGELOG committed).

## 1. Scope

Module 5 replaces v1's manual CIDR list (typed-in IPs, no updates, no domain
support, no bypass routing) with a maintainable, curated, auto-refreshing
GeoIP + GeoSite system driven by publicly released v2fly text lists.

It also extends M3's PBR with a fourth policy — **`vpn_except_geo`** — so the
user can route *everything through the VPN except* a selected set of
networks (e.g. "all sites except RU go through the VPN"). The opposite of
M3's `vpn_geo`.

Expected state at end of M5:

- User opens WebUI → GeoIP tab → sees 16 curated categories, each with a
  per-category **mode** selector: `off` / `vpn` / `direct`.
- User enables `ru=direct`, sets one device to policy `vpn_except_geo` → all
  traffic from that device goes via VPN, RU CIDRs/domains are returned to WAN.
- `awggeosync` cron job runs weekly (Sunday 04:00 local), downloads v2fly
  IP + domain lists for enabled categories, rebuilds ipsets, regenerates
  `dnsmasq.d/*.conf`, reloads dnsmasq only if the domain set changed.
- "Sync now" button in WebUI triggers the same flow synchronously with a
  progress indicator; last-sync timestamp and per-category error state
  visible in the status JSON.
- All network operations go over TLS; fetch failures never corrupt existing
  state (atomic file replace + graceful fallback).

## 2. Decisions (from brainstorming, locked in)

| # | Topic | Choice |
|---|---|---|
| 1 | Source | **v2fly** `geoip` (`release/text/*.txt`) + `domain-list-community` (`master/data/*`). Raw GitHub TXT files, no protobuf `.dat` parsing. |
| 2 | Curated categories | 16 fixed: `google, youtube, netflix, telegram, cloudflare, github, discord, twitter, meta, tiktok, cn, ru, by, ua, private, tor`. Plus user-defined custom list (category name = file name in v2fly). |
| 3 | Refresh schedule | Weekly via `cru` cron (Sunday 04:00 local). On-demand "Sync now" button. |
| 4 | Domain handling | `dnsmasq` `ipset=/domain/…/awg_geo_dst` or `…/awg_geo_direct` directive per category, generated into `/opt/etc/amneziawg/geo/dnsmasq.d/*.conf`. `dnsmasq.postconf` concats them. |
| 5 | Merge policy | Per-category **mode** (`off` / `vpn` / `direct`). Category contents land in exactly one of two ipsets according to mode. Manual CIDR lists stay separate from curated. Union within each ipset. |
| 6 | Security | TLS-only fetch (`curl --proto =https`), no signature verification of `.txt` (v2fly doesn't publish signed text). Pin v2fly ref to `release`/`master` (documented in `sources.env`); graceful fallback to last good state on fetch failure. |
| 7 | Inverted routing | New **4th policy** `vpn_except_geo` + new ipset `awg_geo_direct`. `RETURN` rule before `MARK` for dst ∈ `awg_geo_direct`. |
| 8 | Parallelism | Fetch up to **3** categories concurrently (semaphore); tunable via `awg_geo_sync_parallel`. |
| 9 | Recursion depth | v2fly domain files use `include:` directives; recursion capped at **3** with visited-set cycle guard. |
| 10 | Filtering | In `domain-list-community`, keep only `domain:`/`full:`/`include:` prefixes; drop `regexp:` (dnsmasq cannot handle). |

## 3. Architecture

### 3.1 On-disk layout

```
/opt/etc/amneziawg/geo/
├── ip/
│   ├── google.txt          # one CIDR per line (v2fly text format)
│   ├── ru.txt
│   └── …
├── domain/
│   ├── google.txt          # one domain per line (filtered)
│   ├── ru.txt
│   └── …
├── dnsmasq.d/
│   ├── google.conf         # ipset=/…/awg_geo_dst (or awg_geo_direct)
│   ├── ru.conf
│   └── …
├── last-sync               # unix timestamp of last successful sync
├── fetch-errors.log        # append-only; one line per failed category fetch
└── sources.env             # pinned URLs / refs (see §3.5)
```

### 3.2 State schema (`custom_settings.txt`)

New keys, all `awg_` prefixed per M1 convention:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `awg_geo_<cat>_mode` | `off`/`vpn`/`direct` | `off` | Per-category enable + routing direction. One key per curated category + per active custom category. |
| `awg_geo_categories_custom` | csv | `""` | User-defined category names (must exist in v2fly). |
| `awg_geo_entries` | csv | `""` | **Existing** from M3: manual CIDR → `awg_geo_dst` (VPN pool). |
| `awg_geo_entries_direct` | csv | `""` | **New**: manual CIDR → `awg_geo_direct` (Direct pool). |
| `awg_geo_sync_parallel` | int 1-8 | `3` | Max concurrent fetches. |
| `awg_geo_sync_weekday` | 0-6 | `0` (Sun) | Cron day. |
| `awg_geo_sync_hour` | 0-23 | `4` | Cron hour. |

**Per-device policy** (`awg_dev_N_policy`) valid values become:
`vpn_all | vpn_geo | vpn_except_geo | direct` (was `vpn_all | vpn_geo | direct`).

### 3.3 Runtime (ipsets + iptables)

Two ipsets, both `hash:net family inet maxelem 65536`:

- `awg_geo_dst` — VPN pool (existing from M3; extended to include curated VPN-mode contents).
- `awg_geo_direct` — Bypass pool (new in M5).

PBR chain `AMNEZIAWG` (mangle/PREROUTING) rules, per device with policy `vpn_except_geo`:

```
-A AMNEZIAWG -s <device_ip> -m set --match-set awg_geo_direct dst -j RETURN
-A AMNEZIAWG -s <device_ip> -j MARK --set-xmark 0x100/0xff00
```

Order: `RETURN` **before** `MARK`. Existing `vpn_all` / `vpn_geo` / `direct`
semantics unchanged.

### 3.4 Sync flow

```
geo_sync() {
  enabled = curated + custom where mode ≠ off
  mkdir -p /tmp/geo.staging/{ip,domain,dnsmasq.d}

  for cat in enabled (parallel=N):
    fetch IP   → /tmp/geo.staging/ip/<cat>.txt       (curl --proto =https -fsSL --max-time 60 --retry 2)
    fetch dom  → /tmp/geo.staging/domain/<cat>.raw
    filter domain prefixes (domain:/full:/include:)
    resolve include: recursively (depth ≤ 3, visited set)
    write       → /tmp/geo.staging/domain/<cat>.txt
    generate    → /tmp/geo.staging/dnsmasq.d/<cat>.conf
                (ipset=/<d1>/<d2>/…/<set>     where <set> = awg_geo_dst or awg_geo_direct by mode)
    on failure → append to fetch-errors.log, skip this cat (old files preserved)

  for each successful cat:
    mv -f /tmp/geo.staging/ip/<cat>.txt        /opt/etc/amneziawg/geo/ip/<cat>.txt
    mv -f /tmp/geo.staging/domain/<cat>.txt    /opt/etc/amneziawg/geo/domain/<cat>.txt
    mv -f /tmp/geo.staging/dnsmasq.d/<cat>.conf /opt/etc/amneziawg/geo/dnsmasq.d/<cat>.conf

  cleanup-pass: for cat on disk not in enabled → rm ip/<cat>.txt domain/<cat>.txt dnsmasq.d/<cat>.conf

  hash-compare dnsmasq.d/ contents; if changed → service restart_dnsmasq
  rebuild ipsets (ipset restore) from ip/*.txt + manual lists (awg_geo_entries → awg_geo_dst, awg_geo_entries_direct → awg_geo_direct)
  write last-sync timestamp
  rm -rf /tmp/geo.staging
  status_emit_json
}
```

Per-category atomic replace (not per-directory) guarantees a failed fetch
for one category never wipes the last-known-good data for any other.

### 3.5 `sources.env`

```sh
# Pinned by Module 5. Upgrade via PR / manual edit.
V2FLY_GEOIP_REPO="v2fly/geoip"
V2FLY_GEOIP_REF="release"
V2FLY_GEOIP_PATH="text"     # → raw.githubusercontent.com/$repo/$ref/$path/<cat>.txt
V2FLY_DOMAIN_REPO="v2fly/domain-list-community"
V2FLY_DOMAIN_REF="master"
V2FLY_DOMAIN_PATH="data"
FETCH_TIMEOUT=60
FETCH_RETRIES=2
```

## 4. File structure

### 4.1 New files

| File | Purpose |
|---|---|
| `addon/lib/geo.sh` | All M5 backend logic: `geo_sync / geo_list / geo_categories / geo_status / geo_clear / geo_cron_install / geo_cron_remove`. |
| `addon/lib/geo_parse.sh` | `geo_filter_domain`, `geo_resolve_includes` (kept separate for unit-test granularity). |
| `addon/etc/amneziawg/sources.env` | Template for `/opt/etc/amneziawg/geo/sources.env` (installed by M1 `install_run` into state dir). |
| `addon/tests/geo_test.bats` | bats tests for sync flow. |
| `addon/tests/geo_parse_test.bats` | bats tests for domain filter + recursion. |
| `addon/tests/pbr_except_geo_test.bats` | bats tests for 4th policy. |
| `addon/tests/mocks/mock_curl.sh` | Shared mock `curl` (URL → fixture path). |
| `addon/tests/fixtures/v2fly/ip/{google,ru,cn,private}.txt` | Sample CIDR lists. |
| `addon/tests/fixtures/v2fly/domain/{google,ru,telegram}` | Sample domain files (with `include:` chains). |

### 4.2 Modified files

| File | Change |
|---|---|
| `addon/amneziawg.sh` | Add `geo` subcommand dispatcher: `sync / list / categories / status / clear`. Add `start_awggeosync` service hook (invoked by cron + WebUI "Sync now"). |
| `addon/lib/pbr.sh` | Accept `vpn_except_geo` policy; add `pbr_geo_direct_apply` (rebuilds `awg_geo_direct` ipset); update `pbr_reapply_incremental` hash-compare to cover new ipset. |
| `addon/lib/state.sh` | Validator for `awg_geo_<cat>_mode ∈ {off,vpn,direct}`, `awg_geo_entries_direct` (csv of CIDR), `awg_geo_sync_parallel/weekday/hour`. |
| `addon/lib/dns.sh` | `dns_dnsmasq_postconf_generate` concatenates `/opt/etc/amneziawg/geo/dnsmasq.d/*.conf` into the postconf output. |
| `addon/lib/status.sh` | Extend `status_emit_json` with `geo: { last_sync, enabled_categories[], errors{} }`. |
| `addon/lib/install.sh` | Register `awggeosync` cron on install; deregister on uninstall; create `/opt/etc/amneziawg/geo/` tree; copy `sources.env`. |
| `addon/webui/amneziawg_page.asp` | New "GeoIP" fieldset: category table + manual VPN/Direct CIDR textareas + sync button. |
| `addon/webui/amneziawg.js` | New `AWG.geo` IIFE module (render curated+custom, mode selector, sync now, status). Update `AWG.pbr` to add `vpn_except_geo` option. Update `AWG.validator` for new mode enum. |
| `addon/webui/amneziawg.css` | Minor styles for category table + mode selector. |
| `addon/webui/tests/geo.test.js` | Node tests for client mode-enum validator + AWG.geo rendering helpers (JSDOM-free; test pure functions). |
| `addon/tests/status_test.bats` | +2 cases for new `geo` JSON field. |

## 5. API surface

### 5.1 `amneziawg.sh geo` subcommands

| Command | Args | Effect |
|---|---|---|
| `geo sync` | `[--force]` | Full fetch+apply flow. `--force` bypasses hash-compare. Writes `last-sync`. |
| `geo list` | `[<category>]` | List IP or domain entries for category (stdout). No args → list enabled cats. |
| `geo categories` | — | Print curated list + currently enabled custom list. |
| `geo status` | — | Emit JSON: `{last_sync, enabled, errors, ipset_counts}`. |
| `geo clear` | `[<category>\|--all]` | Remove cached files + regenerate empty ipsets. |

### 5.2 `start_awggeosync` service hook

Triggered via `service start_awggeosync` (Merlin convention). Runs
`amneziawg.sh geo sync` under a PID lock (`/tmp/amneziawg/geo.lock`) so
overlapping cron+WebUI clicks coalesce.

## 6. Testing strategy

### 6.1 Unit (bats)

- **`geo_test.bats`** (≈15 cases):
  - `geo_sync` happy path (2 enabled cats, fixture curl) → files written, ipsets populated, timestamp set.
  - Skip-unchanged: second `geo_sync` with identical fixtures → `restart_dnsmasq` **not** called (hash-compare).
  - Partial failure: one cat's curl returns rc=28 (timeout) → other cats apply; `fetch-errors.log` gets one line; old files for failed cat kept.
  - Disabled category cleanup: after toggling `google` off, `geo sync` removes `ip/google.txt`, `domain/google.txt`, `dnsmasq.d/google.conf`.
  - Parallel semaphore: 4 enabled cats, `awg_geo_sync_parallel=2` → never more than 2 concurrent curl PIDs.
  - Lock collision: second `geo sync` while first running → exits rc=0 with log note.
  - `geo clear --all` → directory trees emptied, ipsets flushed.

- **`geo_parse_test.bats`** (≈10 cases):
  - `geo_filter_domain`: drop `regexp:`, keep `domain:`/`full:`/`include:`, strip attributes after `@` and `#`.
  - `geo_resolve_includes`: 3-level chain resolves; 4-level truncates (logs warning).
  - Cycle: `a → b → a` detected, no infinite loop.
  - Missing include target → warning + continue.

- **`pbr_except_geo_test.bats`** (≈8 cases):
  - `vpn_except_geo` device: iptables rules contain `RETURN` before `MARK` with correct ipset name.
  - Transition `vpn_geo → vpn_except_geo`: incremental reapply flips rule order.
  - Empty `awg_geo_direct`: ipset created but policy still works (just no bypass matches).
  - Migration: legacy state without new keys still loads (defaults applied).

### 6.2 Unit (Node `--test`)

- `geo.test.js` (≈5 cases): mode-enum validator, AWG.geo pure helpers (category key building, mode→ipset mapping).

### 6.3 Mocks & fixtures

- `mock_curl.sh` — reads `$MOCK_CURL_FIXTURES_DIR` + URL suffix → serves the local file. Supports `MOCK_CURL_FAIL_URLS` (regex → rc) for failure injection.
- `mock_cru` — noop stub; tests assert `cru` was called with correct args via invocation log.
- Fixtures under `addon/tests/fixtures/v2fly/`; shared with Node tests for parity (copy-on-test via `run.sh`).

### 6.4 Integration (deferred to on-hardware smoke)

- Real v2fly fetch over public internet (scheduled for end-of-project manual test).
- Real dnsmasq reload and RU-bypass routing validation from a client device.

## 7. Definition of Done

- `addon/lib/geo.sh` + `geo_parse.sh` implement all subcommands; all bats tests pass.
- `addon/lib/pbr.sh` supports `vpn_except_geo`; both ipsets rebuilt on reapply.
- `state.sh` validates new keys; migration from M4 state is lossless.
- WebUI renders category mode table, both manual CIDR lists, "Sync now" button, and per-category error badges.
- `awggeosync` cron registers via `cru` on install; unregisters on uninstall.
- `dnsmasq.postconf` concatenates generated `.conf` files without breaking M3 behaviour.
- `make test` green: 205 prior bats + ~33 new bats + 21 prior node + ~5 new node cases.
- `make build-all` produces both arch ipks; `addon_all.ipk ≤ 200 KB` (current 36 KB; M5 adds ~8-12 KB).
- Spec + plan committed to `main`; CHANGELOG updated.

## 8. Risks

| Risk | Mitigation |
|---|---|
| v2fly repo/structure changes (rename, branch move). | Pin refs in `sources.env`; fetch failures do **not** wipe existing state; monitoring via `fetch-errors.log` + status JSON. |
| ipset `hash:net` overflow (RU ≈ 17k CIDR, composite sets > 65k). | `maxelem=65536`; if overflow → document and suggest user disables large cats; future v2.x can introduce multi-set sharding. |
| dnsmasq restart on every sync breaks UDP sessions. | Hash-compare generated `dnsmasq.d/` contents; restart only when changed. |
| Domain `include:` cycles → infinite loop. | Depth cap 3 + visited-set; warning logged on clamp. |
| busybox `curl` lacks `--fail-with-body`. | Explicit HTTP-code check via `-w '%{http_code}'` + `-o`; rc=22 on `--fail`. |
| Cron fires during active WAN reconnect → fetch fails. | Retry once with 30 s backoff inside `geo_sync`; if still fails, keep old state and log. |
| User mis-types custom category name (404 from v2fly). | Report per-category error in status; don't abort whole sync. |
| Race: WebUI "Sync now" while cron running. | PID lock at `/tmp/amneziawg/geo.lock`; second caller exits gracefully. |

## 9. Out of scope (→ v2.x backlog)

- Custom source URLs (non-v2fly lists).
- Per-device geo pools (pools stay global; per-device direction is via policy).
- MaxMind / IPinfo integration.
- Cosign signature verification of `.dat` (v2fly doesn't sign `.txt`).
- Diff-only sync (delta downloads).
- GeoIP-based DNS return-path (policy-routing DNS answers).
- In-WebUI browser of category contents (list view; would bloat UI for 17k RU CIDR).

## 10. Dependencies & assumptions

- Router has outbound HTTPS to `raw.githubusercontent.com` (both ipv4 + ipv6 fine).
- Entware `curl` ≥ 7.70 installed (comes with M1 base). `flock`, `awk`, `sed` busybox-provided.
- `ipset` supports `hash:net` + `create ... -exist` + `restore` (Merlin stock 6.x+).
- `dnsmasq` in router supports `ipset=` directive (Merlin default).
- `cru` available for cron registration (Asus stock).
- M3's `awg_geo_dst` ipset name is stable; M5 only extends its population strategy.
