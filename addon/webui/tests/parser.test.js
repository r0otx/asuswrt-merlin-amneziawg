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
