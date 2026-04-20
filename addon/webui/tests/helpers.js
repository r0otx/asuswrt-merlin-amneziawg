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
