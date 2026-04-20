# Module 4 — WebUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace v1 WebUI (inline XSS-prone JS) with clean vanilla-JS + split CSS/HTML/JS files that fully exposes M2/M3 backend through the Merlin VPN → AmneziaWG page.

**Architecture:** Single HTML page (`amneziawg_page.asp`) with 9 fieldset sections (tunnel, peer, PBR, security, log). One JS file (`amneziawg.js`) organized as namespaced IIFE modules (AWG.util, AWG.parser, AWG.validator, AWG.config, AWG.status, AWG.pbr, AWG.import, AWG.forms, AWG.init). Client-side parser/validator are a pure mirror of backend `config.sh`, verified via shared test fixtures. Status polling fetches `/user/awg_status.htm` (M2-produced JSON extended with `leases` and `killswitch_armed`). XSS-safe: `textContent` over `innerHTML`.

**Tech Stack:** Vanilla JavaScript (ES5-compat, no framework); Node 18+ built-in `--test` runner for parser/validator unit tests; Merlin ASP template (`<% get_custom_settings(); %>`); POSIX shell for `status.sh` backend extension; bats-core for backend tests.

**Spec:** `docs/superpowers/specs/2026-04-20-module-4-webui-design.md`

**Starting point:** M3 complete at commit `d435692`.

---

## File structure

### Created in M4

- `addon/webui/tests/parser.test.js` — Node `--test` parser tests.
- `addon/webui/tests/validator.test.js` — Node `--test` validator tests.
- `addon/webui/tests/helpers.js` — Test bootstrap: loads `amneziawg.js` into a synthetic `window` global.
- `addon/webui/tests/run.sh` — Wrapper, graceful-skip if Node <18 missing.

### Modified in M4

- `addon/webui/amneziawg_page.asp` — overwrite (v1 visual + cleaner layout).
- `addon/webui/amneziawg.js` — overwrite (currently a placeholder stub).
- `addon/webui/amneziawg.css` — overwrite (currently empty placeholder).
- `addon/lib/status.sh` — extend `status_emit_json` with `leases` and `killswitch_armed` fields.
- `addon/tests/status_test.bats` — +2 tests for new JSON fields.
- `Makefile` — `test` target runs `addon/webui/tests/run.sh`.
- `CHANGELOG.md` — M4 unreleased entry.

### Build pipeline

- `build/ci/lint_asp.py` — exists already (M1); M4 is the first module where it passes (previous `amneziawg_page.asp` was v1 inherit with innerHTML violations).

Target: existing **205 bats** (203 current + 2 new status tests) + **~20 Node tests** for parser/validator, all green.

---

## Tooling prerequisites

- Node ≥18 (built-in `--test`). macOS Homebrew: `brew install node`. Linux CI: `actions/setup-node@v5` step already in M1 `.github/workflows/lint.yml` — used by commitlint.
- Everything else is M1/M2/M3 prereqs.

---

## Phase 1 — Backend extension

### Task 1: Extend `status_emit_json` with `leases` and `killswitch_armed`

**Files:**
- Modify: `addon/lib/status.sh`
- Modify: `addon/tests/status_test.bats`

- [ ] **Step 1: Append 2 failing tests to `addon/tests/status_test.bats`**

Append at end of file:
```bash

@test "status_emit_json includes leases from dnsmasq.leases" {
    export AMNEZIAWG_DNSMASQ_LEASES="${TMPDIR_TEST}/dnsmasq.leases"
    cat > "${AMNEZIAWG_DNSMASQ_LEASES}" <<'EOF'
1729550000 aa:bb:cc:dd:ee:01 192.168.1.100 laptop *
1729550100 aa:bb:cc:dd:ee:02 192.168.1.105 phone *
EOF
    status_emit_json
    grep -q '"leases":\[' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"mac":"aa:bb:cc:dd:ee:01"' "${AMNEZIAWG_RUNTIME}/status.json"
    grep -q '"ip":"192.168.1.105"' "${AMNEZIAWG_RUNTIME}/status.json"
}

@test "status_emit_json includes killswitch_armed flag" {
    status_emit_json
    grep -q '"killswitch_armed":false' "${AMNEZIAWG_RUNTIME}/status.json"
    touch "${AMNEZIAWG_RUNTIME}/killswitch-armed"
    status_emit_json
    grep -q '"killswitch_armed":true' "${AMNEZIAWG_RUNTIME}/status.json"
}
```

- [ ] **Step 2: Run — 2 new tests fail**

```bash
cd /Users/r00t/Desktop/AmneziaGo
bats addon/tests/status_test.bats 2>&1 | tail -8
```
Expected: 2 failures (fields not yet in JSON).

- [ ] **Step 3: Modify `addon/lib/status.sh` `status_emit_json()`**

Find the final JSON emission block (the heredoc-like `printf '{' ... '}' > "${_tmp}"` section). Extend:

1. Near the top of `status_emit_json`, after declaring `_enabled="false"` etc., add:
```sh
    _leases_json="[]"
    : "${AMNEZIAWG_DNSMASQ_LEASES:=/var/lib/misc/dnsmasq.leases}"
    if [ -f "${AMNEZIAWG_DNSMASQ_LEASES}" ]; then
        _leases_json="$(awk '
            BEGIN { printf "[" }
            NR==1 { first=1 }
            NR<=50 {
                name = ($4 == "*" ? "" : $4)
                if (!first) printf ","
                printf "{\"mac\":\"%s\",\"ip\":\"%s\",\"name\":\"%s\"}", $2, $3, name
                first=0
            }
            END { printf "]" }
        ' "${AMNEZIAWG_DNSMASQ_LEASES}" 2>/dev/null)"
        [ -z "${_leases_json}" ] && _leases_json="[]"
    fi

    _killswitch_armed="false"
    [ -f "${AMNEZIAWG_RUNTIME}/killswitch-armed" ] && _killswitch_armed="true"
```

2. Before the final `}` in the printf JSON, add two more fields (after `"daemon_log_tail":"%s"`):
```sh
        printf ',"leases":%s'                 "${_leases_json}"
        printf ',"killswitch_armed":%s'       "${_killswitch_armed}"
```

The full JSON closing becomes:
```sh
        printf '"daemon_log_tail":"%s"'       "${_log_tail}"
        printf ',"leases":%s'                 "${_leases_json}"
        printf ',"killswitch_armed":%s'       "${_killswitch_armed}"
        printf '}\n'
```

Note: the last pre-existing field (before M4 extension) was `daemon_log_tail`. Prepend `,` on both new fields to keep JSON well-formed.

- [ ] **Step 4: Run — both new tests pass**

```bash
bats addon/tests/status_test.bats
```
Expected: 10 tests (8 prior + 2 new), all green.

- [ ] **Step 5: Run full bats suite**

```bash
bats addon/tests/
```
Expected: **205/205** (previous 203 + 2 new).

- [ ] **Step 6: Commit**

```bash
git add addon/lib/status.sh addon/tests/status_test.bats
git commit -m "feat(status): extend status_emit_json with leases and killswitch_armed"
```

---

## Phase 2 — JS core modules (util, esc, parser, validator)

### Task 2: JS scaffold + `AWG.util` + `AWG.esc`

**Files:**
- Overwrite: `addon/webui/amneziawg.js` (currently placeholder stub)

- [ ] **Step 1: Write the base scaffold + util + esc modules**

Overwrite `/Users/r00t/Desktop/AmneziaGo/addon/webui/amneziawg.js`:
```javascript
// addon/webui/amneziawg.js — AmneziaWG WebUI client logic.
// Vanilla JS; ES5-compatible; no external dependencies.
// Organized into namespaced IIFE modules under global AWG.*
//
// See docs/superpowers/specs/2026-04-20-module-4-webui-design.md

(function (global) {
    'use strict';

    var AWG = global.AWG = global.AWG || {};

    // ---------- AWG.util ----------

    AWG.util = {
        humanizeBytes: function (n) {
            n = Number(n) || 0;
            if (n < 1024) return n + ' B';
            if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
            if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + ' MB';
            return (n / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
        },

        formatAge: function (seconds) {
            seconds = Number(seconds) || 0;
            if (seconds === 0) return 'never';
            if (seconds < 60) return seconds + 's ago';
            if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
            if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ago';
            return Math.floor(seconds / 86400) + 'd ago';
        },

        // Safely query an element by id. Returns null if not found.
        $: function (id) {
            return document.getElementById(id);
        }
    };

    // ---------- AWG.esc ----------

    AWG.esc = {
        // Escape for use inside HTML text content (inner text, not attributes).
        // Prefer textContent wherever possible; use this only when building HTML strings.
        escHtml: function (s) {
            if (s == null) return '';
            return String(s)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
        },

        // Escape for use inside HTML attribute double-quoted value.
        escAttr: function (s) {
            if (s == null) return '';
            return String(s).replace(/"/g, '&quot;').replace(/&/g, '&amp;');
        }
    };

})(window);
```

- [ ] **Step 2: Sanity-check the file**

```bash
cd /Users/r00t/Desktop/AmneziaGo
node --check addon/webui/amneziawg.js
```
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add addon/webui/amneziawg.js
git commit -m "feat(webui): scaffold amneziawg.js with AWG.util and AWG.esc modules"
```

---

### Task 3: `AWG.parser` + parser tests

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.parser`)
- Create: `addon/webui/tests/helpers.js`
- Create: `addon/webui/tests/parser.test.js`

- [ ] **Step 1: Create test helper**

`/Users/r00t/Desktop/AmneziaGo/addon/webui/tests/helpers.js`:
```javascript
// helpers.js — bootstrap for loading addon/webui/amneziawg.js into Node tests.
// Creates a synthetic `window` global so the IIFE module can attach AWG.*.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function loadAWG() {
    const src = fs.readFileSync(
        path.join(__dirname, '..', 'amneziawg.js'),
        'utf8'
    );
    const sandbox = { window: {}, document: undefined };
    vm.createContext(sandbox);
    vm.runInContext(src, sandbox);
    return sandbox.window.AWG;
}

function fixturePath(name) {
    return path.join(__dirname, '..', '..', 'tests', 'fixtures', name);
}

function readFixture(name) {
    return fs.readFileSync(fixturePath(name), 'utf8');
}

module.exports = { loadAWG, readFixture, fixturePath };
```

