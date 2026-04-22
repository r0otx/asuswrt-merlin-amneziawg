# Module 6 — Observability (Metrics + Sparklines) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add historical time-series metrics for the tunnel (RX/TX rate, handshake age, link up/down) with inline SVG sparklines in the existing WebUI — no charting library, no external observability stack.

**Architecture:** One-line JSONL append per minute from `watchdog_tick` into `/tmp/amneziawg/metrics.jsonl`, ring-trimmed to 1440 samples (24 h). Atomic mirror to `/www/user/awg_metrics.htm`. WebUI fetches the file every 60 s, renders three pure-SVG sparklines (`<path>` + red `<rect>` overlay for downtime).

**Tech Stack:** POSIX shell (busybox ash), bats-core tests, Node 18+ `--test` for JS helpers, vanilla JS + inline SVG, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-04-22-module-6-observability-design.md`

**Starting point:** M5 complete at commit `a79ed7c` (current `main`).

---

## File structure

### Created in M6

- `addon/lib/metrics.sh` — public: `metrics_sample`, `metrics_ring_trim`, `metrics_get_json`, `metrics_clear`.
- `addon/tests/metrics_test.bats` — ~10 bats cases with mocked `awg` / `ip`.
- `addon/webui/tests/metrics.test.js` — ~5 Node tests for pure helpers.

### Modified in M6

- `addon/lib/watchdog.sh` — append `metrics_sample` call at the end of `watchdog_tick` (after `status_emit_json`).
- `addon/amneziawg.sh` — source `metrics.sh` after `watchdog.sh`.
- `addon/webui/amneziawg_page.asp` — add "Traffic history" fieldset with three SVG containers.
- `addon/webui/amneziawg.js` — add `AWG.metrics` IIFE module; wire polling in `AWG.init`.
- `addon/webui/amneziawg.css` — add sparkline styles.
- `addon/webui/tests/run.sh` — include `metrics.test.js`.
- `CHANGELOG.md` — M6 Unreleased entry.

---

## Constants (used across all tasks)

```sh
# Defaults (overridable via env — required for tests)
: "${AMNEZIAWG_METRICS_FILE:=/tmp/amneziawg/metrics.jsonl}"
: "${AMNEZIAWG_METRICS_WINDOW:=1440}"
: "${AMNEZIAWG_WWW_USER:=/www/user}"
: "${AMNEZIAWG_INTERFACE:=awg0}"
```

---

## Phase 1 — Backend `metrics.sh`

### Task 1: Bootstrap `metrics.sh` + `metrics_clear` + `metrics_get_json`

**Files:**
- Create: `addon/lib/metrics.sh`
- Create: `addon/tests/metrics_test.bats`

- [ ] **Step 1: Create `addon/tests/metrics_test.bats` with the first failing tests**

```bash
#!/usr/bin/env bats
# shellcheck disable=SC2034

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR_TEST
    export AMNEZIAWG_LOG_FILE="${TMPDIR_TEST}/log.out"
    export AMNEZIAWG_METRICS_FILE="${TMPDIR_TEST}/metrics.jsonl"
    export AMNEZIAWG_METRICS_WINDOW=1440
    export AMNEZIAWG_WWW_USER="${TMPDIR_TEST}/www_user"
    export AMNEZIAWG_INTERFACE="awg0"
    mkdir -p "${AMNEZIAWG_WWW_USER}"

    . "${BATS_TEST_DIRNAME}/../lib/log.sh"
    . "${BATS_TEST_DIRNAME}/../lib/metrics.sh"
}

teardown() { rm -rf "${TMPDIR_TEST}"; }

