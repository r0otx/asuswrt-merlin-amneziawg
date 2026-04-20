# Module 4 — WebUI (visual from v1, logic rewritten) · Design Spec

**Status:** Draft for user review
**Date:** 2026-04-20
**Project:** AmneziaGo (v2 of `asuswrt-merlin-amneziawg`)
**Depends on:** M1 (build/packaging), M2 (tunnel lifecycle), M3 (PBR/firewall/kill-switch/DNS).
**Repo branch:** `main`, HEAD `d435692` (M3 CHANGELOG committed).

## 1. Scope

Module 4 replaces v1's monolithic, XSS-prone, inline-JS WebUI with a clean
vanilla-JS/CSS/HTML implementation that fully exposes M2 + M3 backend capabilities
through the Merlin VPN → AmneziaWG page.

The **visual layout is inherited from v1** as per user feedback (documented in
auto-memory `feedback_ui_reuse_v1.md`). What changes: every line of JS and all
form submission flows are rewritten. Validation runs both client-side (immediate
UX) and backend (authoritative); client is deliberately a mirror of backend
`config.sh` / `pbr.sh` semantics, verified via shared test fixtures.

Expected state at end of M4:

- User opens `https://<router>/` → VPN → AmneziaWG → sees live status widget,
  editable tunnel config, PBR table, security toggles.
- User imports Amnezia 2.0 `.conf` via paste + preview; every field populates.
- Save & Apply submits to `start_awgsaveconf`; backend auto-detects diff and
  applies minimum (tunnel_reload + pbr_reapply_incremental + pbr_geo_apply).
- Status widget polls every N seconds and reflects daemon state, handshake age,
  RX/TX, stock-WG conflict, kill-switch armed state.
- Every dynamic DOM insertion is XSS-safe (textContent over innerHTML, escHtml
  where HTML must be built).

## 2. Decisions (from brainstorming, locked in)

| # | Topic | Choice |
|---|---|---|
| 1 | Framework | Vanilla JS; split files (`amneziawg_page.asp`, `amneziawg.js`, `amneziawg.css`). No external library dependencies. |
| 2 | Submission | Global "Save & Apply" (`action_script=start_awgsaveconf`) + separate Start/Stop/Restart control buttons. |
| 3 | Import flow | Client-side parse + preview + populate form; standard Save afterwards. |
| 4 | PBR list UI | Inline-edit table with DHCP-picker dropdown for new-device add. |
| 5 | Geo entries | Manual CIDR textarea in M4; M5 adds auto-population from v2fly. |
| 6 | Polling interval | Default 5 s, user-configurable via `awg_ui_poll_interval`. |
| 7 | XSS hygiene | Always `.textContent =` for user-controlled data; `escHtml()` only when HTML strings must be built. No `innerHTML = raw` anywhere. |
| 8 | `api.github.com` direct calls | Removed. Update-check moves to backend (M5/v2.x) or skipped. |
| 9 | Dirty tracking | `window.onbeforeunload` guard when form is modified without Save. |

## 3. File structure

### 3.1 New / modified files

| File | Op | Purpose |
|---|---|---|
| `addon/webui/amneziawg_page.asp` | overwrite | HTML layout (v1 visual inherited), thin inline bootstrap of `<% get_custom_settings(); %>` → `window._customSettingsInline`. |
| `addon/webui/amneziawg.js` | overwrite | All client JS in namespaced IIFE modules. |
| `addon/webui/amneziawg.css` | overwrite | Complements Merlin CSS. |
| `addon/lib/status.sh` | modify | Extend `status_emit_json` to include `leases` (from dnsmasq.leases) and `killswitch_armed` (flag file existence). |
| `addon/tests/status_test.bats` | modify | +2 tests for new JSON fields. |
| `addon/webui/tests/parser.test.js` | create | Node test runner, parser unit tests (5 fixtures). |
| `addon/webui/tests/validator.test.js` | create | Validator unit tests (mirror of backend rules). |
| `addon/webui/tests/helpers.js` | create | Test util: loads `amneziawg.js` into a synthetic global scope. |
| `addon/webui/tests/run.sh` | create | Wrapper: graceful-skip if Node <18, otherwise `node --test`. |
| `Makefile` | modify | `test` target adds `bash addon/webui/tests/run.sh`. |
| `build/ci/lint_asp.py` | sanity-verify | Should now pass on the rewritten .asp (v1 had violations). |

### 3.2 JS module organization (all in `amneziawg.js`)

Single file, ~800 lines, namespaced IIFE modules:

