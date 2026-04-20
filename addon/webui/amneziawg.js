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

})(window);