@test "metrics_get_json returns [] when file missing" {
    run metrics_get_json
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "metrics_get_json wraps JSONL lines into a JSON array" {
    printf '{"ts":1,"rx":100}\n{"ts":2,"rx":200}\n' > "${AMNEZIAWG_METRICS_FILE}"
    run metrics_get_json
    [ "$status" -eq 0 ]
    [ "$output" = '[{"ts":1,"rx":100},{"ts":2,"rx":200}]' ]
}

@test "metrics_clear removes ring and mirror" {
    printf '{}\n' > "${AMNEZIAWG_METRICS_FILE}"
    printf '{}\n' > "${AMNEZIAWG_WWW_USER}/awg_metrics.htm"
    metrics_clear
    [ ! -f "${AMNEZIAWG_METRICS_FILE}" ]
    [ ! -f "${AMNEZIAWG_WWW_USER}/awg_metrics.htm" ]
}
```

- [ ] **Step 2: Run — 3 failures (metrics.sh missing)**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/metrics_test.bats 2>&1 | tail -5
```

- [ ] **Step 3: Create `addon/lib/metrics.sh` skeleton**

```sh
#!/bin/sh
# addon/lib/metrics.sh — per-minute tunnel metrics with a JSONL ring buffer.
# Public:
#   metrics_sample       # snapshot + append one sample (called from watchdog_tick)
#   metrics_ring_trim    # keep only last ${AMNEZIAWG_METRICS_WINDOW} lines
#   metrics_get_json     # stdout: current ring as a JSON array
#   metrics_clear        # remove ring + /www/user mirror

if ! command -v log_info >/dev/null 2>&1; then
    echo "metrics.sh: log.sh must be sourced first" >&2
    return 1 2>/dev/null || exit 1
fi

: "${AMNEZIAWG_METRICS_FILE:=/tmp/amneziawg/metrics.jsonl}"
: "${AMNEZIAWG_METRICS_WINDOW:=1440}"
: "${AMNEZIAWG_WWW_USER:=/www/user}"
: "${AMNEZIAWG_INTERFACE:=awg0}"

metrics_get_json() {
    if [ ! -s "${AMNEZIAWG_METRICS_FILE}" ]; then
        printf '[]\n'
        return 0
    fi
    awk 'BEGIN { printf "[" }
         NR > 1 { printf "," }
         { printf "%s", $0 }
         END { printf "]\n" }' "${AMNEZIAWG_METRICS_FILE}"
}

metrics_clear() {
    rm -f "${AMNEZIAWG_METRICS_FILE}" \
          "${AMNEZIAWG_WWW_USER}/awg_metrics.htm" 2>/dev/null || true
}

# Implemented in Task 2
metrics_ring_trim() { log_warn "metrics_ring_trim: not implemented (Task 2)"; return 1; }
# Implemented in Task 3
metrics_sample() { log_warn "metrics_sample: not implemented (Task 3)"; return 1; }
```

- [ ] **Step 4: Re-run — 3/3 pass**

```bash
bats addon/tests/metrics_test.bats 2>&1 | tail -5
```

Expected: `ok 1..3`. Note that `metrics_get_json`'s JSON output assertion has no trailing newline because bats' `$output` captures stripped.

- [ ] **Step 5: Commit**

```bash
git add addon/lib/metrics.sh addon/tests/metrics_test.bats
git commit -m "feat(metrics): add skeleton with metrics_get_json + metrics_clear"
```

### Task 2: `metrics_ring_trim`

**Files:**
- Modify: `addon/lib/metrics.sh`
- Modify: `addon/tests/metrics_test.bats`

- [ ] **Step 1: Append failing tests**

```bash

@test "metrics_ring_trim is a noop when line count <= window" {
    # Reduce window for test speed
    export AMNEZIAWG_METRICS_WINDOW=5
    printf '{"ts":1}\n{"ts":2}\n{"ts":3}\n' > "${AMNEZIAWG_METRICS_FILE}"
    metrics_ring_trim
    [ "$(wc -l < "${AMNEZIAWG_METRICS_FILE}")" = "3" ]
}

@test "metrics_ring_trim keeps only last N lines when oversized" {
    export AMNEZIAWG_METRICS_WINDOW=3
    printf '{"ts":1}\n{"ts":2}\n{"ts":3}\n{"ts":4}\n{"ts":5}\n' > "${AMNEZIAWG_METRICS_FILE}"
    metrics_ring_trim
    [ "$(wc -l < "${AMNEZIAWG_METRICS_FILE}")" = "3" ]
    head -1 "${AMNEZIAWG_METRICS_FILE}" | grep -q '"ts":3'
    tail -1 "${AMNEZIAWG_METRICS_FILE}" | grep -q '"ts":5'
}

@test "metrics_ring_trim tolerates missing file" {
    rm -f "${AMNEZIAWG_METRICS_FILE}"
    run metrics_ring_trim
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run — 3 failures**

```bash
bats addon/tests/metrics_test.bats 2>&1 | tail -10
```

- [ ] **Step 3: Replace the stub with real implementation**

In `addon/lib/metrics.sh`, replace the `metrics_ring_trim` stub line with:

```sh
metrics_ring_trim() {
    [ -s "${AMNEZIAWG_METRICS_FILE}" ] || return 0
    _n="$(wc -l < "${AMNEZIAWG_METRICS_FILE}" 2>/dev/null)"
    [ -n "${_n}" ] || return 0
    if [ "${_n}" -gt "${AMNEZIAWG_METRICS_WINDOW}" ] 2>/dev/null; then
        _tmp="${AMNEZIAWG_METRICS_FILE}.trim.$$"
        tail -n "${AMNEZIAWG_METRICS_WINDOW}" "${AMNEZIAWG_METRICS_FILE}" > "${_tmp}" \
            && mv -f "${_tmp}" "${AMNEZIAWG_METRICS_FILE}"
    fi
}
```

- [ ] **Step 4: Run — 6/6 pass**

```bash
bats addon/tests/metrics_test.bats 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/metrics.sh addon/tests/metrics_test.bats
git commit -m "feat(metrics): implement metrics_ring_trim (tail -n window + atomic mv)"
```

### Task 3: `metrics_sample` — snapshot + rate + atomic mirror

**Files:**
- Modify: `addon/lib/metrics.sh`
- Modify: `addon/tests/metrics_test.bats`

- [ ] **Step 1: Extend `setup()` in `addon/tests/metrics_test.bats` to install mock `awg` and `ip`**

Find the existing `setup()` and add these lines **after** the `mkdir -p "${AMNEZIAWG_WWW_USER}"` line and **before** sourcing libs:

```bash
    mkdir -p "${TMPDIR_TEST}/bin"
    export PATH="${TMPDIR_TEST}/bin:${PATH}"
    export MOCK_AWG_LOG="${TMPDIR_TEST}/awg.log"

    # mock `awg show <iface> transfer` and `awg show <iface> latest-handshakes`
    cat > "${TMPDIR_TEST}/bin/awg" <<'EOF'
#!/bin/sh
: "${MOCK_AWG_RX:=0}"
: "${MOCK_AWG_TX:=0}"
: "${MOCK_AWG_HANDSHAKE_AT:=0}"
: "${MOCK_AWG_FAIL:=0}"
printf '%s\n' "$*" >> "${MOCK_AWG_LOG}"
if [ "${MOCK_AWG_FAIL}" = "1" ]; then exit 1; fi
case "$3" in
    transfer)          printf '%s\t%s\n' "${MOCK_AWG_RX}" "${MOCK_AWG_TX}" ;;
    latest-handshakes) printf 'fakepubkey\t%s\n' "${MOCK_AWG_HANDSHAKE_AT}" ;;