- `AWG.util` — humanizeBytes, formatAge, date formatting.
- `AWG.esc` — escHtml, escAttr.
- `AWG.parser` — `parseConf(text)` → `{ok, config|errors}`. Mirrors backend awk logic in `config_import_from_stdin`.
- `AWG.validator` — per-field + aggregate. Mirrors backend `_config_validate_*` and `config_validate`.
- `AWG.config` — readForm, populateForm, snapshot, isDirty, markDirty.
- `AWG.status` — startPolling, stopPolling, _tick, _render, _renderError.
- `AWG.pbr` — device table CRUD (inline), DHCP picker integration.
- `AWG.import` — modal lifecycle, parsePreview, populateFromPreview.
- `AWG.forms` — buildAmngCustom, submitSave, submitControl.
- `AWG.init` — DOMContentLoaded wiring.

## 4. HTML layout

Inherited from v1 visual pattern. Sections top-to-bottom:

1. Sticky status widget (state indicator, endpoint, handshake age, RX/TX, killswitch-armed badge).
2. Conflict banner (hidden unless `stock_wg_conflict=true`).
3. Tunnel Configuration fieldset (Interface + Amnezia obfuscation fields).
4. Peer fieldset (PublicKey, PresharedKey, Endpoint, AllowedIPs, PersistentKeepalive).
5. Policy-Based Routing fieldset (default policy dropdown, device inline-edit table with DHCP picker, geo entries textarea).
6. Security fieldset (killswitch strict toggle, IPv6 bypass toggle, DoH blocklist textarea).
7. Daemon Log fieldset (read-only `<pre>` with tail).
8. Footer controls: Save & Apply, Start, Stop, Restart.
9. Import modal (initially hidden; paste → Parse & Preview → Populate Form).

Hidden form inputs: `action_script`, `action_wait=10`, `amng_custom`.

Every `<input>` / `<select>` / `<textarea>` has `id="awg_<key>"` matching backend schema. On Save the form is serialized to JSON keyed by these IDs.

## 5. Parser + Validator (client-backend parity)

Both are pure functions (no DOM, no globals). Located in `amneziawg.js`.

### 5.1 `AWG.parser.parseConf(text)`

- Returns `{ok: true, config: {interface, peer}}` on success.
- Returns `{ok: false, errors: [...]}` on catastrophic parse (no PrivateKey, no sections).
- Permissive: unknown keys silently ignored.
- Keys lowercased, values trimmed, comments and blank lines skipped.
- Section routing (Interface vs Peer) matches backend awk logic in `config.sh config_import_from_stdin`.

### 5.2 `AWG.validator`

Per-field functions:
- `validateKey(s)` — 44-char base64 with `=` suffix.
- `validateAddr(s)` — IPv4/prefix, octets 0-255, prefix 0-32.
- `validateEndpoint(s)` — `host:port`, port 1-65535.
- `validateCidrList(s)` — non-empty, comma-separated IPv4 or IPv6 CIDRs.
- `validateIntRange(s, min, max)` — non-negative integer in range.
- `validateHValue(s)` — single int or `N-M` with M≥N.
- `validateISeq(s)` — empty OK; else sequence of `<t>`, `<b 0xHEX>` (even hex), `<r N>`, `<rd N>`, `<rc N>`.

Aggregate: `validateAll(config)` — runs all required + optional checks, returns `{ok, errors: []}`.

### 5.3 Parity testing

Shared fixtures in `addon/tests/fixtures/` (created in M1/M2): `amnezia-2.0-import.conf`, `bad-h1.conf`, `bad-key.conf`, `bad-endpoint.conf`.

Both bats (backend) and node tests (client) consume these files. Divergence caught automatically — any PR changing validation in `config.sh` must also update JS counterpart; tests would fail otherwise.

## 6. Forms, event handlers, submission

### 6.1 Save & Apply

1. Pre-flight validation via `validateAll(readForm())`; on error, `alert()` + abort.
2. Serialize form to JSON string.
3. Set hidden `amng_custom` input to the JSON.
4. Set hidden `action_script=start_awgsaveconf`.
5. `form.submit()`.

Merlin httpd unpacks `amng_custom` into `custom_settings.txt` (standard addon API), then fires service-event. M2 `event_service` dispatches to M3 `tunnel_reload + pbr_reapply_incremental + pbr_geo_apply`.

### 6.2 Control buttons (Start/Stop/Restart)

1. Empty hidden `amng_custom`.
2. Set `action_script=start_awg<action>`.
3. `form.submit()`.

No form data changes; only tunnel lifecycle.

### 6.3 Import modal

User paste → `AWG.parser.parseConf(text)` → `AWG.validator.validateAll(config)`:
- On errors — show inline list under textarea.
- On success — show field preview + "Populate Form" button.
- User can edit parsed fields in form after populate; Save applies.