- [ ] **Step 2: Create failing parser tests**

`/Users/r00t/Desktop/AmneziaGo/addon/webui/tests/parser.test.js`:
```javascript
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { loadAWG, readFixture } = require('./helpers');

const AWG = loadAWG();

test('parser: parses Amnezia 2.0 .conf fixture', function () {
    const text = readFixture('amnezia-2.0-import.conf');
    const res = AWG.parser.parseConf(text);
    assert.strictEqual(res.ok, true);
    assert.strictEqual(res.config.interface.privatekey, 'aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=');
    assert.strictEqual(res.config.interface.address, '10.8.0.2/24');
    assert.strictEqual(res.config.interface.jc, '4');
    assert.strictEqual(res.config.interface.h1, '2072158144-2145681082');
    assert.strictEqual(res.config.interface.i1, '<b 0xabcd><r 8><t>');
    assert.strictEqual(res.config.peer.publickey, 'Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3E=');
    assert.strictEqual(res.config.peer.endpoint, 'vpn.example.com:51820');
    assert.strictEqual(res.config.peer.allowed_ips, '0.0.0.0/0,::/0');
});

test('parser: reports error when PrivateKey absent', function () {
    const text = '[Interface]\nAddress = 10.0.0.1/24\n[Peer]\nPublicKey = x\nEndpoint = y:1\nAllowedIPs = 0.0.0.0/0\n';
    const res = AWG.parser.parseConf(text);
    assert.strictEqual(res.ok, false);
    assert.ok(res.errors.length >= 1);
    assert.ok(res.errors.some(function (e) { return /PrivateKey/i.test(e); }));
});

test('parser: lowercases keys, trims values, ignores comments and blanks', function () {
    const text = [
        '# comment at top',
        '[Interface]',
        '',
        'PrivateKey   =   aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=  ',
        'Address=10.0.0.1/24',
        '# trailing comment',
        '[Peer]',
        'PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3E=',
        'Endpoint = host:51820',
        'AllowedIPs = 0.0.0.0/0'
    ].join('\n');
    const res = AWG.parser.parseConf(text);
    assert.strictEqual(res.ok, true);
    assert.strictEqual(res.config.interface.privatekey, 'aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=');
    assert.strictEqual(res.config.interface.address, '10.0.0.1/24');
});

test('parser: permissive — unknown keys silently ignored', function () {
    const text = [
        '[Interface]',
        'PrivateKey = aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE=',
        'Address = 10.0.0.1/24',
        'UnknownField = whatever',
        '[Peer]',
        'PublicKey = Y3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3FjcWNxY3E=',
        'Endpoint = h:1',
        'AllowedIPs = 0.0.0.0/0'
    ].join('\n');
    const res = AWG.parser.parseConf(text);
    assert.strictEqual(res.ok, true);
    assert.ok(!('unknownfield' in res.config.interface));
});

test('parser: returns permissive ok:true for bad-h1 fixture (validation is separate)', function () {
    const text = readFixture('bad-h1.conf');
    const res = AWG.parser.parseConf(text);
    // Parser is permissive — it extracts fields regardless of value validity.
    assert.strictEqual(res.ok, true);
    assert.strictEqual(res.config.interface.h1, 'not-a-number');
});
```

- [ ] **Step 3: Run — all tests fail (parser not defined)**

```bash
cd /Users/r00t/Desktop/AmneziaGo
node --test addon/webui/tests/parser.test.js 2>&1 | tail -15
```
Expected: 5 failures (`AWG.parser is undefined` or similar).

- [ ] **Step 4: Append `AWG.parser` to `amneziawg.js`**

Append inside the outer IIFE (before the `})(window);` closer), **after** `AWG.esc` block:

```javascript

    // ---------- AWG.parser ----------

    AWG.parser = (function () {
        function parseConf(text) {
            var lines = String(text).split(/\r?\n/);
            var section = null;
            var out = { interface: {}, peer: {} };

            for (var i = 0; i < lines.length; i++) {
                var line = lines[i];
                // Strip leading/trailing whitespace
                line = line.replace(/^\s+/, '').replace(/\s+$/, '');
                if (line === '' || line.charAt(0) === '#') continue;

                if (line === '[Interface]') { section = 'interface'; continue; }
                if (line === '[Peer]')      { section = 'peer';      continue; }
                if (section == null)        continue;

                var eq = line.indexOf('=');
                if (eq === -1) continue;

                var key = line.slice(0, eq).replace(/\s+$/, '').toLowerCase();
                var val = line.slice(eq + 1).replace(/^\s+/, '').replace(/\s+$/, '');
                if (key === '') continue;

                if (section === 'interface') {
                    switch (key) {
                        case 'privatekey':
                        case 'address':
                        case 'dns':
                        case 'mtu':
                        case 'jc':
                        case 'jmin':
                        case 'jmax':
                            out.interface[key] = val;
                            break;
                        default:
                            if (/^s[1-4]$/.test(key)) { out.interface[key] = val; break; }
                            if (/^h[1-4]$/.test(key)) { out.interface[key] = val; break; }
                            if (/^i[1-5]$/.test(key)) { out.interface[key] = val; break; }
                            // unknown — ignore
                    }
                } else if (section === 'peer') {
                    switch (key) {
                        case 'publickey':
                            out.peer.publickey = val; break;
                        case 'presharedkey':
                            out.peer.presharedkey = val; break;
                        case 'endpoint':
                            out.peer.endpoint = val; break;
                        case 'allowedips':
                            out.peer.allowed_ips = val; break;
                        case 'persistentkeepalive':
                            out.peer.keepalive = val; break;
                        default:
                            // ignore
                    }
                }
            }

            var errors = [];
            if (!out.interface.privatekey) {
                errors.push('No PrivateKey found — is this a wg/awg .conf file?');
            }
            if (errors.length) {
                return { ok: false, errors: errors };
            }
            return { ok: true, config: out };
        }

        return { parseConf: parseConf };
    })();
```

- [ ] **Step 5: Run — all 5 tests pass**

```bash
node --test addon/webui/tests/parser.test.js
```
Expected: 5 pass.

- [ ] **Step 6: Commit**

```bash
git add addon/webui/amneziawg.js addon/webui/tests/helpers.js addon/webui/tests/parser.test.js
git commit -m "feat(webui): add AWG.parser for .conf files with node tests"
```

---

### Task 4: `AWG.validator` + validator tests

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.validator`)
- Create: `addon/webui/tests/validator.test.js`

- [ ] **Step 1: Create failing validator tests**

`/Users/r00t/Desktop/AmneziaGo/addon/webui/tests/validator.test.js`:
```javascript
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { loadAWG, readFixture } = require('./helpers');

const AWG = loadAWG();
const V = AWG.validator;

// --- validateKey ---

test('validator: validateKey accepts 44-char base64 with trailing =', function () {
    assert.strictEqual(V.validateKey('aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGE='), true);
});

test('validator: validateKey rejects wrong length', function () {
    assert.strictEqual(V.validateKey('short'), false);
    assert.strictEqual(V.validateKey('aGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaGFoYWhhaG='), false);
});

test('validator: validateKey rejects empty and null', function () {
    assert.strictEqual(V.validateKey(''), false);
    assert.strictEqual(V.validateKey(null), false);
    assert.strictEqual(V.validateKey(undefined), false);
});

// --- validateAddr ---

test('validator: validateAddr accepts correct IPv4/prefix', function () {
    assert.strictEqual(V.validateAddr('10.8.0.2/24'), true);
    assert.strictEqual(V.validateAddr('192.168.1.1/32'), true);
});

test('validator: validateAddr rejects missing prefix / bad octet', function () {
    assert.strictEqual(V.validateAddr('10.8.0.2'), false);
    assert.strictEqual(V.validateAddr('999.0.0.1/24'), false);
    assert.strictEqual(V.validateAddr('10.8.0.2/33'), false);
});

// --- validateEndpoint ---

test('validator: validateEndpoint host:port', function () {
    assert.strictEqual(V.validateEndpoint('example.com:51820'), true);
    assert.strictEqual(V.validateEndpoint('1.2.3.4:443'), true);
    assert.strictEqual(V.validateEndpoint('host:0'), false);
    assert.strictEqual(V.validateEndpoint('host:70000'), false);
    assert.strictEqual(V.validateEndpoint('host'), false);
});

// --- validateCidrList ---

test('validator: validateCidrList accepts single and multiple', function () {
    assert.strictEqual(V.validateCidrList('0.0.0.0/0'), true);
    assert.strictEqual(V.validateCidrList('10.0.0.0/8,192.168.0.0/16'), true);
    assert.strictEqual(V.validateCidrList('0.0.0.0/0,::/0'), true);
});

test('validator: validateCidrList rejects empty or garbage', function () {
    assert.strictEqual(V.validateCidrList(''), false);
    assert.strictEqual(V.validateCidrList('10.0.0.0/8,garbage'), false);
});

// --- validateIntRange ---

test('validator: validateIntRange bounds', function () {
    assert.strictEqual(V.validateIntRange('500', 100, 1000), true);
    assert.strictEqual(V.validateIntRange('50', 100, 1000), false);
    assert.strictEqual(V.validateIntRange('1500', 100, 1000), false);
    assert.strictEqual(V.validateIntRange('abc', 100, 1000), false);
});

// --- validateHValue ---

test('validator: validateHValue single int or N-M', function () {
    assert.strictEqual(V.validateHValue('12345'), true);
    assert.strictEqual(V.validateHValue('2072158144-2145681082'), true);
    assert.strictEqual(V.validateHValue('100-100'), true);
    assert.strictEqual(V.validateHValue('200-100'), false);
    assert.strictEqual(V.validateHValue('abc'), false);
    assert.strictEqual(V.validateHValue(''), false);
});

