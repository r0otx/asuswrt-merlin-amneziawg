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

        function validatePolicy(p) {
            return p === 'vpn_all' || p === 'vpn_geo'
                || p === 'vpn_except_geo' || p === 'direct';
        }
        function validateGeoMode(m) {
            return m === 'off' || m === 'vpn' || m === 'direct';
        }

        return {
            validateKey: validateKey,
            validateAddr: validateAddr,
            validateEndpoint: validateEndpoint,
            validateCidrList: validateCidrList,
            validateIntRange: validateIntRange,
            validateHValue: validateHValue,
            validateISeq: validateISeq,
            validateAll: validateAll,
            validatePolicy: validatePolicy,
            validateGeoMode: validateGeoMode
        };
    })();

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

            // Geo status (Module 5)
            var geoStatusEl = AWG.util.$('awg-geo-status');
            if (geoStatusEl && AWG.geo && AWG.geo.renderStatus) {
                AWG.geo.renderStatus(geoStatusEl, status.geo);
            }

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

            var path = document.createElementNS(svgNs, 'path');
            path.setAttribute('class', 'awg-spark-line');
            path.setAttribute('d', buildPath(points, key));
            svg.appendChild(path);

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


    // ---------- AWG.pbr ----------

    AWG.pbr = (function () {
        var _devices = [];
        var _leases = [];

        var POLICIES = ['vpn_all', 'vpn_geo', 'vpn_except_geo', 'direct'];

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
            POLICIES: POLICIES,
            setDevices: setDevices,
            snapshot: snapshot,
            add: add,
            remove: remove,
            updateLeasePicker: updateLeasePicker,
            addFromLeasePicker: addFromLeasePicker,
            addManual: addManual
        };
    })();


    // ---------- AWG.geo ----------

    AWG.geo = (function () {
        var CURATED = [
            'google', 'youtube', 'netflix', 'telegram', 'cloudflare',
            'github', 'discord', 'twitter', 'meta', 'tiktok',
            'cn', 'ru', 'by', 'ua', 'private', 'tor'
        ];
        var MODES = ['off', 'vpn', 'direct'];

        function modeKey(cat) { return 'awg_geo_' + cat + '_mode'; }
        function modeToIpset(mode) {
            if (mode === 'vpn')    return 'awg_geo_dst';
            if (mode === 'direct') return 'awg_geo_direct';
            return null;
        }
        function categoryMode(state, cat) {
            var v = state && state[modeKey(cat)];
            return (v === 'vpn' || v === 'direct') ? v : 'off';
        }

        function renderCategoryRow(state, cat) {
            var tr = document.createElement('tr');
            var tdName = document.createElement('td');
            tdName.textContent = cat;
            var tdMode = document.createElement('td');
            var sel = document.createElement('select');
            sel.name = modeKey(cat);
            sel.className = 'awg-geo-mode';
            for (var i = 0; i < MODES.length; i++) {
                var opt = document.createElement('option');
                opt.value = MODES[i];
                opt.textContent = MODES[i];
                if (categoryMode(state, cat) === MODES[i]) opt.selected = true;
                sel.appendChild(opt);
            }
            tdMode.appendChild(sel);
            tr.appendChild(tdName);
            tr.appendChild(tdMode);
            return tr;
        }

        function renderAll(tbody, state) {
            while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
            for (var i = 0; i < CURATED.length; i++) {
                tbody.appendChild(renderCategoryRow(state, CURATED[i]));
            }
            var custom = ((state && state.awg_geo_categories_custom) || '')
                .split(',').map(function (s) { return s.trim(); }).filter(Boolean);
            for (var j = 0; j < custom.length; j++) {
                tbody.appendChild(renderCategoryRow(state, custom[j]));
            }
        }

        function syncNow(onResult) {
            var form = new FormData();
            form.append('action_mode', ' Restart ');
            form.append('action_script', 'start_awggeosync');
            fetch('/apply.cgi', { method: 'POST', body: form, credentials: 'same-origin' })
                .then(function (r) { onResult(r.ok, null); })
                .catch(function (e) { onResult(false, String(e)); });
        }

        function renderStatus(el, geoJson) {
            if (!geoJson) { el.textContent = 'n/a'; return; }
            var parts = [];
            if (geoJson.last_sync && geoJson.last_sync > 0) {
                parts.push('last sync: ' + new Date(geoJson.last_sync * 1000).toISOString());
            } else {
                parts.push('last sync: never');
            }
            parts.push('enabled: ' + ((geoJson.enabled || []).length));
            if (geoJson.errors && geoJson.errors.length > 0) {
                parts.push('errors: ' + geoJson.errors.join(', '));
            }
            el.textContent = parts.join(' · ');
        }

        return {
            CURATED: CURATED,
            MODES: MODES,
            modeKey: modeKey,
            modeToIpset: modeToIpset,
            categoryMode: categoryMode,
            renderCategoryRow: renderCategoryRow,
            renderAll: renderAll,
            syncNow: syncNow,
            renderStatus: renderStatus
        };
    })();


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

            // 3b. GeoIP fieldset (Module 5)
            var geoTbody = document.querySelector('#awg-geo-table tbody');
            if (geoTbody && AWG.geo && AWG.geo.renderAll) {
                AWG.geo.renderAll(geoTbody, cs);
                var geoInputs = geoTbody.querySelectorAll('select');
                for (var gi = 0; gi < geoInputs.length; gi++) {
                    geoInputs[gi].addEventListener('change', AWG.config.markDirty);
                }
            }
            var geoBtn = document.getElementById('awg-geo-sync-btn');
            var geoStatus = document.getElementById('awg-geo-status');
            if (geoBtn && geoStatus) {
                geoBtn.addEventListener('click', function () {
                    geoBtn.disabled = true;
                    geoStatus.textContent = 'syncing…';
                    AWG.geo.syncNow(function (ok, err) {
                        geoBtn.disabled = false;
                        geoStatus.textContent = ok ? 'sync started' : ('error: ' + (err || 'unknown'));
                    });
                });
            }

            // 4. Start polling
            var intervalSec = parseInt(cs.awg_ui_poll_interval || '5', 10);
            if (!(intervalSec >= 1 && intervalSec <= 60)) intervalSec = 5;
            AWG.status.startPolling(intervalSec * 1000);

            // Metrics polling — one tick per minute by default (12× the status interval)
            if (AWG.metrics && AWG.metrics.poll) {
                AWG.metrics.poll(intervalSec * 12 * 1000);
            }

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

})(window);