esac
EOF
    chmod +x "${TMPDIR_TEST}/bin/awg"

    # mock `ip link show <iface>` — MOCK_IP_LINK_UP=1 → exit 0 and print UP
    cat > "${TMPDIR_TEST}/bin/ip" <<'EOF'
#!/bin/sh
: "${MOCK_IP_LINK_UP:=1}"
if [ "$1" = "link" ] && [ "$2" = "show" ]; then
    if [ "${MOCK_IP_LINK_UP}" = "1" ]; then
        printf '5: awg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 state UNKNOWN\n'
        exit 0
    else
        exit 1
    fi
fi
EOF
    chmod +x "${TMPDIR_TEST}/bin/ip"
```

Then append the new tests:

```bash

@test "metrics_sample from empty state writes one line with rate=0" {
    export MOCK_AWG_RX=1000000 MOCK_AWG_TX=500000 MOCK_AWG_HANDSHAKE_AT=0 MOCK_IP_LINK_UP=1
    metrics_sample
    [ -s "${AMNEZIAWG_METRICS_FILE}" ]
    _line="$(cat "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_line}" | grep -q '"rx":1000000'
    echo "${_line}" | grep -q '"tx":500000'
    echo "${_line}" | grep -q '"rx_bps":0'
    echo "${_line}" | grep -q '"tx_bps":0'
    echo "${_line}" | grep -q '"up":1'
}

@test "metrics_sample computes rate vs previous sample" {
    # Seed a previous sample 60 s ago. Use a timestamp relative to 'now' so
    # the rate is deterministic.
    _now=$(date +%s)
    _prev_ts=$((_now - 60))
    printf '{"ts":%s,"rx":1000000,"tx":500000,"rx_bps":0,"tx_bps":0,"hs":0,"up":1}\n' \
           "${_prev_ts}" > "${AMNEZIAWG_METRICS_FILE}"
    export MOCK_AWG_RX=1600000 MOCK_AWG_TX=800000 MOCK_AWG_HANDSHAKE_AT=0 MOCK_IP_LINK_UP=1
    metrics_sample
    # rx_bps ≈ (1_600_000 - 1_000_000) * 8 / 60 = 80_000
    # tx_bps ≈ (  800_000 -   500_000) * 8 / 60 = 40_000
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"rx_bps":80000'
    echo "${_last}" | grep -q '"tx_bps":40000'
}

@test "metrics_sample clamps rate to 0 on counter wrap" {
    _now=$(date +%s); _prev_ts=$((_now - 60))
    printf '{"ts":%s,"rx":5000000000,"tx":4000000000,"rx_bps":0,"tx_bps":0,"hs":0,"up":1}\n' \
           "${_prev_ts}" > "${AMNEZIAWG_METRICS_FILE}"
    export MOCK_AWG_RX=1000 MOCK_AWG_TX=2000 MOCK_AWG_HANDSHAKE_AT=0 MOCK_IP_LINK_UP=1
    metrics_sample
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"rx_bps":0'
    echo "${_last}" | grep -q '"tx_bps":0'
}

@test "metrics_sample sets up=0 when ip link show fails" {
    export MOCK_AWG_RX=0 MOCK_AWG_TX=0 MOCK_IP_LINK_UP=0
    metrics_sample
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"up":0'
}

@test "metrics_sample computes handshake age correctly" {
    _now=$(date +%s); _hs=$((_now - 42))
    export MOCK_AWG_RX=0 MOCK_AWG_TX=0 MOCK_AWG_HANDSHAKE_AT="${_hs}" MOCK_IP_LINK_UP=1
    metrics_sample
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    # hs should be approximately 42 (within 1s jitter from two separate `date +%s` calls)
    echo "${_last}" | grep -qE '"hs":(41|42|43)'
}