// --- validateISeq ---

test('validator: validateISeq accepts empty and tag sequences', function () {
    assert.strictEqual(V.validateISeq(''), true);
    assert.strictEqual(V.validateISeq('<t>'), true);
    assert.strictEqual(V.validateISeq('<b 0xabcd>'), true);
    assert.strictEqual(V.validateISeq('<r 8>'), true);
    assert.strictEqual(V.validateISeq('<rd 6>'), true);
    assert.strictEqual(V.validateISeq('<rc 10>'), true);
    assert.strictEqual(V.validateISeq('<b 0xabcd><r 8><t>'), true);
});

test('validator: validateISeq rejects malformed', function () {
    assert.strictEqual(V.validateISeq('<b 0xabc>'), false);     // odd hex
    assert.strictEqual(V.validateISeq('<x 5>'), false);         // unknown tag
    assert.strictEqual(V.validateISeq('<t>garbage<r 8>'), false);
    assert.strictEqual(V.validateISeq('<t'), false);            // unclosed
});

// --- validateAll (aggregate) with fixtures ---

test('validator: validateAll accepts Amnezia 2.0 fixture', function () {
    const parsed = AWG.parser.parseConf(readFixture('amnezia-2.0-import.conf'));
    assert.strictEqual(parsed.ok, true);
    const res = V.validateAll(parsed.config);
    assert.strictEqual(res.ok, true, 'errors: ' + JSON.stringify(res.errors));
});

test('validator: validateAll rejects bad-h1 fixture with H1 error', function () {
    const parsed = AWG.parser.parseConf(readFixture('bad-h1.conf'));
    assert.strictEqual(parsed.ok, true);
    const res = V.validateAll(parsed.config);
    assert.strictEqual(res.ok, false);
    assert.ok(res.errors.some(function (e) { return /h1/i.test(e); }));
});

test('validator: validateAll rejects bad-key fixture with privatekey error', function () {
    const parsed = AWG.parser.parseConf(readFixture('bad-key.conf'));
    assert.strictEqual(parsed.ok, true);
    const res = V.validateAll(parsed.config);
    assert.strictEqual(res.ok, false);
    assert.ok(res.errors.some(function (e) { return /privatekey/i.test(e); }));
});

test('validator: validateAll rejects bad-endpoint fixture', function () {
    const parsed = AWG.parser.parseConf(readFixture('bad-endpoint.conf'));
    assert.strictEqual(parsed.ok, true);
    const res = V.validateAll(parsed.config);
    assert.strictEqual(res.ok, false);
    assert.ok(res.errors.some(function (e) { return /endpoint/i.test(e); }));
});
```

- [ ] **Step 2: Run — all 15 tests fail**

```bash
cd /Users/r00t/Desktop/AmneziaGo
node --test addon/webui/tests/validator.test.js 2>&1 | tail -15
```

- [ ] **Step 3: Append `AWG.validator` to `amneziawg.js`**

Append inside the outer IIFE, after `AWG.parser`:

```javascript

    // ---------- AWG.validator ----------

    AWG.validator = (function () {
        var RE_KEY = /^[A-Za-z0-9+/]{43}=$/;
        var RE_IP4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/;
        var RE_CIDR_V4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)\/(\d+)$/;
        var RE_CIDR_V6 = /^[0-9A-Fa-f:]+\/\d+$/;
        var RE_INT = /^\d+$/;

        function validateKey(s) {
            if (s == null) return false;
            if (typeof s !== 'string') return false;
            if (s.length !== 44) return false;
            return RE_KEY.test(s);
        }

        function validateAddr(s) {
            if (s == null || typeof s !== 'string') return false;
            var m = RE_CIDR_V4.exec(s);
            if (!m) return false;
            for (var i = 1; i <= 4; i++) {
                var o = Number(m[i]);
                if (!(o >= 0 && o <= 255)) return false;
            }
            var pref = Number(m[5]);
            return pref >= 0 && pref <= 32;
        }

        function validateEndpoint(s) {
            if (s == null || typeof s !== 'string') return false;
            var idx = s.lastIndexOf(':');
            if (idx <= 0 || idx === s.length - 1) return false;
            var host = s.slice(0, idx);
            var port = Number(s.slice(idx + 1));
            if (!host) return false;
            return Number.isFinite(port) && port >= 1 && port <= 65535;
        }

        function validateCidrList(s) {
            if (!s || typeof s !== 'string') return false;
            var parts = s.split(',');
            for (var i = 0; i < parts.length; i++) {
                var p = parts[i].replace(/\s+/g, '');
                if (p === '') return false;
                if (p.indexOf(':') >= 0) {
                    if (!RE_CIDR_V6.test(p)) return false;
                } else {
                    if (!validateAddr(p)) return false;
                }
            }
            return true;
        }

        function validateIntRange(s, min, max) {
            if (s == null) return false;
            var str = String(s);
            if (!RE_INT.test(str)) return false;
            var n = Number(str);
            return n >= min && n <= max;
        }

        function validateHValue(s) {
            if (!s || typeof s !== 'string') return false;
            var dash = s.indexOf('-');
            if (dash === -1) return RE_INT.test(s);
            var lo = s.slice(0, dash);
            var hi = s.slice(dash + 1);
            if (!RE_INT.test(lo) || !RE_INT.test(hi)) return false;
            return Number(lo) <= Number(hi);
        }

        function validateISeq(s) {
            if (s == null || s === '') return true;
            if (typeof s !== 'string') return false;
            var rest = s;
            while (rest.length > 0) {
                if (rest.indexOf('<t>') === 0) { rest = rest.slice(3); continue; }
                var m;
                if ((m = /^<b 0x([0-9a-fA-F]+)>/.exec(rest))) {
                    if (m[1].length % 2 !== 0) return false;
                    rest = rest.slice(m[0].length);
                    continue;
                }
                if ((m = /^<r (\d+)>/.exec(rest))) { rest = rest.slice(m[0].length); continue; }
                if ((m = /^<rd (\d+)>/.exec(rest))) { rest = rest.slice(m[0].length); continue; }
                if ((m = /^<rc (\d+)>/.exec(rest))) { rest = rest.slice(m[0].length); continue; }
                return false;
            }
            return true;
        }

        function validateAll(config) {
            var errors = [];
            var iface = (config && config.interface) || {};
            var peer  = (config && config.peer) || {};

            if (!validateKey(iface.privatekey)) {
                errors.push('privatekey invalid (must be 44-char base64)');
            }
            if (!validateAddr(iface.address)) {
                errors.push('address invalid (must be IP/prefix)');
            }
            if (!validateKey(peer.publickey)) {
                errors.push('peer_publickey invalid');
            }
            if (!validateEndpoint(peer.endpoint)) {
                errors.push('peer_endpoint invalid (must be host:port)');
            }
            if (!validateCidrList(peer.allowed_ips)) {
                errors.push('peer_allowed_ips invalid (CIDR list required)');
            }

            if (peer.presharedkey && !validateKey(peer.presharedkey)) {
                errors.push('peer_presharedkey invalid');
            }

            if (iface.dns) {
                var ips = iface.dns.split(',');
                for (var i = 0; i < ips.length; i++) {
                    if (!RE_IP4.test(ips[i].replace(/\s+/g, ''))) {
                        errors.push('dns entry invalid: ' + ips[i]);
                    }
                }
            }

            var mtu = iface.mtu || '1280';
            if (!validateIntRange(mtu, 576, 1500)) {
                errors.push('mtu invalid (range 576..1500, got ' + mtu + ')');
            }

            if (!validateIntRange(iface.jc || '0', 1, 128))     errors.push('jc invalid (range 1..128)');
            if (!validateIntRange(iface.jmin || '0', 0, 1500))  errors.push('jmin invalid');
            if (!validateIntRange(iface.jmax || '0', 0, 1500))  errors.push('jmax invalid');
            if (Number(iface.jmax || '0') < Number(iface.jmin || '0')) {
                errors.push('jmax must be >= jmin');
            }

            ['s1', 's2', 's3', 's4'].forEach(function (s) {
                if (iface[s] != null && iface[s] !== '' && !validateIntRange(iface[s], 0, 1500)) {
                    errors.push(s + ' invalid');
                }
            });

            ['h1', 'h2', 'h3', 'h4'].forEach(function (h) {
                if (!validateHValue(iface[h] || '')) {
                    errors.push(h + ' invalid (int or int-int, got ' + (iface[h] || '') + ')');
                }
            });

            ['i1', 'i2', 'i3', 'i4', 'i5'].forEach(function (i) {
                if (!validateISeq(iface[i] || '')) {
                    errors.push(i + ' invalid tagged sequence');
                }
            });

            if (peer.keepalive && !validateIntRange(peer.keepalive, 0, 65535)) {
                errors.push('peer_keepalive invalid');
            }

            return { ok: errors.length === 0, errors: errors };
        }

        return {
            validateKey: validateKey,
            validateAddr: validateAddr,
            validateEndpoint: validateEndpoint,
            validateCidrList: validateCidrList,
            validateIntRange: validateIntRange,
            validateHValue: validateHValue,
            validateISeq: validateISeq,
            validateAll: validateAll
        };
    })();
```

- [ ] **Step 4: Run — all 15 tests pass**

```bash
node --test addon/webui/tests/validator.test.js
```

- [ ] **Step 5: Commit**

```bash
git add addon/webui/amneziawg.js addon/webui/tests/validator.test.js
git commit -m "feat(webui): add AWG.validator mirroring backend rules (node tests)"
```

---

## Phase 3 — JS state, config, status, polling

### Task 5: `AWG.config` (readForm / populateForm / dirty tracking)

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.config`)

No Node tests — `AWG.config` is DOM-bound (tested manually via smoke test).

