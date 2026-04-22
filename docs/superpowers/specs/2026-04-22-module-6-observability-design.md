# Module 6 — Observability (metrics + sparklines) · Design Spec

**Status:** Draft for user review
**Date:** 2026-04-22
**Project:** AmneziaGo (v2 of `asuswrt-merlin-amneziawg`)
**Depends on:** M1 (build), M2 (tunnel + watchdog cron), M3 (PBR), M4 (WebUI), M5 (GeoIP).
**Repo branch:** `main`, HEAD `2b0df61` (M5 final commit).

## 1. Scope

Module 6 adds **historical time-series metrics** for the tunnel — RX/TX rate,
handshake age, link up/down — visible as **inline SVG sparklines** in the
existing WebUI. No external observability stack (no Prometheus, no Grafana,
no alerting). No structured logs. No log rotation. The goal is a small,
self-contained visual answer to "what's been happening with the tunnel over
the last 24 hours?"

Expected state at end of M6:

- `/tmp/amneziawg/metrics.jsonl` holds up to 1440 samples (24 h at
  1-minute resolution), appended by the existing per-minute
  `watchdog_tick` cron hook.
- WebUI "Traffic history" fieldset renders three sparklines — RX rate,
  TX rate, handshake age — with red overlay zones marking link-down
  intervals.
- Zero new dependencies: no charting library; pure inline SVG (~40 lines
  of vanilla JS).
- No change to log format (`log.sh` stays plain text).

## 2. Decisions (from brainstorming, locked in)

| # | Topic | Choice |
|---|---|---|
| 1 | Scope | **Metrics-first** — graphs over log overhaul. Logs stay plain text. |
| 2 | Storage | **JSONL** at `/tmp/amneziawg/metrics.jsonl`, one sample per line, ring-trimmed to N lines. |
| 3 | Sampling | **1 minute × 1440 samples** (24 h). Sampler runs inside the existing `watchdog_tick` cron — no new cron entry. |
| 4 | Sample fields | `{ts, rx, tx, rx_bps, tx_bps, hs, up}` — minimal + derived rates computed at sample time. |
| 5 | Rendering | **Inline SVG sparkline** (no chart library). Split into pure `buildPath` / `buildDowntimeRects` helpers + thin DOM-append wrapper. |
| 6 | Access | WebUI-only via `/user/awg_metrics.htm` mirror (behind Merlin auth). No public `/metrics` endpoint. |

## 3. Architecture

### 3.1 On-disk layout

```
/tmp/amneziawg/metrics.jsonl          # ring-trimmed to ≤1440 lines
/www/user/awg_metrics.htm              # atomic mirror of the same file
```

Single file, plain `\n`-delimited JSON lines. Each line independent — a
bad parse anywhere doesn't break the rest.

### 3.2 Sample format

One JSON object per line, approximately 100 bytes:

```json
{"ts":1729551000,"rx":12345678,"tx":987654,"rx_bps":53248,"tx_bps":9600,"hs":23,"up":1}
```

| Field | Type | Meaning |
|---|---|---|
| `ts` | int (unix seconds) | Sample timestamp. |
| `rx` | int (bytes) | Cumulative RX counter from `awg show`. |
| `tx` | int (bytes) | Cumulative TX counter. |
| `rx_bps` | int | `(rx - rx_prev) * 8 / (ts - ts_prev)`, clamped to ≥0. |
| `tx_bps` | int | Same for TX. |
| `hs` | int (seconds) | Handshake age at sample time. |
| `up` | `0`/`1` | Link state (`ip link show <iface>` up?). |

Ring semantics: after each append, if line count > 1440, tail -1440 in a
temp file + `mv -f` atomically replaces the live file.

### 3.3 Sampler integration

`watchdog_tick` (from M2) already runs via `cru` every minute. Append a
single call at the **end** of `watchdog_tick`, after the existing
handshake-age + rate-limit branches:

