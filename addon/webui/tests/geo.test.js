// addon/webui/tests/geo.test.js — unit tests for AWG.geo pure helpers + validator.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { loadAWG } = require('./helpers.js');

test('AWG.geo.CURATED has 16 fixed categories in declared order', () => {
    const AWG = loadAWG();
    const expected = [
        'google', 'youtube', 'netflix', 'telegram', 'cloudflare',
        'github', 'discord', 'twitter', 'meta', 'tiktok',
        'cn', 'ru', 'by', 'ua', 'private', 'tor'
    ];
    assert.deepEqual(AWG.geo.CURATED, expected);
});

test('AWG.geo.MODES are off/vpn/direct', () => {
    const AWG = loadAWG();
    assert.deepEqual(AWG.geo.MODES, ['off', 'vpn', 'direct']);
});

test('AWG.geo.modeKey builds state key name', () => {
    const AWG = loadAWG();
    assert.strictEqual(AWG.geo.modeKey('ru'), 'awg_geo_ru_mode');
    assert.strictEqual(AWG.geo.modeKey('google'), 'awg_geo_google_mode');
});

test('AWG.geo.modeToIpset routes modes to correct ipsets', () => {
    const AWG = loadAWG();
    assert.strictEqual(AWG.geo.modeToIpset('vpn'), 'awg_geo_dst');
    assert.strictEqual(AWG.geo.modeToIpset('direct'), 'awg_geo_direct');
    assert.strictEqual(AWG.geo.modeToIpset('off'), null);
    assert.strictEqual(AWG.geo.modeToIpset('bogus'), null);
});

test('AWG.geo.categoryMode reads from state with default off', () => {
    const AWG = loadAWG();
    assert.strictEqual(AWG.geo.categoryMode({}, 'ru'), 'off');
    assert.strictEqual(AWG.geo.categoryMode({ awg_geo_ru_mode: 'direct' }, 'ru'), 'direct');
    assert.strictEqual(AWG.geo.categoryMode({ awg_geo_ru_mode: 'vpn' }, 'ru'), 'vpn');
    assert.strictEqual(AWG.geo.categoryMode({ awg_geo_ru_mode: 'bogus' }, 'ru'), 'off');
    assert.strictEqual(AWG.geo.categoryMode(null, 'ru'), 'off');
});

test('AWG.validator accepts vpn_except_geo policy', () => {
    const AWG = loadAWG();
    assert.ok(AWG.validator.validatePolicy('vpn_all'));
    assert.ok(AWG.validator.validatePolicy('vpn_geo'));
    assert.ok(AWG.validator.validatePolicy('vpn_except_geo'));
    assert.ok(AWG.validator.validatePolicy('direct'));
    assert.ok(!AWG.validator.validatePolicy('whatever'));
    assert.ok(!AWG.validator.validatePolicy(''));
    assert.ok(!AWG.validator.validatePolicy(null));
});

test('AWG.validator.validateGeoMode accepts off/vpn/direct only', () => {
    const AWG = loadAWG();
    assert.ok(AWG.validator.validateGeoMode('off'));
    assert.ok(AWG.validator.validateGeoMode('vpn'));
    assert.ok(AWG.validator.validateGeoMode('direct'));
    assert.ok(!AWG.validator.validateGeoMode('bypass'));
    assert.ok(!AWG.validator.validateGeoMode(''));
    assert.ok(!AWG.validator.validateGeoMode(null));
});

test('AWG.pbr.POLICIES contains vpn_except_geo in declared order', () => {
    const AWG = loadAWG();
    assert.ok(Array.isArray(AWG.pbr.POLICIES));
    assert.deepEqual(AWG.pbr.POLICIES,
        ['vpn_all', 'vpn_geo', 'vpn_except_geo', 'direct']);
});