- [ ] **Step 1: Append `AWG.config` to `amneziawg.js`**

```javascript

    // ---------- AWG.config ----------

    AWG.config = (function () {
        var _snapshot = null;
        var _dirty = false;

        // Scalar keys that map 1:1 to form inputs.
        var SCALAR_KEYS = [
            'awg_enabled',
            'awg_privatekey', 'awg_address', 'awg_dns', 'awg_mtu',
            'awg_jc', 'awg_jmin', 'awg_jmax',
            'awg_s1', 'awg_s2', 'awg_s3', 'awg_s4',
            'awg_h1', 'awg_h2', 'awg_h3', 'awg_h4',
            'awg_i1', 'awg_i2', 'awg_i3', 'awg_i4', 'awg_i5',
            'awg_peer_publickey', 'awg_peer_presharedkey',
            'awg_peer_endpoint', 'awg_peer_allowed_ips', 'awg_peer_keepalive',
            'awg_default_policy',
            'awg_killswitch_strict', 'awg_ipv6_allow_bypass',
            'awg_doh_blocklist', 'awg_geo_entries',
            'awg_ui_poll_interval'
        ];

        function _elemValue(el) {
            if (!el) return '';
            if (el.type === 'checkbox') return el.checked ? '1' : '0';
            return el.value;
        }

        function _setElemValue(el, value) {
            if (!el) return;
            if (el.type === 'checkbox') {
                el.checked = (value === '1' || value === true || value === 'true');
            } else {
                el.value = (value == null ? '' : value);
            }
        }

        function readForm() {
            var out = {};
            for (var i = 0; i < SCALAR_KEYS.length; i++) {
                var key = SCALAR_KEYS[i];
                var el = AWG.util.$(key);
                out[key] = _elemValue(el);
            }
            // Devices: walk AWG.pbr.snapshot().
            var devs = (AWG.pbr && AWG.pbr.snapshot) ? AWG.pbr.snapshot() : [];
            out.awg_dev_count = String(devs.length);
            for (var j = 0; j < devs.length; j++) {
                out['awg_dev_' + j + '_ip']     = devs[j].ip || '';
                out['awg_dev_' + j + '_mac']    = devs[j].mac || '';
                out['awg_dev_' + j + '_name']   = devs[j].name || '';
                out['awg_dev_' + j + '_policy'] = devs[j].policy || 'direct';
            }
            return out;
        }

        function populateForm(obj) {
            obj = obj || {};
            for (var i = 0; i < SCALAR_KEYS.length; i++) {
                var key = SCALAR_KEYS[i];
                if (key in obj) {
                    _setElemValue(AWG.util.$(key), obj[key]);
                }
            }
            // Devices
            var count = parseInt(obj.awg_dev_count || '0', 10);
            var devs = [];
            for (var j = 0; j < count; j++) {
                devs.push({
                    ip:     obj['awg_dev_' + j + '_ip']     || '',
                    mac:    obj['awg_dev_' + j + '_mac']    || '',
                    name:   obj['awg_dev_' + j + '_name']   || '',
                    policy: obj['awg_dev_' + j + '_policy'] || 'direct'
                });
            }
            if (AWG.pbr && AWG.pbr.setDevices) AWG.pbr.setDevices(devs);
        }

        // Take a snapshot of current form state — used as baseline for dirty detection.
        function snapshot() {
            _snapshot = JSON.stringify(readForm());
            _dirty = false;
        }

        function markDirty() { _dirty = true; }
        function clearDirty() { _dirty = false; }
        function isDirty() { return _dirty; }

        // Also expose a flat keys list for AWG.forms.
        function flatKeys() {
            return SCALAR_KEYS.slice();
        }

        return {
            readForm: readForm,
            populateForm: populateForm,
            snapshot: snapshot,
            markDirty: markDirty,
            clearDirty: clearDirty,
            isDirty: isDirty,
            flatKeys: flatKeys
        };
    })();
```

- [ ] **Step 2: Syntax check**

```bash
cd /Users/r00t/Desktop/AmneziaGo
node --check addon/webui/amneziawg.js
```

- [ ] **Step 3: Commit**

```bash
git add addon/webui/amneziawg.js
git commit -m "feat(webui): add AWG.config with form serialization and dirty tracking"
```

---

### Task 6: `AWG.status` (polling + widget render)

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.status`)

- [ ] **Step 1: Append `AWG.status` to `amneziawg.js`**

```javascript

    // ---------- AWG.status ----------

    AWG.status = (function () {
        var _timerId = null;
        var _lastLeasesKey = '';

        function _leasesKey(leases) {
            if (!leases || !leases.length) return '';
            var macs = [];
            for (var i = 0; i < leases.length; i++) macs.push(leases[i].mac || '');
            macs.sort();
            return macs.join('|');
        }

        function _render(status) {
            var widget = AWG.util.$('awg-status-widget');
            if (widget) {
                widget.className = 'awg-status-widget awg-state-' + (status.state || 'stopped');
                widget.classList.remove('awg-status-stale');
            }

            var setText = function (id, value) {
                var el = AWG.util.$(id);
                if (el) el.textContent = (value == null ? '' : String(value));
            };

            setText('awg-status-state',     status.state || 'stopped');
            setText('awg-status-endpoint',  status.endpoint || '—');
            setText('awg-status-handshake', AWG.util.formatAge(status.handshake_age_seconds));
            setText('awg-status-rxtx',
                    AWG.util.humanizeBytes(status.rx_bytes) + ' / ' +
                    AWG.util.humanizeBytes(status.tx_bytes));

            var banner = AWG.util.$('awg-conflict-banner');
            if (banner) banner.style.display = status.stock_wg_conflict ? 'block' : 'none';

            var ksBadge = AWG.util.$('awg-killswitch-badge');
            if (ksBadge) {
                if (status.killswitch_armed) {
                    ksBadge.textContent = '🔒 Kill-switch ACTIVE';
                    ksBadge.style.display = 'inline-block';
                } else {
                    ksBadge.style.display = 'none';
                }
            }

            var logTail = AWG.util.$('awg-log-tail');
            if (logTail) logTail.textContent = status.daemon_log_tail || '(no log entries)';

            // Leases — update DHCP picker only on change
            var leasesKey = _leasesKey(status.leases);
            if (leasesKey !== _lastLeasesKey) {
                _lastLeasesKey = leasesKey;
                if (AWG.pbr && AWG.pbr.updateLeasePicker) {
                    AWG.pbr.updateLeasePicker(status.leases || []);
                }
            }
        }

        function _renderError(err) {
            var widget = AWG.util.$('awg-status-widget');
            if (widget) widget.classList.add('awg-status-stale');
            // Don't wipe last-known data; just mark stale.
            if (typeof console !== 'undefined' && console.warn) {
                console.warn('awg status fetch failed:', err);
            }
        }

        function _tick() {
            fetch('/user/awg_status.htm', { cache: 'no-store' })
                .then(function (r) { return r.ok ? r.json() : Promise.reject('HTTP ' + r.status); })
                .then(_render)
                .catch(_renderError);
        }

        function startPolling(intervalMs) {
            stopPolling();
            _tick();
            _timerId = setInterval(_tick, intervalMs);
        }

        function stopPolling() {
            if (_timerId) { clearInterval(_timerId); _timerId = null; }
        }

        return {
            startPolling: startPolling,
            stopPolling: stopPolling,
            _tick: _tick,
            _render: _render
        };
    })();
```

- [ ] **Step 2: Syntax check**

```bash
node --check addon/webui/amneziawg.js
```

- [ ] **Step 3: Commit**

```bash
git add addon/webui/amneziawg.js
git commit -m "feat(webui): add AWG.status for polling /user/awg_status.htm"
```

---

## Phase 4 — PBR table, Import modal, Form submission, Init

### Task 7: `AWG.pbr` (inline device table)

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.pbr`)

- [ ] **Step 1: Append `AWG.pbr` to `amneziawg.js`**