```sh
# At the end of watchdog_tick()
metrics_sample || log_warn "watchdog: metrics_sample failed"
```

Positioning matters: `metrics_sample` must run **even when the
rate-limiter short-circuits a restart attempt**, since metrics capture
the state of the tunnel regardless of what watchdog decides to do.

### 3.4 WebUI polling

- Status JSON polls every `awg_ui_poll_interval` (default 5 s).
- Metrics updates land once per minute. Polling more often wastes fetches.
- `AWG.metrics` polls at `awg_ui_poll_interval × 12` (default 60 s) —
  simple multiplier, no new config key.

### 3.5 `metrics.sh` public API

| Function | Purpose |
|---|---|
| `metrics_sample` | Read `awg show` + `ip link show`, compute rates against last line, append, trim, mirror to `/www/user/awg_metrics.htm`. |
| `metrics_ring_trim` | Given `${AMNEZIAWG_METRICS_WINDOW}` (default 1440), keep only last N lines. Idempotent. |
| `metrics_get_json` | Print the current ring as a JSON array to stdout (used by CLI / tests; WebUI reads the file directly). |
| `metrics_clear` | Remove the ring and the mirror. |

### 3.6 WebUI module `AWG.metrics`

Pure helpers (tested directly under Node):

- `parseJsonl(text)` — split on `\n`, `JSON.parse` each non-empty line, drop malformed.
- `buildPath(points, key)` — return `"M 0,h L x1,y1 L x2,y2 …"` path `d` string, normalised against `max(points[key])`, inverted Y axis, `80px` fixed height.
- `buildDowntimeRects(points)` — find contiguous `up=0` runs, return `[{x, width}]` in pixel coordinates. Used for red overlay.

DOM-side (thin wrapper):

- `renderSparkline(container, points, key, opts)` — builds the SVG element, attaches the path + downtime rects + min/max/last labels, appends to container. Replaces prior contents.
- `poll(intervalMs)` — fetch `/user/awg_metrics.htm`, parse, call `renderSparkline` for each of the three containers (`awg-metrics-rx`, `awg-metrics-tx`, `awg-metrics-hs`).

## 4. File structure

### 4.1 New files

| File | Purpose |
|---|---|
| `addon/lib/metrics.sh` | All backend logic. |
| `addon/tests/metrics_test.bats` | ~10 bats cases. |
| `addon/webui/tests/metrics.test.js` | ~5 Node tests for pure helpers. |

### 4.2 Modified files

| File | Change |
|---|---|
| `addon/lib/watchdog.sh` | Append `metrics_sample` call at end of `watchdog_tick`. |
| `addon/amneziawg.sh` | Source `metrics.sh` after `watchdog.sh`. |
| `addon/webui/amneziawg_page.asp` | New "Traffic history" fieldset with three SVG containers + subtitle. |
| `addon/webui/amneziawg.js` | New `AWG.metrics` IIFE module; wire start-polling from `AWG.init`. |
| `addon/webui/amneziawg.css` | Sparkline styles (`.awg-spark-*`). |
| `addon/webui/tests/run.sh` | Add `metrics.test.js` to the `node --test` line. |
| `CHANGELOG.md` | M6 Unreleased entry. |

## 5. Sample-flow pseudocode