@test "metrics_sample survives awg binary failure (daemon down)" {
    export MOCK_AWG_FAIL=1 MOCK_IP_LINK_UP=0
    run metrics_sample
    [ "$status" -eq 0 ]
    _last="$(tail -1 "${AMNEZIAWG_METRICS_FILE}")"
    echo "${_last}" | grep -q '"rx":0'
    echo "${_last}" | grep -q '"tx":0'
    echo "${_last}" | grep -q '"up":0'
}

@test "metrics_sample mirrors to /www/user atomically" {
    export MOCK_AWG_RX=100 MOCK_AWG_TX=50 MOCK_IP_LINK_UP=1
    metrics_sample
    [ -s "${AMNEZIAWG_WWW_USER}/awg_metrics.htm" ]
    diff "${AMNEZIAWG_METRICS_FILE}" "${AMNEZIAWG_WWW_USER}/awg_metrics.htm"
    ! ls "${AMNEZIAWG_WWW_USER}"/*.tmp 2>/dev/null
}

@test "metrics_sample triggers ring trim when over window" {
    export AMNEZIAWG_METRICS_WINDOW=3
    # Pre-fill with 3 old samples
    _now=$(date +%s)
    for i in 1 2 3; do
        printf '{"ts":%s,"rx":0,"tx":0,"rx_bps":0,"tx_bps":0,"hs":0,"up":1}\n' \
               $((_now - 300 + i*60)) >> "${AMNEZIAWG_METRICS_FILE}"
    done
    export MOCK_AWG_RX=100 MOCK_AWG_TX=50 MOCK_IP_LINK_UP=1
    metrics_sample
    [ "$(wc -l < "${AMNEZIAWG_METRICS_FILE}")" = "3" ]
}
```

- [ ] **Step 2: Run — 8 failures**

```bash
bats addon/tests/metrics_test.bats 2>&1 | tail -15
```

- [ ] **Step 3: Replace the `metrics_sample` stub in `addon/lib/metrics.sh`**

Find the stub line `metrics_sample() { log_warn ...; return 1; }` and replace with:

```sh
metrics_sample() {
    _ts=$(date +%s)

    # RX/TX counters from `awg show <iface> transfer`
    _dump="$(awg show "${AMNEZIAWG_INTERFACE}" transfer 2>/dev/null || true)"
    _rx="$(printf '%s' "${_dump}" | awk 'NR==1{print $1+0}')"
    _tx="$(printf '%s' "${_dump}" | awk 'NR==1{print $2+0}')"
    [ -z "${_rx}" ] && _rx=0
    [ -z "${_tx}" ] && _tx=0

    # Handshake timestamp from `awg show <iface> latest-handshakes`
    _hs_at="$(awg show "${AMNEZIAWG_INTERFACE}" latest-handshakes 2>/dev/null \
              | awk 'NR==1{print $2+0}')"
    [ -z "${_hs_at}" ] && _hs_at=0
    if [ "${_hs_at}" -gt 0 ] 2>/dev/null; then
        _hs=$(( _ts - _hs_at ))
        [ "${_hs}" -lt 0 ] && _hs=0
    else
        _hs=0
    fi

    # Link up?
    if ip link show "${AMNEZIAWG_INTERFACE}" 2>/dev/null \
         | grep -qE 'state (UP|UNKNOWN)'; then
        _up=1
    else
        _up=0
    fi

    # Rate vs last sample (if any)
    _rx_bps=0
    _tx_bps=0
    if [ -s "${AMNEZIAWG_METRICS_FILE}" ]; then
        _prev="$(tail -n 1 "${AMNEZIAWG_METRICS_FILE}")"
        _prev_ts="$(printf '%s' "${_prev}"  | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')"
        _prev_rx="$(printf '%s' "${_prev}"  | sed -n 's/.*"rx":\([0-9]*\).*/\1/p')"
        _prev_tx="$(printf '%s' "${_prev}"  | sed -n 's/.*"tx":\([0-9]*\).*/\1/p')"
        [ -z "${_prev_ts}" ] && _prev_ts=0
        [ -z "${_prev_rx}" ] && _prev_rx=0
        [ -z "${_prev_tx}" ] && _prev_tx=0
        _delta=$(( _ts - _prev_ts ))
        if [ "${_delta}" -gt 0 ] && [ "${_rx}" -ge "${_prev_rx}" ] 2>/dev/null; then
            _rx_bps=$(( (_rx - _prev_rx) * 8 / _delta ))
        fi
        if [ "${_delta}" -gt 0 ] && [ "${_tx}" -ge "${_prev_tx}" ] 2>/dev/null; then
            _tx_bps=$(( (_tx - _prev_tx) * 8 / _delta ))
        fi
    fi

    mkdir -p "$(dirname "${AMNEZIAWG_METRICS_FILE}")"
    printf '{"ts":%s,"rx":%s,"tx":%s,"rx_bps":%s,"tx_bps":%s,"hs":%s,"up":%s}\n' \
           "${_ts}" "${_rx}" "${_tx}" "${_rx_bps}" "${_tx_bps}" "${_hs}" "${_up}" \
           >> "${AMNEZIAWG_METRICS_FILE}" \
        || { log_warn "metrics: write to ${AMNEZIAWG_METRICS_FILE} failed"; return 1; }

    metrics_ring_trim

    # Atomic mirror for WebUI
    if [ -d "${AMNEZIAWG_WWW_USER}" ]; then
        _mirror_tmp="${AMNEZIAWG_WWW_USER}/awg_metrics.htm.tmp.$$"
        cp "${AMNEZIAWG_METRICS_FILE}" "${_mirror_tmp}" 2>/dev/null \
            && mv -f "${_mirror_tmp}" "${AMNEZIAWG_WWW_USER}/awg_metrics.htm"
    fi
    return 0
}
```

- [ ] **Step 4: Run — 14/14 pass**

```bash
bats addon/tests/metrics_test.bats 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add addon/lib/metrics.sh addon/tests/metrics_test.bats
git commit -m "feat(metrics): implement metrics_sample (snapshot + rate + atomic mirror)"
```

---

## Phase 2 — Integration

### Task 4: Hook `metrics_sample` into `watchdog_tick`

**Files:**
- Modify: `addon/lib/watchdog.sh`
- Modify: `addon/amneziawg.sh`
- Modify: `addon/tests/watchdog_test.bats`

- [ ] **Step 1: Append failing test to `addon/tests/watchdog_test.bats`**

```bash