```javascript

    // ---------- AWG.pbr ----------

    AWG.pbr = (function () {
        var _devices = [];
        var _leases = [];

        var POLICIES = ['direct', 'vpn_all', 'vpn_geo'];

        function setDevices(devs) {
            _devices = Array.isArray(devs) ? devs.slice() : [];
            _render();
        }

        function snapshot() {
            // Return deep copy
            var out = [];
            for (var i = 0; i < _devices.length; i++) {
                out.push({
                    ip:     _devices[i].ip || '',
                    mac:    _devices[i].mac || '',
                    name:   _devices[i].name || '',
                    policy: _devices[i].policy || 'direct'
                });
            }
            return out;
        }

        function add(dev) {
            _devices.push({
                ip:     dev.ip || '',
                mac:    dev.mac || '',
                name:   dev.name || '',
                policy: dev.policy || 'direct'
            });
            _render();
            AWG.config.markDirty();
        }

        function remove(idx) {
            if (idx < 0 || idx >= _devices.length) return;
            _devices.splice(idx, 1);
            _render();
            AWG.config.markDirty();
        }

        function updateAt(idx, field, value) {
            if (idx < 0 || idx >= _devices.length) return;
            _devices[idx][field] = value;
            AWG.config.markDirty();
            // Re-apply class on row (policy class change only)
            if (field === 'policy') {
                var row = document.querySelector('#awg-devices tr[data-idx="' + idx + '"]');
                if (row) {
                    row.className = 'awg-device-row awg-policy-' + value;
                }
            }
        }

        function updateLeasePicker(leases) {
            _leases = Array.isArray(leases) ? leases : [];
            var picker = AWG.util.$('awg-lease-picker');
            if (!picker) return;
            // Clear options except the first placeholder
            while (picker.options.length > 1) picker.remove(1);
            for (var i = 0; i < _leases.length; i++) {
                var opt = document.createElement('option');
                opt.value = _leases[i].mac + '|' + _leases[i].ip + '|' + (_leases[i].name || '');
                opt.textContent = (_leases[i].name || '(unnamed)') + ' — ' +
                                  _leases[i].ip + ' [' + _leases[i].mac + ']';
                picker.appendChild(opt);
            }
        }

        function addFromLeasePicker() {
            var picker = AWG.util.$('awg-lease-picker');
            if (!picker || !picker.value) return;
            var parts = picker.value.split('|');
            add({
                mac: parts[0] || '',
                ip: parts[1] || '',
                name: parts[2] || '',
                policy: 'direct'
            });
            picker.selectedIndex = 0;
        }

        function addManual() {
            var ip = (AWG.util.$('awg-manual-ip') || {}).value || '';
            var mac = (AWG.util.$('awg-manual-mac') || {}).value || '';
            var name = (AWG.util.$('awg-manual-name') || {}).value || '';
            if (!ip) {
                alert('IP address required to add device');
                return;
            }
            add({ ip: ip, mac: mac, name: name, policy: 'direct' });
            AWG.util.$('awg-manual-ip').value = '';
            AWG.util.$('awg-manual-mac').value = '';
            AWG.util.$('awg-manual-name').value = '';
        }

        function _render() {
            var tbody = document.querySelector('#awg-devices tbody');
            if (!tbody) return;
            // Clear
            while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
            // Rebuild
            for (var i = 0; i < _devices.length; i++) {
                tbody.appendChild(_renderRow(i, _devices[i]));
            }
        }

        function _renderRow(idx, dev) {
            var tr = document.createElement('tr');
            tr.className = 'awg-device-row awg-policy-' + (dev.policy || 'direct');
            tr.setAttribute('data-idx', String(idx));

            var tdName = document.createElement('td');
            var inpName = document.createElement('input');
            inpName.type = 'text';
            inpName.value = dev.name || '';
            inpName.className = 'form_input';
            inpName.addEventListener('input', function () {
                updateAt(idx, 'name', inpName.value);
            });
            tdName.appendChild(inpName);

            var tdIp = document.createElement('td');
            var inpIp = document.createElement('input');
            inpIp.type = 'text';
            inpIp.value = dev.ip || '';
            inpIp.className = 'form_input';
            inpIp.addEventListener('input', function () {
                updateAt(idx, 'ip', inpIp.value);
            });
            tdIp.appendChild(inpIp);

            var tdMac = document.createElement('td');
            var inpMac = document.createElement('input');
            inpMac.type = 'text';
            inpMac.value = dev.mac || '';
            inpMac.className = 'form_input';
            inpMac.addEventListener('input', function () {
                updateAt(idx, 'mac', inpMac.value);
            });
            tdMac.appendChild(inpMac);

            var tdPolicy = document.createElement('td');
            var sel = document.createElement('select');
            sel.className = 'form_input';
            for (var i = 0; i < POLICIES.length; i++) {
                var opt = document.createElement('option');
                opt.value = POLICIES[i];
                opt.textContent = POLICIES[i];
                if (POLICIES[i] === (dev.policy || 'direct')) opt.selected = true;
                sel.appendChild(opt);
            }
            sel.addEventListener('change', function () {
                updateAt(idx, 'policy', sel.value);
            });
            tdPolicy.appendChild(sel);

            var tdAction = document.createElement('td');
            var btnDel = document.createElement('button');
            btnDel.type = 'button';
            btnDel.className = 'form_button';
            btnDel.textContent = 'Remove';
            btnDel.addEventListener('click', function () { remove(idx); });
            tdAction.appendChild(btnDel);

            tr.appendChild(tdName);
            tr.appendChild(tdIp);
            tr.appendChild(tdMac);
            tr.appendChild(tdPolicy);
            tr.appendChild(tdAction);
            return tr;
        }

        return {
            setDevices: setDevices,
            snapshot: snapshot,
            add: add,
            remove: remove,
            updateLeasePicker: updateLeasePicker,
            addFromLeasePicker: addFromLeasePicker,
            addManual: addManual
        };
    })();
```

- [ ] **Step 2: Syntax check**

```bash
node --check addon/webui/amneziawg.js
```

- [ ] **Step 3: Commit**

```bash
git add addon/webui/amneziawg.js
git commit -m "feat(webui): add AWG.pbr for inline device table with DHCP picker"
```

---

### Task 8: `AWG.import` (modal lifecycle)

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.import`)

- [ ] **Step 1: Append to `amneziawg.js`**

```javascript

    // ---------- AWG.import ----------

    AWG.import = (function () {
        var _preview = null;

        function openModal() {
            var modal = AWG.util.$('awg-import-modal');
            if (modal) modal.style.display = 'block';
            var ta = AWG.util.$('awg-import-text');
            if (ta) ta.focus();
            var preview = AWG.util.$('awg-import-preview');
            if (preview) {
                while (preview.firstChild) preview.removeChild(preview.firstChild);
            }
            _preview = null;
        }

        function closeModal() {
            var modal = AWG.util.$('awg-import-modal');
            if (modal) modal.style.display = 'none';
            _preview = null;
        }

        function parsePreview() {
            var ta = AWG.util.$('awg-import-text');
            var preview = AWG.util.$('awg-import-preview');
            if (!ta || !preview) return;

            var text = ta.value || '';
            while (preview.firstChild) preview.removeChild(preview.firstChild);

            var parsed = AWG.parser.parseConf(text);
            if (!parsed.ok) {
                _preview = null;
                _renderErrors(preview, parsed.errors);
                return;
            }

            var vres = AWG.validator.validateAll(parsed.config);
            if (!vres.ok) {
                _preview = null;
                _renderErrors(preview, vres.errors);
                _renderFields(preview, parsed.config);
                return;
            }

            _preview = parsed.config;
            _renderFields(preview, parsed.config);

            var okMsg = document.createElement('div');
            okMsg.className = 'awg-import-ok';
            okMsg.textContent = '✓ All fields valid. Click "Populate Form" to apply.';
            preview.appendChild(okMsg);
        }

        function _renderErrors(preview, errors) {
            var ul = document.createElement('ul');
            ul.className = 'awg-import-errors';
            for (var i = 0; i < errors.length; i++) {
                var li = document.createElement('li');
                li.textContent = errors[i];
                ul.appendChild(li);
            }
            preview.appendChild(ul);
        }

        function _renderFields(preview, config) {
            var table = document.createElement('table');
            table.className = 'awg-import-fields';
            var emit = function (section, k, v) {
                if (!v && v !== 0) return;
                var tr = document.createElement('tr');
                var tdK = document.createElement('td');
                tdK.textContent = section + '.' + k;
                var tdV = document.createElement('td');
                tdV.textContent = v;
                tr.appendChild(tdK);
                tr.appendChild(tdV);
                table.appendChild(tr);
            };
            var iface = config.interface || {};
            var peer = config.peer || {};
            Object.keys(iface).forEach(function (k) { emit('interface', k, iface[k]); });
            Object.keys(peer).forEach(function (k) { emit('peer', k, peer[k]); });
            preview.appendChild(table);
        }

        function populateFromPreview() {
            if (!_preview) {
                alert('No valid preview to apply. Click "Parse & Preview" first.');
                return;
            }
            var flat = {};
            var iface = _preview.interface || {};
            var peer  = _preview.peer || {};

            // Interface → awg_* keys
            var IFACE_KEYS = {
                privatekey: 'awg_privatekey',
                address:    'awg_address',
                dns:        'awg_dns',
                mtu:        'awg_mtu',
                jc:         'awg_jc',
                jmin:       'awg_jmin',
                jmax:       'awg_jmax'
            };
            Object.keys(IFACE_KEYS).forEach(function (k) {
                if (iface[k] != null) flat[IFACE_KEYS[k]] = iface[k];
            });
            ['s1','s2','s3','s4','h1','h2','h3','h4','i1','i2','i3','i4','i5'].forEach(function (k) {
                if (iface[k] != null) flat['awg_' + k] = iface[k];
            });

            var PEER_KEYS = {
                publickey:    'awg_peer_publickey',
                presharedkey: 'awg_peer_presharedkey',
                endpoint:     'awg_peer_endpoint',
                allowed_ips:  'awg_peer_allowed_ips',
                keepalive:    'awg_peer_keepalive'
            };
            Object.keys(PEER_KEYS).forEach(function (k) {
                if (peer[k] != null) flat[PEER_KEYS[k]] = peer[k];
            });

            // Enable flag defaults to 1 on import
            flat.awg_enabled = '1';

            AWG.config.populateForm(flat);
            AWG.config.markDirty();
            closeModal();
        }

        return {
            openModal: openModal,
            closeModal: closeModal,
            parsePreview: parsePreview,
            populateFromPreview: populateFromPreview
        };
    })();
```

- [ ] **Step 2: Syntax check**

```bash
node --check addon/webui/amneziawg.js
```

- [ ] **Step 3: Commit**

```bash
git add addon/webui/amneziawg.js
git commit -m "feat(webui): add AWG.import modal with parse+preview+populate flow"
```

---

### Task 9: `AWG.forms` (submitSave + submitControl)

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.forms`)

- [ ] **Step 1: Append to `amneziawg.js`**