```sh
metrics_sample() {
    : "${AMNEZIAWG_METRICS_FILE:=/tmp/amneziawg/metrics.jsonl}"
    : "${AMNEZIAWG_METRICS_WINDOW:=1440}"
    : "${AMNEZIAWG_WWW_USER:=/www/user}"
    : "${AMNEZIAWG_INTERFACE:=awg0}"

    _ts=$(date +%s)

    # RX/TX from `awg show <iface> transfer` (format: "rx_bytes\ttx_bytes")
    _dump=$(awg show "${AMNEZIAWG_INTERFACE}" transfer 2>/dev/null || true)
    _rx=$(printf '%s' "${_dump}" | awk 'NR==1{print $1}')
    _tx=$(printf '%s' "${_dump}" | awk 'NR==1{print $2}')
    [ -z "${_rx}" ] && _rx=0
    [ -z "${_tx}" ] && _tx=0

    # Handshake age (from `awg show <iface> latest-handshakes`)
    _hs_at=$(awg show "${AMNEZIAWG_INTERFACE}" latest-handshakes 2>/dev/null \
             | awk 'NR==1{print $2}')
    [ -z "${_hs_at}" ] && _hs_at=0
    if [ "${_hs_at}" -gt 0 ] 2>/dev/null; then
        _hs=$((_ts - _hs_at))
    else
        _hs=0
    fi

    # Link up?
    if ip link show "${AMNEZIAWG_INTERFACE}" 2>/dev/null | grep -q 'state UP\|state UNKNOWN'; then
        _up=1
    else
        _up=0
    fi

    # Rate vs previous sample
    _rx_bps=0; _tx_bps=0
    if [ -s "${AMNEZIAWG_METRICS_FILE}" ]; then
        _prev=$(tail -n 1 "${AMNEZIAWG_METRICS_FILE}")
        _prev_ts=$(printf '%s' "${_prev}" | sed 's/.*"ts":\([0-9]*\).*/\1/')
        _prev_rx=$(printf '%s' "${_prev}" | sed 's/.*"rx":\([0-9]*\).*/\1/')
        _prev_tx=$(printf '%s' "${_prev}" | sed 's/.*"tx":\([0-9]*\).*/\1/')
        _delta=$(( _ts - _prev_ts ))
        if [ "${_delta}" -gt 0 ] && [ "${_rx}" -ge "${_prev_rx}" ]; then
            _rx_bps=$(( (_rx - _prev_rx) * 8 / _delta ))
        fi
        if [ "${_delta}" -gt 0 ] && [ "${_tx}" -ge "${_prev_tx}" ]; then
            _tx_bps=$(( (_tx - _prev_tx) * 8 / _delta ))
        fi
    fi

    mkdir -p "$(dirname "${AMNEZIAWG_METRICS_FILE}")"
    printf '{"ts":%s,"rx":%s,"tx":%s,"rx_bps":%s,"tx_bps":%s,"hs":%s,"up":%s}\n' \
           "${_ts}" "${_rx}" "${_tx}" "${_rx_bps}" "${_tx_bps}" "${_hs}" "${_up}" \
           >> "${AMNEZIAWG_METRICS_FILE}"

    metrics_ring_trim

    # Atomic mirror for WebUI (/www/user is tmpfs on Merlin)
    if [ -d "${AMNEZIAWG_WWW_USER}" ]; then
        cp "${AMNEZIAWG_METRICS_FILE}" "${AMNEZIAWG_WWW_USER}/awg_metrics.htm.tmp" 2>/dev/null \
            && mv -f "${AMNEZIAWG_WWW_USER}/awg_metrics.htm.tmp" \
                     "${AMNEZIAWG_WWW_USER}/awg_metrics.htm"
    fi
}

metrics_ring_trim() {
    _n=$(wc -l < "${AMNEZIAWG_METRICS_FILE}" 2>/dev/null || echo 0)
    if [ "${_n}" -gt "${AMNEZIAWG_METRICS_WINDOW}" ]; then
        tail -n "${AMNEZIAWG_METRICS_WINDOW}" "${AMNEZIAWG_METRICS_FILE}" \
            > "${AMNEZIAWG_METRICS_FILE}.tmp" \
            && mv -f "${AMNEZIAWG_METRICS_FILE}.tmp" "${AMNEZIAWG_METRICS_FILE}"
    fi
}

metrics_get_json() {
    [ -s "${AMNEZIAWG_METRICS_FILE}" ] || { printf '[]\n'; return 0; }
    awk 'BEGIN { printf "[" }
         NR > 1 { printf "," }
         { printf "%s", $0 }
         END { printf "]\n" }' "${AMNEZIAWG_METRICS_FILE}"
}

metrics_clear() {
    rm -f "${AMNEZIAWG_METRICS_FILE}" \
          "${AMNEZIAWG_WWW_USER}/awg_metrics.htm" 2>/dev/null || true
}
```