### 6.4 PBR inline edit

- Table rows built via `document.createElement` (no `innerHTML = ...`).
- Each row: `<input>` for name/IP/MAC, `<select>` for policy, `<button>` remove.
- Input change → update in-memory `_devices[idx]` → mark dirty.
- Add new row: DHCP picker (`<select>` populated from status.leases) OR manual fields.
- On Save, `_devices[]` serializes to `awg_dev_count` + `awg_dev_<N>_*` keys.

### 6.5 Dirty tracking

`AWG.config.markDirty()` sets an internal flag on any form input change. `window.beforeunload` preventDefault when dirty. Cleared after successful submit.

## 7. Status polling

### 7.1 JSON contract (extended from M2 §6)

```json
{
  "version":               "0.0.0-dev",
  "timestamp":             1713540000,
  "state":                 "running" | "stopped" | "failed",
  "enabled":               true | false,
  "interface":             "awg0",
  "endpoint":              "host:port",
  "public_key":            "<base64>",
  "rx_bytes":              number,
  "tx_bytes":              number,
  "handshake_age_seconds": number,
  "stock_wg_conflict":     bool,
  "daemon_log_tail":       "string (last 20 lines, \\n-joined)",
  "leases":                [ {mac, ip, name}, ... max 50 ],
  "killswitch_armed":      bool
}
```

New in M4: `leases`, `killswitch_armed`.

Backend change: `addon/lib/status.sh` `status_emit_json()` extended to emit these two fields. Existing tests updated; 2 new tests added.

### 7.2 Polling behaviour

- `fetch('/user/awg_status.htm', {cache: 'no-store'})` every `awg_ui_poll_interval` seconds (default 5).
- On success: parse JSON, render widget, update log tail, conditionally refresh DHCP picker.
- On failure: mark widget `.awg-status-stale`, do not wipe last-known state; auto-recovers on next successful tick.
- Browser throttles inactive tabs (1 tick/min ceiling). Acceptable.
- Leases change detection: shallow set-compare on MAC list; only re-render picker if set actually changed.

## 8. XSS hygiene and security