```javascript

    // ---------- AWG.forms ----------

    AWG.forms = (function () {

        // Build synthetic {interface, peer} config from the flat form data —
        // needed for AWG.validator.validateAll, which expects nested structure.
        function _buildConfigFromFlat(flat) {
            var iface = {
                privatekey: flat.awg_privatekey,
                address:    flat.awg_address,
                dns:        flat.awg_dns,
                mtu:        flat.awg_mtu,
                jc:         flat.awg_jc,
                jmin:       flat.awg_jmin,
                jmax:       flat.awg_jmax,
                s1: flat.awg_s1, s2: flat.awg_s2, s3: flat.awg_s3, s4: flat.awg_s4,
                h1: flat.awg_h1, h2: flat.awg_h2, h3: flat.awg_h3, h4: flat.awg_h4,
                i1: flat.awg_i1, i2: flat.awg_i2, i3: flat.awg_i3, i4: flat.awg_i4, i5: flat.awg_i5
            };
            var peer = {
                publickey:    flat.awg_peer_publickey,
                presharedkey: flat.awg_peer_presharedkey,
                endpoint:     flat.awg_peer_endpoint,
                allowed_ips:  flat.awg_peer_allowed_ips,
                keepalive:    flat.awg_peer_keepalive
            };
            return { interface: iface, peer: peer };
        }

        function submitSave() {
            var flat = AWG.config.readForm();

            // Pre-flight validation (mirror of backend)
            var cfg = _buildConfigFromFlat(flat);
            var res = AWG.validator.validateAll(cfg);
            if (!res.ok) {
                alert('Configuration validation errors:\n\n' + res.errors.join('\n'));
                return;
            }

            var amng = AWG.util.$('amng_custom');
            var as = AWG.util.$('action_script');
            if (!amng || !as) {
                alert('Form hidden inputs missing — page broken');
                return;
            }
            amng.value = JSON.stringify(flat);
            as.value = 'start_awgsaveconf';

            AWG.config.clearDirty();
            document.forms['amneziawg_form'].submit();
        }

        function submitControl(action) {
            // action: 'awgstart' | 'awgstop' | 'awgrestart'
            var amng = AWG.util.$('amng_custom');
            var as = AWG.util.$('action_script');
            if (!amng || !as) return;
            amng.value = '';
            as.value = 'start_' + action;
            document.forms['amneziawg_form'].submit();
        }

        return {
            submitSave: submitSave,
            submitControl: submitControl
        };
    })();
```

- [ ] **Step 2: Syntax check + commit**

```bash
cd /Users/r00t/Desktop/AmneziaGo
node --check addon/webui/amneziawg.js
git add addon/webui/amneziawg.js
git commit -m "feat(webui): add AWG.forms with submitSave and submitControl"
```

---

### Task 10: `AWG.init` (DOMContentLoaded wiring)

**Files:**
- Modify: `addon/webui/amneziawg.js` (append `AWG.init`)

- [ ] **Step 1: Append to `amneziawg.js`**

```javascript

    // ---------- AWG.init ----------

    AWG.init = (function () {
        function onReady() {
            // 1. Load initial state injected by ASP in <head>
            var cs = global._customSettingsInline || {};
            AWG.config.populateForm(cs);

            // 2. Take snapshot (baseline) AFTER populate so dirty detection works
            AWG.config.snapshot();

            // 3. Bind input events for dirty tracking
            var inputs = document.querySelectorAll('input, select, textarea');
            for (var i = 0; i < inputs.length; i++) {
                inputs[i].addEventListener('change', AWG.config.markDirty);
                inputs[i].addEventListener('input',  AWG.config.markDirty);
            }

            // 4. Start polling
            var intervalSec = parseInt(cs.awg_ui_poll_interval || '5', 10);
            if (!(intervalSec >= 1 && intervalSec <= 60)) intervalSec = 5;
            AWG.status.startPolling(intervalSec * 1000);

            // 5. beforeunload guard
            global.addEventListener('beforeunload', function (e) {
                if (AWG.config.isDirty()) {
                    e.preventDefault();
                    e.returnValue = '';
                }
            });
        }

        if (typeof document !== 'undefined') {
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', onReady);
            } else {
                // Already loaded (defer script after DOMContentLoaded)
                setTimeout(onReady, 0);
            }
        }

        return { onReady: onReady };
    })();
```

- [ ] **Step 2: Syntax check + full bats + node suite**

```bash
cd /Users/r00t/Desktop/AmneziaGo
node --check addon/webui/amneziawg.js
node --test addon/webui/tests/parser.test.js addon/webui/tests/validator.test.js
bats addon/tests/
```
Expected: all green (bats 205/205, node 20/20).

- [ ] **Step 3: Commit**

```bash
git add addon/webui/amneziawg.js
git commit -m "feat(webui): add AWG.init with DOMContentLoaded wiring and polling bootstrap"
```

---

## Phase 5 — HTML + CSS

### Task 11: `amneziawg_page.asp` — overwrite with clean layout

**Files:**
- Overwrite: `addon/webui/amneziawg_page.asp`

The current file is the 1170-line v1 content fetched in M1. M4 replaces it with a clean layout.

- [ ] **Step 1: Overwrite `addon/webui/amneziawg_page.asp`**