@test "watchdog_tick calls metrics_sample at the end" {
    # Shadow metrics_sample to record the call — library is not otherwise
    # sourced in this test to keep watchdog tests focused on cron semantics.
    metrics_sample() { printf 'metrics_sample called\n' >> "${TMPDIR_TEST}/metrics.log"; }
    state_set "awg_enabled" "1"
    watchdog_tick
    grep -q 'metrics_sample called' "${TMPDIR_TEST}/metrics.log"
}

@test "watchdog_tick calls metrics_sample even when rate-limited" {
    metrics_sample() { printf 'metrics_sample called\n' >> "${TMPDIR_TEST}/metrics.log"; }
    state_set "awg_enabled" "1"
    # Pre-fill rate-limit window so the next restart attempt is short-circuited.
    _now=$(date +%s)
    _wd_read_state
    _last_tick=$((_now - 60))
    _restart_win_start="${_now}"
    _restart_count=3
    _wd_write_state
    watchdog_tick
    grep -q 'metrics_sample called' "${TMPDIR_TEST}/metrics.log"
}
```

- [ ] **Step 2: Run — both fail**

```bash
bats addon/tests/watchdog_test.bats 2>&1 | tail -10
```

- [ ] **Step 3: Append `metrics_sample` call inside `watchdog_tick()` in `addon/lib/watchdog.sh`**

Locate the very last line of `watchdog_tick` (currently `status_emit_json`) and insert the metrics call **after** it:

```sh
    status_emit_json
    if command -v metrics_sample >/dev/null 2>&1; then
        metrics_sample || log_warn "watchdog: metrics_sample failed"
    fi
}
```

- [ ] **Step 4: Source `metrics.sh` in `addon/amneziawg.sh`**

Find the existing `. "${AWG_ADDON_DIR}/lib/watchdog.sh"` line and insert right after it:

```sh
. "${AWG_ADDON_DIR}/lib/metrics.sh"
```

- [ ] **Step 5: Run — 2 new tests pass + all prior watchdog tests still pass**

```bash
bats addon/tests/watchdog_test.bats 2>&1 | tail -5
bash -n addon/amneziawg.sh && echo "syntax ok"
```

- [ ] **Step 6: Commit**

```bash
git add addon/lib/watchdog.sh addon/amneziawg.sh addon/tests/watchdog_test.bats
git commit -m "feat(watchdog): call metrics_sample every tick (rate-limit aware)"
```

---

## Phase 3 — WebUI `AWG.metrics`

### Task 5: Pure helpers `parseJsonl` + `buildPath` + `buildDowntimeRects`

**Files:**
- Modify: `addon/webui/amneziawg.js` (append new IIFE after `AWG.status`)
- Create: `addon/webui/tests/metrics.test.js`
- Modify: `addon/webui/tests/run.sh`

- [ ] **Step 1: Create `addon/webui/tests/metrics.test.js`**

```javascript
// addon/webui/tests/metrics.test.js — AWG.metrics pure helpers.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { loadAWG } = require('./helpers.js');

test('AWG.metrics.parseJsonl parses valid lines', () => {
    const AWG = loadAWG();
    const text = '{"ts":1,"rx":10}\n{"ts":2,"rx":20}\n';
    const out = AWG.metrics.parseJsonl(text);
    assert.strictEqual(out.length, 2);
    assert.strictEqual(out[0].ts, 1);
    assert.strictEqual(out[1].rx, 20);
});

test('AWG.metrics.parseJsonl skips blank and malformed lines', () => {
    const AWG = loadAWG();
    const text = '{"ts":1}\n\n{not json}\n{"ts":3}\n';
    const out = AWG.metrics.parseJsonl(text);
    assert.strictEqual(out.length, 2);
    assert.strictEqual(out[0].ts, 1);
    assert.strictEqual(out[1].ts, 3);
});

