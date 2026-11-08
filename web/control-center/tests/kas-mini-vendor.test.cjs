// Stage B1 (issue #425) vendor integrity tests for the vendored kas-mini bundle.
// Run by web-control-center.yml (`node --test web/control-center/tests/*.test.cjs`).
// Provenance contract: kas-mini-vendor/PROVENANCE.json + build-vendor.mjs --verify (CI).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const panelDir = path.resolve(__dirname, '..');
const bundlePath = path.join(panelDir, 'web', 'kas-mini.js');
const indexHtmlPath = path.join(panelDir, 'web', 'index.html');
const appJsPath = path.join(panelDir, 'web', 'app.js');
const provPath = path.join(panelDir, 'kas-mini-vendor', 'PROVENANCE.json');

// Hard pin: bumping the source requires an explicit sync PR that regenerates
// PROVENANCE.json and the bundle (build-vendor.mjs --update-provenance).
const KAS_MINI_PIN = '519da90a6bc75049498169f0fcd7a02054f7e104';

// Network/persistence capability tokens that must never appear in the offline bundle.
// 'WebSocket' is deliberately NOT banned: the minified bundle legitimately contains the
// string "Sec-WebSocket-Protocol" (a YAML field value). URLs from upstream data tables
// (connectivity-check endpoints) are inert string constants — the capability tokens
// below prove they cannot be requested.
const BANNED = [
    'fetch(', 'XMLHttpRequest', 'EventSource', 'importScripts',
    'localStorage', 'sessionStorage', 'indexedDB', 'document.cookie',
    'web2core', 'workers.dev', // upstream CORS fallback must stay out of kas-mini
];

test('provenance: pinned source SHA and checksum match the committed bundle', () => {
    const prov = JSON.parse(fs.readFileSync(provPath, 'utf8'));
    assert.equal(prov.sourceSha, KAS_MINI_PIN);
    assert.match(prov.sourceRepo, /^https:\/\/github\.com\//);
    const bundle = fs.readFileSync(bundlePath);
    const entry = prov.files && prov.files['kas-mini.js'];
    assert.ok(entry, 'PROVENANCE.json must record the kas-mini.js asset');
    assert.equal(entry.sha256, createHash('sha256').update(bundle).digest('hex'));
    assert.equal(entry.bytes, bundle.length);
    assert.ok(prov.esbuild && prov.esbuild.version && !/SET-BY-BUILD/.test(prov.esbuild.version), 'esbuild version recorded');
});

test('bundle defines the KasMini global (Variant A boundary, docs/35 §4.1)', () => {
    const bundle = fs.readFileSync(bundlePath, 'utf8');
    assert.ok(bundle.startsWith('var KasMini='), 'esbuild --format=iife --global-name=KasMini output expected');
    for (const name of ['buildMiniMihomoConfig', 'mountKasMini', 'KAS_MINI_VENDOR']) {
        assert.ok(bundle.includes(name), `exported API member missing: ${name}`);
    }
});

test('bundle is offline: no network/persistence capability tokens', () => {
    const bundle = fs.readFileSync(bundlePath, 'utf8');
    for (const token of BANNED) {
        assert.ok(!bundle.includes(token), `banned token present in vendored bundle: ${token}`);
    }
});

test('KasMini API: synthetic URI generates the canonical default YAML in a clean sandbox', () => {
    const bundle = fs.readFileSync(bundlePath, 'utf8');
    const sandbox = { crypto: require('node:crypto').webcrypto, console, URL: require('node:url').URL };
    vm.runInNewContext(bundle, sandbox); // no document in sandbox → guarded auto-mount stays inert
    const KasMini = sandbox.KasMini;
    assert.ok(KasMini, 'var KasMini must land on the sandbox global');
    assert.equal(typeof KasMini.mountKasMini, 'function');
    assert.equal(KasMini.KAS_MINI_VENDOR.sourceSha, KAS_MINI_PIN);

    // Synthetic, nonsecret placeholder fixture (same shape as upstream kas-mini tests).
    const vless = 'vless://11111111-2222-3333-4444-555555555555@example.com:443?encryption=none&security=reality&sni=www.example.com&fp=chrome&pbk=xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D&sid=ab&type=tcp&flow=xtls-rprx-vision#NodeVLESS';
    const r = KasMini.buildMiniMihomoConfig({
        linksText: vless,
        allowLan: true,
        mixedOn: true,
        mixedPort: 7890,
        webUI: true,
        tun: true,
        mipsStack: true,
    });
    assert.ok(r.yaml.includes('mixed-port: 7890'), 'default output carries the canonical KAS mixed-port');
    assert.ok(r.yaml.includes('secret:'), 'external-controller must be secret-protected');
    assert.ok(r.yaml.includes('auto-route: false'), 'TUN must not auto-route (KAS scenario)');
    assert.equal(r.report.nodes, 1);

    // Documents the B2 pre-check need: a profile-less YAML drops mixed-port and would
    // fail both import gates — B2 pins the KAS profile, it must not weaken the gates.
    const off = KasMini.buildMiniMihomoConfig({ linksText: vless, mixedOn: false });
    assert.ok(!off.yaml.includes('mixed-port:'));
});

test('panel boundary: core panel scripts never reference kas-mini; wiring is index.html + bundle only', () => {
    const appJs = fs.readFileSync(appJsPath, 'utf8');
    assert.ok(!appJs.includes('KasMini'), 'app.js must not depend on the vendored bundle');
    assert.ok(!appJs.includes('kas-mini'), 'app.js must not read kas-mini DOM (no scraping of the preview)');

    const html = fs.readFileSync(indexHtmlPath, 'utf8');
    assert.equal(html.split('id="kas-mini-root"').length - 1, 1, 'exactly one kas-mini container');
    assert.equal(html.split('src="/kas-mini.js"').length - 1, 1, 'exactly one kas-mini script tag');
    assert.ok(!/type="module"/.test(html), 'panel stays classic-script (Variant A)');
});