- **Every dynamic DOM update** uses `.textContent = value`. `innerHTML` forbidden outside of trusted static templates.
- `escHtml()` available for building HTML strings, but never applied to user input without escaping (that's its job).
- `<% nvram_get(...) %>` ASP templates appear **only** in `<script>window._customSettingsInline = { ... };</script>` (JSON context, ASP engine escapes appropriately) and in `value="..."` attributes. Never inside a `<span>...</span>` body directly.
- `build/ci/lint_asp.py` enforces these patterns and is part of `make lint`; M4 is the first module where ASP passes cleanly.
- CSRF — inherited from Merlin httpd cookie-session. All POSTs go through standard `/start_apply.htm` which Merlin protects.
- No external resource loads (no CDN, no Google Fonts, no remote iframes). All assets in `/www/user/amneziawg*`.
- No `api.github.com` fetch from browser (v1 bug).
- No `eval()` anywhere.

## 9. Testing strategy

### 9.1 Client-side parser/validator

Node 18+ built-in test runner. `addon/webui/tests/*.test.js`.

- `parser.test.js` — loads each fixture, asserts `{ok, config}` shape, keys, values.
- `validator.test.js` — per-rule positive/negative cases (mirror of `config_test.bats`); aggregate.

`addon/webui/tests/run.sh` — gracefully skips if `node` missing or <18. Integrated into `make test`.

### 9.2 Backend extensions

- `addon/tests/status_test.bats` +2 tests for `leases` field (dnsmasq.leases parsing) and `killswitch_armed` field (flag file existence).

### 9.3 No automated browser tests

Merlin WebUI integration is manual (spec §11 item 10). Headless browser testing (Playwright/Puppeteer) against a real Merlin is out of scope for M4 — too much environment overhead; M4 scale doesn't warrant it.

## 10. CSS

`addon/webui/amneziawg.css` — ~150 lines. Extends Merlin's form_input/form_button classes.

Additions:
- `.awg-status-widget` — flex layout for header strip.
- `.awg-state-running` / `-stopped` / `-failed` — background colors (green/red/yellow).
- `.awg-conflict-banner` — warning bar style.
- `.awg-device-row.awg-policy-<p>` — subtle background per policy.
- `.awg-log-tail` — monospace, scrollable.
- `.awg-status-stale` — dims the widget when polling fails.

Inherits Merlin's existing form styling; no font/color override.

## 11. Definition of Done

1. Files from §3.1 created/modified.
2. `make lint` — clean (includes shellcheck, shfmt-optional, go-vet-advisory, yamllint, asp-lint, commitlint).
3. `bats addon/tests/` — ≥205 green (203 prior + 2 new status tests).
4. `bash addon/webui/tests/run.sh` — all Node tests green (or graceful-skip).
5. `make build-all` — 6 `.ipk`; addon-all ≤ 200 KB.
6. `build/ci/lint_asp.py` — exits 0 (first time! v1 always failed).
7. Smoke test on AArch64 router (manual):
   - Open `https://<router>/` → VPN → AmneziaWG; page loads, status widget renders.
   - Fill Tunnel section → Save & Apply → `awg0` up, status becomes `running`.
   - Add device via DHCP picker → policy=`vpn_all` → Save → `ip rule show` contains prio 99.
   - Change policy to `direct` → Save → rule changes; other connections not disrupted.
   - Stop → status `stopped`, kill-switch armed badge visible.
   - Start → status `running`, badge gone.
   - Paste Amnezia 2.0 `.conf` in Import modal → Parse & Preview → Populate Form → Save.
   - Enter garbage H1 → Parse shows validation errors inline.
   - Browser's "You have unsaved changes" prompt appears when navigating away dirty.
8. No external HTTP fetches from browser (verified via DevTools Network tab — only `/user/*.htm` on same origin).
9. No `innerHTML = rawUser` strings in `amneziawg.js` (verified via `grep -nE 'innerHTML\s*=\s*[A-Za-z_]' addon/webui/amneziawg.js` → empty).
10. After Save & Apply without any changes — backend logs show `tunnel_reload: no change, noop` AND `pbr_reapply_incremental: no state change, skip`. Zero connection disruption.

## 12. Out of scope

- GeoIP/geosite auto-download + category checkboxes — M5.
- Chart.js RX/TX graphs + health endpoint — M6.
- WebCrypto key generation — v2.x.
- In-app update checker — v2.x.
- Multi-tunnel / server mode UI — v2.x.
- Per-device DNS override — v2.x (backend unsupported).
- i18n, dark theme toggle — v2.x.
- Log search/filter — v2.x.
- Headless browser tests — v2.x.

## 13. Risks

| Risk | P | Mitigation |
|---|---|---|
| Merlin httpd `amng_custom` JSON decode issues on old builds | Low | Standard addon pattern (YazFi/FlexQoS); fallback: per-section separate actions |
| `window._customSettingsInline` malformed on special chars | Med | Escape on backend `state_set`; double-decode on client with try/catch |
| Node test runner not present | Low | run.sh graceful skip |
| v1 .asp patterns trigger lint_asp | High | Expected: M4 is when we clean them up — fix inline |
| Rebuild on every Save even when nothing changed | Low | hash-compare in tunnel_reload and pbr_reapply_incremental (already implemented) |
| Import with exotic encodings | Low | Liberal parser, tolower keys, trim whitespace |
| Fetch /user/awg_status.htm 404 on first poll | Low | M1 ui_mount ensures slot presence; client has retry-on-error |

## 14. Backlog (v2.x / post-M4)

- WebCrypto "Generate Keypair" button.
- Per-device notes/tags.
- Saved config profiles (switch between N).
- Dark mode toggle.
- Config export as `.conf` (download).
- Diff view "what will change" before Save.
- QR code for `.conf`.
- Keyboard shortcuts (Ctrl+S to save).

## 15. Addon package size projection

| Component | Estimated |
|---|---|
| `amneziawg_page.asp` | ~40 KB |
| `amneziawg.js` | ~25 KB |
| `amneziawg.css` | ~3 KB |
| `addon/lib/*.sh` | ~38 KB |
| misc (hooks, VERSION, example.conf) | ~2 KB |
| **addon_all.ipk** | **~75-90 KB** (cap 200 KB) |

## 16. Cross-references

- M1 spec: `docs/superpowers/specs/2026-04-18-module-1-build-packaging-design.md`
- M2 spec: `docs/superpowers/specs/2026-04-19-module-2-tunnel-lifecycle-design.md`
- M3 spec: `docs/superpowers/specs/2026-04-20-module-3-pbr-firewall-design.md`
- Feedback: auto-memory `feedback_ui_reuse_v1.md` (UI visual inherited from v1).
- v1 page source: `addon/webui/amneziawg_page.asp` (current — will be overwritten).
- v1 audit: tracked from M1 research (`r0otx/asuswrt-merlin-amneziawg@v1.1.6`).
- Merlin Addons API: https://github.com/RMerl/asuswrt-merlin.ng/wiki/Addons-API
- Node test runner: https://nodejs.org/api/test.html
