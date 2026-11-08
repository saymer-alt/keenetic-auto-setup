// KAS vendor entry for kas-mini (Stage B1, issue saymer-alt/keenetic-auto-setup#425).
//
// This file is compiled INSIDE the pinned web4core tree (PROVENANCE.json sourceSha, dev
// override KAS_MINI_SOURCE_DIR) so the relative imports of the upstream entry and the
// shared web4core modules resolve unchanged. Generation stays single-sourced in web4core:
// this file only re-exports the upstream API and adds the panel mount (kas-mini-mount.js).
//
// Integration boundary — Variant A (docs/35-web-autosetup-stage-a.md §4.1): esbuild
// --format=iife --global-name=KasMini, loaded by the panel as a classic <script defer>;
// handoff happens only through the exported API (generation/state methods). The panel
// never reads kas-mini DOM (the preview textarea is not an interface).
export {
    buildMiniMihomoConfig,
    applyMiniSettings,
    vetWireGuardConf,
    redactLine,
    createMiniUiState,
    readWgFileEntries,
    MINI_NOTES,
} from './entry-kas-mini.js';
export { mountKasMini } from './kas-mini-mount.js';

// Embedded provenance: must equal PROVENANCE.json sourceSha (asserted by
// tests/kas-mini-vendor.test.cjs and web/control-center/kas_mini_vendor_test.go).
export const KAS_MINI_VENDOR = Object.freeze({
    sourceRepo: 'https://github.com/saymer-alt/web4core',
    sourceSha: '519da90a6bc75049498169f0fcd7a02054f7e104',
    stage: 'B1',
    issue: 'saymer-alt/keenetic-auto-setup#425',
});

// Guarded auto-mount (Variant A): the panel provides an empty #kas-mini-root container;
// absent container or document (other pages, Node test sandbox) leaves the module inert.
if (typeof document !== 'undefined') {
    const root = document.getElementById('kas-mini-root');
    if (root && !root.dataset.kasMiniMounted) mountKasMini(root);
}
