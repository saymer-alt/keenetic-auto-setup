# Manual Mihomo update from panel — implementation plan

User authorized implementation of manual update checking and canonical component
updates; begin with Mihomo. Inline execution in existing isolated feature worktree.
No router actions or merge/main/stable edits. No automatic startup/background update.

Goal: manually inspect the fixed entware-go latest channel, show available package
for compiled architecture vs runtime version, and invoke canonical update-mihomo.sh
only after a second explicit confirmation. No arbitrary URLs, args, commands, force,
opkg upgrade-all, configuration rewrite or user-controlled executable.

Architecture: embedded source-identical updater (same model as Doctor/importer),
fixed POST /api/updates/check and /api/updates/mihomo, GET /api/updates/operation.
Origin/content-type/fetch-site/confirmation/empty-body guards. Fixed GitHub API,
10s check timeout, 1MiB cap, proxy+redirect disabled. Select unique uploaded stable
asset with exact project URL/name/arch; unsupported or malformed metadata unknown.
No asset binary is fetched by checking. Runtime version comes only from local API.
Same runtime may still have newer package release; canonical updater decides. Older
known runtime candidates disabled. The preview is informational, not a pinned
artifact approval: confirmation explicitly invokes fixed channel's canonical updater.

Mutations reuse existing importRunning exclusive maintenance flag: imports,
filters, Doctor, settings and updater cannot overlap. Canonical updater retains
shared shell lifecycle lock, one-Mihomo, staged commit, config immutability and
rollback. Worker survives request cancellation. Graceful panel shutdown drains it.
No shell output returned/logged. Before/after bounded streaming file digests classify
changed/unchanged/unverified; failed updater never claims rollback.

Steps:
- [ ] RED Go tests: metadata selection/trust/bounds, update HTTP guards/busy,
      async completion/cancel, fixed runner/no output leaks, file outcome.
- [ ] Implement updates.go; embed byte-identical updater, wire route/init fields.
- [ ] RED Node UI tests: check manual only, cancel no POST, duplicate starts,
      busy mutation guards, outcomes; implement existing overview card RU/EN.
- [ ] Full Go/race/vet, Node/browser/package qualification; independent review.
- [ ] Publish draft changes and run CI. Do not publish a hardware test release
      until full canonical updater transaction via panel is qualified in a guest
      or redirected full-script fixture, including no-op/failure recovery.

Deferred: MT feed update, watchdog/core migration, panel self-update, release signing
protocol. Those need component-specific source/version/transaction evidence.

## Qualification and review ledger

- Metadata/HTTP/runner tests first failed on missing behavior. Node tests first
  failed on missing controls; implementation now passes 39 Node tests.
- Go race test reproduced shared response/worker entry capture; fixed by passing
  the operation value to the goroutine. Full Go test/race/vet pass.
- Full source updater via HTTP passes changed, older/no-op, and new-start failure
  recovery. Real filesystem contents, config bytes, restored service marker and
  metadata absence are asserted; synthetic process/PID/network seams are explicit.
- Fresh independent reviewer identified phantom RUNNING after another tab replaces
  status, lost POST response not reconciled, and missing Entware TLS trust roots.
  Each was reproduced RED and fixed GREEN. Root TLS fixture verifies untrusted CA
  refusal, protected Entware CA acceptance, writable trust-bundle refusal. Native
  root CI includes TestInventoryEntwareUpdateTrust. TLS stays verified, with
  X25519/P-256 compatibility curves (no hybrid ClientHello path dependency).
- Actual Chromium passes explicit-check/no-startup-network, cancel/no-write,
  accepted/no-op, busy UI and existing navigation/filter/settings tests at 4 widths.
- Real-opkg panel packaging 8/8 and 484 Markdown links pass locally.
- Minor deferred: valid starter asset makes this stricter metadata checker refuse
  even an otherwise healthy ABI. Canonical updater has a narrower skip rule; no
  success or unsafe fallback is invented. Current live release has uploaded assets.
- Isolate the new feature in feat/kas-web-mihomo-updates / a stacked draft PR, based
  on tested c3cc2ce. No router writes or main/stable/merge. Published-head CI and
  physical acceptance of the new update action remain required.
