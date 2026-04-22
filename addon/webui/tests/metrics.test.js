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
