# kas-mini-vendor — vendored kas-mini build (Stage B1, issue #425)

Reproducible vendoring of the kas-mini Mini Generator bundle ([web4core PR #28][pr28],
Phase 0 of [keenetic-auto-setup#425][i425]) into KAS Web. The generated bundle is
`web/kas-mini.js`; it is served by the existing panel static handler and embedded via
`go:embed web/*` — no new backend code, no importers, no apply wiring (bounded owner GO:
read-only UI experiment, review 5818028422).

## Contract

- **Pinned source:** `PROVENANCE.json` `sourceSha` (web4core tree at that exact commit;
  `sourcePull` is only a fetch fallback).
- **KAS-owned adapter sources** (compiled inside the pinned tree): `vendor-entry.js`
  (re-exports the upstream API) and `kas-mini-mount.js` (panel mount, adapted from the
  upstream `kas-mini/index.html` at the pinned SHA; ids prefixed `km-`, scoped to
  `#kas-mini-root`).
- **Integration boundary — Variant A** (docs/35-web-autosetup-stage-a.md §4.1):
  esbuild `--format=iife --global-name=KasMini`, classic `<script defer>`; handoff only
  through the exported API; the panel never reads kas-mini DOM.
- **Offline:** no fetch/XHR/storage/cookies and no upstream CORS fallback
  (`web2core`/`workers.dev`) — enforced by `tests/kas-mini-vendor.test.cjs`.
- **Reproducibility:** CI rebuilds from `sourceSha` and requires a **byte-identical**
  committed asset (`web-control-center.yml` → `build-vendor.mjs --verify`).

## Commands

```bash
# CI verify (no writes): fetch pinned SHA → rebuild → byte-compare
node web/control-center/kas-mini-vendor/build-vendor.mjs --verify

# Dev: rebuild + overwrite asset; refresh PROVENANCE.json (hash/bytes/esbuild) for a sync PR
node web/control-center/kas-mini-vendor/build-vendor.mjs --update-provenance

# Dev convenience (no network): existing checkout exactly at the pinned SHA
KAS_MINI_SOURCE_DIR=/path/to/web4core node .../build-vendor.mjs --update-provenance
```

`ESBUILD_BIN=/path/esbuild` skips `npm ci` (esbuild version is then read from
`--version`; CI uses the web4core package-lock). Only PC/CI — routers have no Node.js.

## Update policy

Bump `sourceSha` + regenerate the asset **only** in an explicit sync PR
(`Refs #425`); never hand-edit `web/kas-mini.js` or the recorded hashes.

[pr28]: https://github.com/saymer-alt/web4core/pull/28
[i425]: https://github.com/saymer-alt/keenetic-auto-setup/issues/425