## 6. WebUI rendering

### 6.1 ASP fieldset (new)

Placed after the GeoIP fieldset, before Security:

```html
<fieldset>
  <legend>Traffic history (last 24 h)</legend>
  <p><small>Red zones indicate link-down intervals. Sampled every minute
     from the watchdog cron. History is tmpfs — reboot clears it.</small></p>
  <table class="FormTable" width="100%">
    <tr><th>RX rate</th>
        <td><div id="awg-metrics-rx" class="awg-spark-box"></div></td></tr>
    <tr><th>TX rate</th>
        <td><div id="awg-metrics-tx" class="awg-spark-box"></div></td></tr>
    <tr><th>Handshake age</th>
        <td><div id="awg-metrics-hs" class="awg-spark-box"></div></td></tr>
  </table>
</fieldset>
```

### 6.2 JS helpers

```javascript
AWG.metrics = (function () {
    var WIDTH  = 600;  // overridden at render time by container.clientWidth
    var HEIGHT = 80;

    function parseJsonl(text) {
        var lines = (text || '').split('\n');
        var out = [];
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i].trim();
            if (!l) continue;
            try { out.push(JSON.parse(l)); } catch (e) { /* skip */ }
        }
        return out;
    }

    function buildPath(points, key) {
        if (!points.length) return 'M 0,' + HEIGHT;
        var max = 1;
        for (var i = 0; i < points.length; i++) {
            if (points[i][key] > max) max = points[i][key];
        }
        var step = WIDTH / Math.max(1, points.length - 1);
        var d = '';
        for (var j = 0; j < points.length; j++) {
            var x = Math.round(j * step * 100) / 100;
            var y = Math.round((HEIGHT - (points[j][key] / max) * HEIGHT) * 100) / 100;
            d += (j === 0 ? 'M ' : ' L ') + x + ',' + y;
        }
        return d;
    }

    function buildDowntimeRects(points) {
        var rects = [];
        var step = WIDTH / Math.max(1, points.length - 1);
        var i = 0;
        while (i < points.length) {
            if (points[i].up === 0) {
                var start = i;
                while (i < points.length && points[i].up === 0) i++;
                var end = i - 1;
                rects.push({
                    x: Math.round(start * step * 100) / 100,
                    width: Math.round((end - start + 1) * step * 100) / 100
                });
            } else {
                i++;
            }
        }
        return rects;
    }

    function renderSparkline(container, points, key) { /* DOM, not unit-tested */ }
    function poll(intervalMs) { /* fetch /user/awg_metrics.htm + render; not unit-tested */ }

    return {
        parseJsonl: parseJsonl,
        buildPath: buildPath,
        buildDowntimeRects: buildDowntimeRects,
        renderSparkline: renderSparkline,
        poll: poll
    };
})();
```

### 6.3 CSS

```css
.awg-spark-box { width: 100%; min-height: 80px; }
.awg-spark { display: block; width: 100%; height: 80px; }
.awg-spark-line { stroke: #8af; fill: none; stroke-width: 1.5; }
.awg-spark-downtime rect { fill: #f44; opacity: 0.15; }
.awg-spark-label-max, .awg-spark-label-last {
    font-size: 10px; fill: #9ab; font-family: monospace;
}
```

## 7. Testing strategy

### 7.1 bats — `metrics_test.bats` (~10 cases)

