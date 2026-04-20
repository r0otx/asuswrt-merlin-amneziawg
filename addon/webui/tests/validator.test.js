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