test('AWG.metrics.parseJsonl returns [] for empty input', () => {
    const AWG = loadAWG();
    assert.deepEqual(AWG.metrics.parseJsonl(''), []);
    assert.deepEqual(AWG.metrics.parseJsonl(null), []);
    assert.deepEqual(AWG.metrics.parseJsonl(undefined), []);
});

test('AWG.metrics.buildPath returns safe no-op for empty array', () => {
    const AWG = loadAWG();
    const d = AWG.metrics.buildPath([], 'rx_bps');
    assert.ok(d.startsWith('M 0,'));
});

test('AWG.metrics.buildPath renders a valid SVG path string', () => {
    const AWG = loadAWG();
    const points = [
        { rx_bps: 0 }, { rx_bps: 50 }, { rx_bps: 100 }
    ];
    const d = AWG.metrics.buildPath(points, 'rx_bps');
    // Starts with M, contains at least two L segments, no NaN
    assert.ok(/^M /.test(d));
    assert.strictEqual((d.match(/L /g) || []).length, 2);
    assert.ok(!/NaN/.test(d));
});

test('AWG.metrics.buildDowntimeRects finds contiguous up=0 runs', () => {
    const AWG = loadAWG();
    const points = [
        { up: 1 }, { up: 0 }, { up: 0 }, { up: 1 }, { up: 0 }, { up: 1 }
    ];
    const rects = AWG.metrics.buildDowntimeRects(points);
    // Two runs: indices 1-2, index 4
    assert.strictEqual(rects.length, 2);
    assert.ok(rects[0].width > 0);
    assert.ok(rects[1].width > 0);
});