```html
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
  <meta http-equiv="Pragma" content="no-cache"/>
  <meta http-equiv="Expires" content="-1"/>
  <meta name="version" content="0.0.0-dev">
  <title>Asuswrt-Merlin — AmneziaWG</title>
  <link rel="stylesheet" type="text/css" href="/index_style.css">
  <link rel="stylesheet" type="text/css" href="/form_style.css">
  <link rel="stylesheet" type="text/css" href="/user/amneziawg.css">
  <script type="text/javascript" src="/state.js"></script>
  <script type="text/javascript" src="/popup.js"></script>
  <script type="text/javascript" src="/general.js"></script>
  <script type="text/javascript" src="/help.js"></script>
  <script type="text/javascript" src="/validator.js"></script>
  <script type="text/javascript" src="/httpApi.js"></script>
  <script type="text/javascript">
    // Initial state injected from custom_settings.txt
    window._customSettingsInline = <% get_custom_settings(); %>;
  </script>
</head>
<body onload="show_menu();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<div id="hiddenMask" class="popup_bg" style="z-index:999;">
  <table cellpadding="5" cellspacing="0" id="dr_sweet_advise" class="dr_sweet_advise" align="center">
    <tr><td><img src="/images/loading.gif"></td>
        <td style="color:#FFFFFF;"><div id="drword" style="height:100%;"></div></td></tr>
  </table>
</div>
<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr><td width="17">&nbsp;</td>
<td valign="top" width="202">
  <div id="mainMenu"></div>
  <div id="subMenu"></div>
</td>
<td valign="top">
  <div id="tabMenu" class="submenuBlock"></div>
  <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
    <tr>
      <td align="left" valign="top">
        <table width="760px" border="0" cellpadding="5" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle">
          <tr><td bgcolor="#4D595D" valign="top">
          <div>&nbsp;</div>
          <div class="formfonttitle">VPN — AmneziaWG</div>
          <div style="margin:10px 0 10px 5px;" class="splitLine"></div>
          <div class="formfontdesc">Amnezia-flavoured WireGuard VPN client with selective policy-based routing.</div>

          <!-- ============ Form ============ -->
          <form method="post" name="amneziawg_form" action="/start_apply.htm" target="hidden_frame"
                onsubmit="return false;">
          <input type="hidden" name="current_page" value="Advanced_AmneziaWG.asp">
          <input type="hidden" name="next_page" value="Advanced_AmneziaWG.asp">
          <input type="hidden" name="modified" value="0">
          <input type="hidden" name="flag" value="">
          <input type="hidden" id="action_script" name="action_script" value="start_awgsaveconf">
          <input type="hidden" name="action_wait" value="10">
          <input type="hidden" name="first_time" value="">
          <input type="hidden" id="amng_custom" name="amng_custom" value="">

          <!-- ============ Sticky status widget ============ -->
          <div id="awg-status-widget" class="awg-status-widget awg-state-stopped">
            <span>State:       <strong id="awg-status-state">stopped</strong></span>
            <span>Endpoint:    <strong id="awg-status-endpoint">—</strong></span>
            <span>Handshake:   <strong id="awg-status-handshake">never</strong></span>
            <span>RX / TX:     <strong id="awg-status-rxtx">0 B / 0 B</strong></span>
            <span id="awg-killswitch-badge" style="display:none"></span>
          </div>
          <div id="awg-conflict-banner" class="awg-conflict-banner" style="display:none">
            &#x26A0; Stock Merlin WG client is active — routing may conflict.
          </div>

          <!-- ============ Tunnel Configuration ============ -->
          <fieldset>
            <legend>Tunnel Configuration</legend>
            <p>
              <button type="button" class="form_button" onclick="AWG.import.openModal()">Import .conf</button>
            </p>
            <table class="FormTable" width="100%">
              <tr><th>Enabled</th>
                  <td><input type="checkbox" id="awg_enabled"></td></tr>
              <tr><th>Private Key</th>
                  <td><input type="text" id="awg_privatekey" class="form_input" maxlength="44" size="48"></td></tr>
              <tr><th>Address</th>
                  <td><input type="text" id="awg_address" class="form_input" size="24" placeholder="10.8.0.2/24"></td></tr>
              <tr><th>DNS</th>
                  <td><input type="text" id="awg_dns" class="form_input" size="32" placeholder="1.1.1.1"></td></tr>
              <tr><th>MTU</th>
                  <td><input type="text" id="awg_mtu" class="form_input" size="6" placeholder="1280"></td></tr>
              <tr><th>Jc</th><td><input type="text" id="awg_jc" class="form_input" size="6"></td></tr>
              <tr><th>Jmin</th><td><input type="text" id="awg_jmin" class="form_input" size="6"></td></tr>
              <tr><th>Jmax</th><td><input type="text" id="awg_jmax" class="form_input" size="6"></td></tr>
              <tr><th>S1</th><td><input type="text" id="awg_s1" class="form_input" size="6"></td></tr>
              <tr><th>S2</th><td><input type="text" id="awg_s2" class="form_input" size="6"></td></tr>
              <tr><th>S3</th><td><input type="text" id="awg_s3" class="form_input" size="6"></td></tr>
              <tr><th>S4</th><td><input type="text" id="awg_s4" class="form_input" size="6"></td></tr>
              <tr><th>H1</th><td><input type="text" id="awg_h1" class="form_input" size="24" placeholder="N or N-M"></td></tr>
              <tr><th>H2</th><td><input type="text" id="awg_h2" class="form_input" size="24"></td></tr>
              <tr><th>H3</th><td><input type="text" id="awg_h3" class="form_input" size="24"></td></tr>
              <tr><th>H4</th><td><input type="text" id="awg_h4" class="form_input" size="24"></td></tr>
              <tr><th>I1</th><td><input type="text" id="awg_i1" class="form_input" size="48" placeholder="&lt;b 0xabcd&gt;&lt;r 8&gt;&lt;t&gt;"></td></tr>
              <tr><th>I2</th><td><input type="text" id="awg_i2" class="form_input" size="48"></td></tr>
              <tr><th>I3</th><td><input type="text" id="awg_i3" class="form_input" size="48"></td></tr>
              <tr><th>I4</th><td><input type="text" id="awg_i4" class="form_input" size="48"></td></tr>
              <tr><th>I5</th><td><input type="text" id="awg_i5" class="form_input" size="48"></td></tr>
            </table>
          </fieldset>

          <!-- ============ Peer ============ -->
          <fieldset>
            <legend>Peer</legend>
            <table class="FormTable" width="100%">
              <tr><th>Public Key</th>
                  <td><input type="text" id="awg_peer_publickey" class="form_input" maxlength="44" size="48"></td></tr>
              <tr><th>Preshared Key (opt)</th>
                  <td><input type="text" id="awg_peer_presharedkey" class="form_input" maxlength="44" size="48"></td></tr>
              <tr><th>Endpoint</th>
                  <td><input type="text" id="awg_peer_endpoint" class="form_input" size="48" placeholder="vpn.example.com:51820"></td></tr>
              <tr><th>Allowed IPs</th>
                  <td><input type="text" id="awg_peer_allowed_ips" class="form_input" size="48" placeholder="0.0.0.0/0"></td></tr>
              <tr><th>Persistent Keepalive</th>
                  <td><input type="text" id="awg_peer_keepalive" class="form_input" size="6" placeholder="25"></td></tr>
            </table>
          </fieldset>

          <!-- ============ Policy-Based Routing ============ -->
          <fieldset>
            <legend>Policy-Based Routing</legend>
            <table class="FormTable" width="100%">
              <tr><th>Default Policy</th>
                  <td>
                    <select id="awg_default_policy" class="form_input">
                      <option value="direct">direct (not in VPN)</option>
                      <option value="vpn_all">vpn_all (whole LAN via VPN)</option>
                      <option value="vpn_geo">vpn_geo (only to geo IPs)</option>
                    </select>
                  </td></tr>
            </table>
            <p><strong>Devices</strong></p>
            <table id="awg-devices" class="FormTable" width="100%">
              <thead><tr><th>Name</th><th>IP</th><th>MAC</th><th>Policy</th><th></th></tr></thead>
              <tbody></tbody>
            </table>
            <p>
              From DHCP:
              <select id="awg-lease-picker" class="form_input">
                <option value="">— select lease —</option>
              </select>
              <button type="button" class="form_button" onclick="AWG.pbr.addFromLeasePicker()">Add from lease</button>
            </p>
            <p>
              Or manually:
              Name <input type="text" id="awg-manual-name" class="form_input" size="12">
              IP <input type="text" id="awg-manual-ip" class="form_input" size="14">
              MAC <input type="text" id="awg-manual-mac" class="form_input" size="18">
              <button type="button" class="form_button" onclick="AWG.pbr.addManual()">Add</button>
            </p>
            <table class="FormTable" width="100%">
              <tr><th>Geo Entries (CIDRs, comma-separated)</th>
                  <td><textarea id="awg_geo_entries" class="form_input" rows="3" cols="60"
                                placeholder="10.0.0.0/8, 1.2.3.4/32"></textarea></td></tr>
            </table>
          </fieldset>

          <!-- ============ Security ============ -->
          <fieldset>
            <legend>Security</legend>
            <table class="FormTable" width="100%">
              <tr><th>Strict Kill-switch</th>
                  <td><input type="checkbox" id="awg_killswitch_strict"> DROP all VPN traffic when tunnel is down</td></tr>
              <tr><th>Allow IPv6 Bypass</th>
                  <td><input type="checkbox" id="awg_ipv6_allow_bypass"> (disables IPv6 leak protection)</td></tr>
              <tr><th>DoH Blocklist (CIDRs)</th>
                  <td><textarea id="awg_doh_blocklist" class="form_input" rows="3" cols="60"
                                placeholder="1.1.1.1/32, 8.8.8.8/32 (optional)"></textarea></td></tr>
              <tr><th>UI Poll Interval (sec)</th>
                  <td><input type="text" id="awg_ui_poll_interval" class="form_input" size="6" placeholder="5"></td></tr>
            </table>
          </fieldset>

          <!-- ============ Daemon Log ============ -->
          <fieldset>
            <legend>Daemon Log (last 20 lines)</legend>
            <pre id="awg-log-tail" class="awg-log-tail">(no log entries)</pre>
          </fieldset>

          <!-- ============ Action buttons ============ -->
          <div class="awg-actions">
            <input type="button" class="button_gen" value="Save &amp; Apply" onclick="AWG.forms.submitSave()">
            <input type="button" class="button_gen" value="Start"   onclick="AWG.forms.submitControl('awgstart')">
            <input type="button" class="button_gen" value="Stop"    onclick="AWG.forms.submitControl('awgstop')">
            <input type="button" class="button_gen" value="Restart" onclick="AWG.forms.submitControl('awgrestart')">
          </div>

          </form>

          <!-- ============ Import modal ============ -->
          <div id="awg-import-modal" class="awg-import-modal" style="display:none">
            <div class="awg-import-inner">
              <h3>Import .conf</h3>
              <p>Paste a WireGuard/AmneziaWG <code>.conf</code>. Client-side parser shows a preview before applying.</p>
              <textarea id="awg-import-text" rows="12" cols="80"
                        placeholder="[Interface]&#10;PrivateKey = ..."></textarea>
              <div>
                <button type="button" class="form_button" onclick="AWG.import.parsePreview()">Parse &amp; Preview</button>
                <button type="button" class="form_button" onclick="AWG.import.populateFromPreview()">Populate Form</button>
                <button type="button" class="form_button" onclick="AWG.import.closeModal()">Cancel</button>
              </div>
              <div id="awg-import-preview" class="awg-import-preview"></div>
            </div>
          </div>

          </td></tr>
        </table>
      </td>
    </tr>
  </table>
</td><td width="10" align="center" valign="top">&nbsp;</td></tr>
</table>
<div id="footer"></div>

<script type="text/javascript" src="/user/amneziawg.js"></script>
</body>
</html>
```

- [ ] **Step 2: Render VERSION into meta tag**

```bash
cd /Users/r00t/Desktop/AmneziaGo
./build/version.sh
grep 'meta name="version"' addon/webui/amneziawg_page.asp
```
Expected: `content="0.0.0-dev"`.

- [ ] **Step 3: Verify lint_asp.py passes**

```bash
python3 build/ci/lint_asp.py; echo "rc=$?"
```
Expected: `lint_asp: OK` + rc=0.

If it fails (possible: `<% nvram_get %>` no longer used in this file; `get_custom_settings` is in `<script>` context which linter treats as attribute). Review what the linter says and fix.

- [ ] **Step 4: Commit**

```bash
git add addon/webui/amneziawg_page.asp
git commit -m "feat(webui): overwrite amneziawg_page.asp with clean v4 layout

Replaces v1 1170-line inline-JS page with a structured HTML form.
All interactivity moved to /user/amneziawg.js.
No innerHTML=rawUser, no external fetches, no eval.
lint_asp.py now passes."
```

---

### Task 12: `amneziawg.css` — extend Merlin styles

**Files:**
- Overwrite: `addon/webui/amneziawg.css`

Current file is an empty placeholder.

- [ ] **Step 1: Write the stylesheet**

Overwrite `/Users/r00t/Desktop/AmneziaGo/addon/webui/amneziawg.css`:
```css
/* addon/webui/amneziawg.css — AmneziaWG WebUI styles (complements Merlin CSS). */

/* ---------- Status widget ---------- */
.awg-status-widget {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  padding: 8px 12px;
  margin: 8px 0;
  border-radius: 4px;
  font-size: 13px;
}
.awg-status-widget > span { white-space: nowrap; }
.awg-status-widget.awg-state-running  { background: #2e5b37; color: #d4edda; }
.awg-status-widget.awg-state-stopped  { background: #5a2d2d; color: #f8d7da; }
.awg-status-widget.awg-state-failed   { background: #6b5a1f; color: #fff3cd; }
.awg-status-widget.awg-status-stale   { opacity: 0.5; }

/* ---------- Conflict banner ---------- */
.awg-conflict-banner {
  background: #6b5a1f;
  color: #fff3cd;
  padding: 8px 12px;
  margin: 8px 0;
  border-radius: 4px;
  font-weight: bold;
}

/* ---------- Kill-switch badge ---------- */
#awg-killswitch-badge {
  background: #5a2d2d;
  color: #f8d7da;
  padding: 2px 8px;
  border-radius: 10px;
  font-weight: bold;
}

/* ---------- PBR device table ---------- */
#awg-devices { margin-top: 8px; }
#awg-devices th { background: #3a464b; }
.awg-device-row.awg-policy-vpn_all { background: rgba(70, 100, 150, 0.2); }
.awg-device-row.awg-policy-vpn_geo { background: rgba(70, 150, 100, 0.2); }
.awg-device-row.awg-policy-direct  { background: rgba(100, 100, 100, 0.1); }

/* ---------- Log tail ---------- */
.awg-log-tail {
  font-family: monospace;
  font-size: 11px;
  white-space: pre-wrap;
  max-height: 220px;
  overflow-y: auto;
  background: #1c1c1c;
  color: #c0c0c0;
  padding: 6px 10px;
  border: 1px solid #3a464b;
  border-radius: 4px;
}

/* ---------- Import modal ---------- */
.awg-import-modal {
  position: fixed;
  top: 0; left: 0;
  width: 100%; height: 100%;
  background: rgba(0, 0, 0, 0.7);
  z-index: 10000;
}
.awg-import-inner {
  position: absolute;
  top: 50%; left: 50%;
  transform: translate(-50%, -50%);
  background: #2b3438;
  color: #e0e0e0;
  padding: 20px;
  border-radius: 6px;
  min-width: 640px;
  max-width: 90vw;
  max-height: 90vh;
  overflow-y: auto;
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
}
.awg-import-inner h3 { margin-top: 0; }
.awg-import-inner textarea {
  width: 100%;
  box-sizing: border-box;
  font-family: monospace;
  font-size: 12px;
  background: #1c1c1c;
  color: #c0c0c0;
  border: 1px solid #3a464b;
  padding: 6px;
}
.awg-import-preview { margin-top: 12px; }
.awg-import-errors {
  background: #5a2d2d;
  color: #f8d7da;
  padding: 8px 14px;
  border-radius: 4px;
  list-style: disc;
}
.awg-import-ok {
  background: #2e5b37;
  color: #d4edda;
  padding: 6px 12px;
  border-radius: 4px;
  margin-top: 8px;
}
.awg-import-fields {
  width: 100%;
  margin-top: 8px;
  font-size: 12px;
}
.awg-import-fields td { padding: 2px 8px; border-bottom: 1px solid #3a464b; }
.awg-import-fields td:first-child { color: #9ab; font-family: monospace; }

/* ---------- Actions bar ---------- */
.awg-actions {
  margin-top: 16px;
  padding-top: 10px;
  border-top: 1px solid #3a464b;
  text-align: right;
}
.awg-actions .button_gen { margin-left: 8px; }
```