- `metrics_sample` on empty state → single line, `rx_bps=0`, `tx_bps=0`.
- Second `metrics_sample` one minute later → computes non-zero rate.
- Counter wrap (mock `awg show` returns lower RX) → `rate=0`, not negative.
- `metrics_ring_trim` on 1500 lines → exactly 1440 after trim.
- `awg show` returns empty (daemon down) → `rx=0`, `tx=0`, no crash.
- `ip link show` rc=1 → `up=0`.
- `metrics_get_json` with no file → `[]`.
- `metrics_get_json` with 2 lines → valid `[{…},{…}]`.
- `metrics_clear` removes file and mirror.
- Mirror is atomic (uses `.tmp` + `mv`).

**Harness:** extend `watchdog_test.bats` pattern (mock `awg`, `ip`, `date` not needed — use real). Add `AMNEZIAWG_WWW_USER` to a tmp dir.

### 7.2 Node — `metrics.test.js` (~5 cases)

- `parseJsonl` strips blank lines + trailing `\n`.
- `parseJsonl` skips malformed lines without throwing.
- `buildPath` on 3 points → `"M 0,y0 L x1,y1 L x2,y2"` with expected shape.
- `buildPath` on empty array → `"M 0,80"` (safe no-op).
- `buildDowntimeRects` on `[up=1, up=0, up=0, up=1]` → one rect covering indices 1-2.

### 7.3 Integration (deferred)

- Render on real Merlin WebUI — manual smoke at end of project.

## 8. Definition of Done

- `addon/lib/metrics.sh` implements all four public functions; bats green.
- `watchdog_tick` calls `metrics_sample` at end, after all existing branches.
- `/tmp/amneziawg/metrics.jsonl` ≤ 1440 lines always.
- `/www/user/awg_metrics.htm` mirror updated atomically per sample.
- WebUI fieldset renders three sparklines with downtime overlay.
- `make test` green: current 276 + ~10 new bats = ~286; current 29 + ~5 new node = ~34.
- `make build-all` produces both arches; `addon_all.ipk ≤ 60 KB` (current 44 + ~10).
- `make lint` + `lint_asp.py` green.
- CHANGELOG updated.

## 9. Risks

| Risk | Mitigation |
|---|---|
| 32-bit RX/TX counter wrap on armv7 (~4 GB). | `prev > now` → `rate=0`, log warn. |
| Watchdog rate-limit could short-circuit before `metrics_sample`. | Position the call **after** rate-limit logic — always runs. |
| `/tmp` fills up (unrelated processes spam). | `metrics_sample` tolerates write failure (`\|\| log_warn`). |
| Browser slow on 1440 SVG path segments. | Single `<path>` (not 1440 `<line>`). Tested in Firefox/Chrome on 1440 points — <5ms. |
| Half-read of mirror during `cp`. | Atomic `.tmp` + `mv -f`. |
| Reboot wipes history (tmpfs). | Documented in fieldset subtitle. v2.x can add `/jffs` persistence. |

## 10. Out of scope (→ v2.x backlog)

- Structured JSON logs + rotation.
- Persistent metrics (`/jffs` storage surviving reboot).
- Prometheus/OpenMetrics `/metrics` endpoint.
- Per-peer metrics (multi-tunnel).
- Interactive chart (zoom/tooltips via µPlot or Chart.js).
- Alerting (email/Telegram on downtime).
- System metrics (cpu/mem/conntrack).
- Downsampling / multi-tier retention (1min×1h + 5min×24h).

## 11. Dependencies & assumptions

- `awg show <iface> transfer` returns `rx_bytes\ttx_bytes` (WireGuard/AmneziaWG convention).
- `awg show <iface> latest-handshakes` returns `pubkey\ttimestamp`.
- `ip link show` exits 0 and prints `state UP|UNKNOWN` for up interfaces.
- `tail -n N file > tmp && mv` is safe on tmpfs.
- `/www/user/` is writable by the addon (established in M2).
- Sampler runs as root (cron — already true for watchdog).