test('AWG.metrics.buildDowntimeRects returns [] when all up=1', () => {
    const AWG = loadAWG();
    const rects = AWG.metrics.buildDowntimeRects([
        { up: 1 }, { up: 1 }, { up: 1 }
    ]);
    assert.deepEqual(rects, []);
});
```

- [ ] **Step 2: Add `metrics.test.js` to the Node runner**

Edit `addon/webui/tests/run.sh`. Find the final `node --test ...` line and append `webui/tests/metrics.test.js`:

```sh
node --test webui/tests/parser.test.js webui/tests/validator.test.js webui/tests/geo.test.js webui/tests/metrics.test.js
```

- [ ] **Step 3: Run — 7 failures (AWG.metrics missing)**

```bash
bash addon/webui/tests/run.sh 2>&1 | tail -10
```

- [ ] **Step 4: Append the `AWG.metrics` IIFE to `addon/webui/amneziawg.js`**

Locate the end of the `AWG.status` IIFE (it ends with `})();` somewhere around line 500). Insert **directly after** `AWG.status`:

```javascript
    // ---------- AWG.metrics ----------

    AWG.metrics = (function () {
        var WIDTH  = 600;
        var HEIGHT = 80;
        var POLL_MS_DEFAULT = 60000;

        function parseJsonl(text) {
            if (!text) return [];
            var lines = String(text).split('\n');
            var out = [];
            for (var i = 0; i < lines.length; i++) {
                var l = lines[i].trim();
                if (!l) continue;
                try { out.push(JSON.parse(l)); } catch (_e) { /* skip */ }
            }
            return out;
        }

        function buildPath(points, key) {
            if (!points || !points.length) return 'M 0,' + HEIGHT;
            var max = 1;
            for (var i = 0; i < points.length; i++) {
                var v = points[i][key];
                if (typeof v === 'number' && v > max) max = v;
            }
            var step = WIDTH / Math.max(1, points.length - 1);
            var d = '';
            for (var j = 0; j < points.length; j++) {
                var raw = points[j][key];
                var val = (typeof raw === 'number') ? raw : 0;
                var x = Math.round(j * step * 100) / 100;
                var y = Math.round((HEIGHT - (val / max) * HEIGHT) * 100) / 100;
                d += (j === 0 ? 'M ' : ' L ') + x + ',' + y;
            }
            return d;
        }

        function buildDowntimeRects(points) {
            var rects = [];
            if (!points || !points.length) return rects;
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

        // DOM-side helpers — not unit-tested (require a live document).
        function renderSparkline(container, points, key) {
            if (!container) return;
            var svgNs = 'http://www.w3.org/2000/svg';
            while (container.firstChild) container.removeChild(container.firstChild);
            var svg = document.createElementNS(svgNs, 'svg');
            svg.setAttribute('viewBox', '0 0 ' + WIDTH + ' ' + HEIGHT);
            svg.setAttribute('preserveAspectRatio', 'none');
            svg.setAttribute('class', 'awg-spark');

            // Downtime overlay (behind the line)
            var gDown = document.createElementNS(svgNs, 'g');
            gDown.setAttribute('class', 'awg-spark-downtime');
            var rects = buildDowntimeRects(points);
            for (var i = 0; i < rects.length; i++) {
                var r = document.createElementNS(svgNs, 'rect');
                r.setAttribute('x', String(rects[i].x));
                r.setAttribute('y', '0');
                r.setAttribute('width', String(rects[i].width));
                r.setAttribute('height', String(HEIGHT));
                gDown.appendChild(r);
            }
            svg.appendChild(gDown);

            // Main line
            var path = document.createElementNS(svgNs, 'path');
            path.setAttribute('class', 'awg-spark-line');
            path.setAttribute('d', buildPath(points, key));
            svg.appendChild(path);

            // Max + last labels
            var max = 0, last = 0;
            for (var j = 0; j < points.length; j++) {
                var v = points[j][key];
                if (typeof v !== 'number') continue;
                if (v > max) max = v;
                last = v;
            }
            var tMax = document.createElementNS(svgNs, 'text');
            tMax.setAttribute('class', 'awg-spark-label-max');
            tMax.setAttribute('x', '4'); tMax.setAttribute('y', '12');
            tMax.textContent = 'max ' + AWG.util.humanizeBytes(max) + '/s';
            svg.appendChild(tMax);
            var tLast = document.createElementNS(svgNs, 'text');
            tLast.setAttribute('class', 'awg-spark-label-last');
            tLast.setAttribute('x', String(WIDTH - 4));
            tLast.setAttribute('y', '12');
            tLast.setAttribute('text-anchor', 'end');
            tLast.textContent = 'now ' + AWG.util.humanizeBytes(last) + '/s';
            svg.appendChild(tLast);

            container.appendChild(svg);
        }

        function poll(intervalMs) {
            var ms = intervalMs || POLL_MS_DEFAULT;
            function tick() {
                fetch('/user/awg_metrics.htm', { cache: 'no-store' })
                    .then(function (r) { return r.text(); })
                    .then(function (txt) {
                        var pts = parseJsonl(txt);
                        renderSparkline(document.getElementById('awg-metrics-rx'), pts, 'rx_bps');
                        renderSparkline(document.getElementById('awg-metrics-tx'), pts, 'tx_bps');
                        renderSparkline(document.getElementById('awg-metrics-hs'), pts, 'hs');
                    })
                    .catch(function () { /* ignore transient fetch errors */ });
            }
            tick();
            setInterval(tick, ms);
        }

        return {
            parseJsonl: parseJsonl,
            buildPath: buildPath,
            buildDowntimeRects: buildDowntimeRects,
            renderSparkline: renderSparkline,
            poll: poll
        };
    })();
```

- [ ] **Step 5: Run — 7/7 new Node tests pass**

```bash
bash addon/webui/tests/run.sh 2>&1 | grep -E "^ℹ (tests|pass|fail)"
```

Expected: `tests 36` (29 prior + 7 new), `pass 36`, `fail 0`.

- [ ] **Step 6: Commit**

```bash
git add addon/webui/amneziawg.js addon/webui/tests/metrics.test.js addon/webui/tests/run.sh
git commit -m "feat(webui): add AWG.metrics (parseJsonl, buildPath, buildDowntimeRects, renderSparkline, poll)"
```

### Task 6: ASP fieldset + CSS + wire polling from `AWG.init`

**Files:**
- Modify: `addon/webui/amneziawg_page.asp`
- Modify: `addon/webui/amneziawg.js` (`AWG.init`)
- Modify: `addon/webui/amneziawg.css`

- [ ] **Step 1: Add fieldset to `addon/webui/amneziawg_page.asp`**

Locate the GeoIP fieldset (contains `<legend>GeoIP / GeoSite`). Insert the new fieldset **after** its closing `</fieldset>` and **before** the Security fieldset:

```html
          <!-- ============ Traffic history (Module 6) ============ -->
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

- [ ] **Step 2: Append CSS to `addon/webui/amneziawg.css`**

```css

/* ---------- Traffic history sparklines (Module 6) ---------- */
.awg-spark-box { width: 100%; min-height: 80px; }
.awg-spark { display: block; width: 100%; height: 80px; }
.awg-spark-line { stroke: #8af; fill: none; stroke-width: 1.5; }
.awg-spark-downtime rect { fill: #f44; opacity: 0.15; }
.awg-spark-label-max, .awg-spark-label-last {
    font-size: 10px; fill: #9ab; font-family: monospace;
}
```

- [ ] **Step 3: Wire polling from `AWG.init`**

In `addon/webui/amneziawg.js` inside `AWG.init.onReady`, find the line `AWG.status.startPolling(intervalSec * 1000);` and insert **after** it:

```javascript
            // Metrics polling — one tick per minute by default (12× the status interval)
            if (AWG.metrics && AWG.metrics.poll) {
                AWG.metrics.poll(intervalSec * 12 * 1000);
            }
```

- [ ] **Step 4: Run ASP lint + Node tests**

```bash
python3 build/ci/lint_asp.py addon/webui/amneziawg_page.asp
bash addon/webui/tests/run.sh 2>&1 | grep -E "^ℹ (tests|pass|fail)"
```

Expected: `lint_asp: OK` and `pass 36`.

- [ ] **Step 5: Commit**

```bash
git add addon/webui/amneziawg_page.asp addon/webui/amneziawg.js addon/webui/amneziawg.css
git commit -m "feat(webui): add Traffic history fieldset with three sparklines"
```

---

## Phase 4 — Release prep

### Task 7: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add an M6 block under `## [Unreleased]` / `### Features` at the top of the list**

Open `CHANGELOG.md` and insert **directly above** the first existing `- GeoIP + GeoSite auto-population …` bullet inside the Unreleased Features section:

```markdown
- Traffic history — per-minute ring buffer (`/tmp/amneziawg/metrics.jsonl`,
  1440 samples = 24 h) populated by the existing `watchdog_tick` cron,
  exposed to the WebUI as three inline SVG sparklines (RX rate, TX rate,
  handshake age) with red overlay zones for link-down intervals. No
  charting library; pure vanilla JS + inline SVG (~40 lines).
```

And under `### Build` append the Module 6 reference alongside the M5 one:

```markdown
- Module 6 — Observability (metrics + sparklines) (see
  `docs/superpowers/specs/2026-04-22-module-6-observability-design.md`).
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): document Module 6 (metrics + sparklines)"
```

### Task 8: Full green run + size check

**Files:** none modified.

- [ ] **Step 1: Full test suite**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests 2>&1 | tail -3
bash addon/webui/tests/run.sh 2>&1 | grep -E "^ℹ (tests|pass|fail)"
```

Expected:
- bats: all pass (previous 276 + new `metrics_test.bats` ~14 + 2 new watchdog tests = ~292).
- Node: `tests 36`, `pass 36`.

- [ ] **Step 2: Lint**

```bash
make lint 2>&1 | tail -10
```

Expected: no shellcheck/yamllint errors; `go vet` advisory warning for upstream code is OK (mirrors existing behaviour).

- [ ] **Step 3: Cross-arch build**

```bash
make build-all 2>&1 | tail -10
ls -la dist/aarch64/*.ipk dist/armv7/*.ipk
```

Expected: both arches produce three ipks each.

- [ ] **Step 4: Size check**

```bash
make check-size
```

Expected: all within caps. `amneziawg-merlin-addon_*.ipk` ≤ 60 KB target (current 44 KB post-M5; M6 adds ~10-15 KB: one ~80-line shell lib + one ~150-line JS module + CSS).

- [ ] **Step 5: Final commit (if any stray tweaks)**

Only if `git status` shows anything — otherwise skip.

```bash
git status
```

---

## Self-review checklist

| Spec requirement | Task covering it |
|---|---|
| `/tmp/amneziawg/metrics.jsonl` ≤ 1440 samples (§3.1, §8 DoD) | Task 2 (`metrics_ring_trim`), Task 3 (ring-trim in sample) |
| Sample fields `{ts, rx, tx, rx_bps, tx_bps, hs, up}` (§3.2) | Task 3 (printf format) |
| Sampling from `watchdog_tick` every minute (§3.3) | Task 4 (wires call at end of tick) |
| Metrics runs even when rate-limited (§3.3 + §9) | Task 4 (explicit test case) |
| WebUI polls once per minute (§3.4) | Task 6 (`intervalSec * 12 * 1000`) |
| `metrics.sh` public API (§3.5) | Tasks 1-3 |
| `AWG.metrics` module with parseJsonl / buildPath / buildDowntimeRects / renderSparkline / poll (§3.6) | Task 5 |
| ASP fieldset + CSS (§6.1 + §6.3) | Task 6 |
| Counter wrap → rate=0 (§9) | Task 3 (test + code) |
| Link-down detection via `ip link show` (§3.2) | Task 3 (test + code) |
| Atomic mirror to `/www/user/awg_metrics.htm` (§9) | Task 3 (test + code) |
| bats coverage (§7.1, ~10 cases) | Tasks 1-3 (3+3+8 = 14 cases) |
| Node coverage (§7.2, ~5 cases) | Task 5 (7 cases) |
| Size budget ≤ 60 KB (§8) | Task 8 (check-size) |
| CHANGELOG (§8) | Task 7 |

All 15 spec items have a mapped task. Coverage exceeds the spec in two places (bats 14>10, node 7>5) — acceptable; added cases cover edge behaviour flagged in §9 Risks.

**Placeholder scan:** no `TBD`, `TODO`, "similar to", "appropriate error handling", or bare "implement later" in any step.

**Type consistency spot-check:**
- Sample-field names (`rx`, `tx`, `rx_bps`, `tx_bps`, `hs`, `up`, `ts`) identical across metrics.sh printf, bats assertions, AWG.metrics helpers, Node tests.
- Env-var names (`AMNEZIAWG_METRICS_FILE`, `AMNEZIAWG_METRICS_WINDOW`, `AMNEZIAWG_WWW_USER`, `AMNEZIAWG_INTERFACE`) consistent across Tasks 1-4 and the spec.
- DOM ids (`awg-metrics-rx`, `awg-metrics-tx`, `awg-metrics-hs`) match between ASP (Task 6) and JS `poll` (Task 5).

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-22-module-6-observability-plan.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — Fresh subagent per task, two-stage review, fast iteration.
2. **Inline Execution** — Batch execution with checkpoints via `executing-plans`.