- [ ] **Step 2: Commit**

```bash
git add addon/webui/amneziawg.css
git commit -m "feat(webui): add amneziawg.css complementing Merlin theme"
```

---

## Phase 6 — Test infrastructure

### Task 13: `run.sh` + Makefile integration

**Files:**
- Create: `addon/webui/tests/run.sh`
- Modify: `Makefile`

- [ ] **Step 1: Create `addon/webui/tests/run.sh`**

```sh
#!/bin/sh
# addon/webui/tests/run.sh — run Node-based webui tests, graceful-skip if
# Node <18 not installed.

set -eu

cd "$(dirname "$0")/../.."

if ! command -v node >/dev/null 2>&1; then
    echo "node not installed — skipping webui tests"
    exit 0
fi

# Extract major version
node_major="$(node --version | sed 's/^v//; s/\..*//')"
if [ "${node_major}" -lt 18 ] 2>/dev/null; then
    echo "node ${node_major} < 18; skipping webui tests"
    exit 0
fi

node --test webui/tests/parser.test.js webui/tests/validator.test.js
```

- [ ] **Step 2: Make executable + smoke test**

```bash
cd /Users/r00t/Desktop/AmneziaGo
chmod +x addon/webui/tests/run.sh
bash addon/webui/tests/run.sh
```
Expected: prints test results from Node, exit 0.

- [ ] **Step 3: Update `Makefile` `test` target**

Find the `test:` target:
```make
.PHONY: test
test: ## Run Go + bats tests
	go test -race ./...
	bats addon/tests/
```

Change to:
```make
.PHONY: test
test: ## Run Go + bats + webui tests
	go test -race ./...
	bats addon/tests/
	bash addon/webui/tests/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add addon/webui/tests/run.sh Makefile
git commit -m "build(test): integrate Node-based webui tests into make test"
```

---

## Phase 7 — Verification

### Task 14: Ensure `lint_asp.py` passes

**Files:** (verification only; may touch `amneziawg_page.asp` if issues)

- [ ] **Step 1: Run**

```bash
cd /Users/r00t/Desktop/AmneziaGo
python3 build/ci/lint_asp.py
echo "rc=$?"
```
Expected: `lint_asp: OK` + rc=0.

If errors surface:
- `no eval()` → trivially pass (no eval in new code).
- `innerHTML from user identifier` → scan `amneziawg.js` for `innerHTML\s*=\s*[A-Za-z]` → our code uses `textContent`, should pass.
- `<% nvram_get(...) %>` interpolated outside attribute → our ASP uses `get_custom_settings()` inside `<script>`. The linter treats `<% get_custom_settings(); %>` separately; verify its rule doesn't flag it.

If any false positive: update `build/ci/lint_asp.py` to accept the new, safer patterns.

- [ ] **Step 2: (if needed) Fix and commit**

```bash
git add <fixed-file>
git commit -m "fix(lint): adjust lint_asp for v4 page patterns"
```

---

### Task 15: Full suite + build verification

- [ ] **Step 1: Run full test stack**

```bash
cd /Users/r00t/Desktop/AmneziaGo
make lint
bats addon/tests/
bash addon/webui/tests/run.sh
```
Expected: all green. Bats 205/205, Node ~20/20.

- [ ] **Step 2: Docker build (aarch64)**

```bash
make build-docker-aarch64 2>&1 | tail -5
ls -la dist/aarch64/amneziawg-merlin-addon_*.ipk
./build/ci/check_size.sh dist
```
Expected: addon ≤ 200 KB.

- [ ] **Step 3: Spot-check ipk contents**

```bash
cd /tmp
cp /Users/r00t/Desktop/AmneziaGo/dist/aarch64/amneziawg-merlin-addon_*.ipk ./m4addon.ipk
mkdir -p m4extract && cd m4extract
tar xzf ../m4addon.ipk
tar xzf data.tar.gz
ls -la jffs/addons/amneziawg/webui/
cd /
rm -rf /tmp/m4extract /tmp/m4addon.ipk
```
Expected: `amneziawg_page.asp`, `amneziawg.js`, `amneziawg.css` all present.

- [ ] **Step 4: Commit any build-time fixes**

```bash
git status  # should be clean; if not, commit appropriately
```

---

### Task 16: CHANGELOG update

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Append M4 entries**

Under the existing `### Features` block (right after the M3 PBR entries), append:

```
- WebUI rewrite — vanilla JS in split files (`amneziawg.js`, `amneziawg.css`),
  no framework, no external CDN. Inherits v1 visual layout; client-side JS is
  fully rewritten with safe DOM manipulation (textContent over innerHTML).
- Client-side `.conf` parser + validator mirroring backend (shared fixtures);
  Node 18+ `--test` unit tests verify parity.
- Status polling widget (`/user/awg_status.htm` every N seconds) shows live
  state, handshake age, RX/TX, kill-switch armed state, stock-WG conflict.
- Inline-edit PBR device table with DHCP-lease picker; import `.conf` modal
  with preview-before-apply.
- Global "Save & Apply" submits `amng_custom` JSON; backend auto-detects diff
  (tunnel_reload + pbr_reapply_incremental are noop when state unchanged).
- Status JSON extended with `leases[]` and `killswitch_armed` fields.
- Removed v1 UI bugs: direct `api.github.com` fetch (exposed router IP),
  `innerHTML = rawUser` XSS paths, hardcoded DoH block IPs, `prompt()`
  DHCP-picker.
```

Under `### Build`:
```
- Module 4 — WebUI rewrite (see
  `docs/superpowers/specs/2026-04-20-module-4-webui-design.md`).
- `make test` now also runs `addon/webui/tests/run.sh` (Node 18+ required,
  graceful-skip otherwise).
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): document Module 4 (WebUI rewrite)"
```

---

## Self-Review

### Spec coverage

| Spec section | Task |
|---|---|
| §2.1 Framework: vanilla split files | Tasks 2-12 |
| §2.2 Submission: Save & Apply + Control | Task 9 |
| §2.3 Import: client parse + preview + populate | Task 8 |
| §2.4 PBR inline table | Task 7 |
| §2.5 Geo manual CIDR textarea | Task 11 (form), Task 5 (state) |
| §2.6 Polling 5s default + user-configurable | Task 6 + Task 10 |
| §2.7 XSS: textContent over innerHTML | All JS tasks (zero innerHTML=raw) |
| §2.8 No api.github.com | Verified by Task 14 (lint_asp) and absence in code |
| §2.9 Dirty tracking | Task 5 + Task 10 |
| §3.1 Files | Tasks 1-13 |
| §3.2 JS modules | Tasks 2-10 (one per module) |
| §4 HTML layout | Task 11 |
| §5.1-5.3 Parser + Validator parity | Tasks 3-4 |
| §6 Forms, event handlers, submission | Tasks 5, 7, 8, 9, 10 |
| §7.1 JSON extension | Task 1 |
| §7.2 Polling behaviour | Task 6 |
| §8 XSS hygiene | Tasks 2-10 (architecture), Task 14 (verification) |
| §9 Testing | Task 3, 4 (Node), Task 1 (bats), Task 13 (runner) |
| §10 CSS | Task 12 |
| §11 DoD | Tasks 14, 15, 16 |

All spec requirements mapped to at least one task.

### Placeholder scan

- No `TBD`, `TODO`, `implement later`, `similar to`, or `add error handling` in the plan.
- Every Step includes full code or exact command.

### Type consistency

- `AWG.config.readForm()` returns flat object keyed by `awg_*` throughout (Tasks 5, 9).
- `AWG.pbr.snapshot()` returns `[{ip, mac, name, policy}]` identically in Tasks 7, 5.
- Status JSON field names (`state`, `endpoint`, `handshake_age_seconds`, `leases`, `killswitch_armed`) match between backend (Task 1) and client (Task 6).
- `SCALAR_KEYS` list in `AWG.config` matches form inputs in HTML (Task 11).
- `AWG.validator.validateAll(config)` takes `{interface, peer}` shape; `AWG.parser.parseConf()` returns same shape; tests verify (Tasks 3, 4).

No consistency issues.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-20-module-4-webui-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review
   (spec compliance then code quality) after each. Consistent with M1/M2/M3
   workflow (cumulative: 47 + 20 + 18 = 85 commits so far).

2. **Inline Execution** — batch execution with checkpoints for review; stays in
   this session.

Which approach?
