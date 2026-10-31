# KAS WEB beta.2 — one canonical release, user-selected update channels

**Status:** implementation design accepted as work item, **NOT implemented/CI qualified** in this document. Source base [WEB integration #291](https://github.com/saymer-alt/keenetic-auto-setup/pull/291); product acceptance [#289](https://github.com/saymer-alt/keenetic-auto-setup/issues/289). Owner (30.10.2026): beta.1 is on **one test KN-1010 only**, a one-time manual beta1→beta2 upgrade is acceptable. beta2 should be the first user-distributed edition.

## Non-negotiable upgrade contract

A user installs beta.2 only once. After that, every newer beta, stable release, or next stable version can be fetched **manually in WEB** without an obligatory SSH upgrade or duplicate release assets. Selecting a channel does **not** perform installation, reboot router, change firewall/VPN or route traffic. No background auto-update. On failure, leave the installed service intact where preflight permits; do not promise opkg rollback.

## Code dependencies and implementation plan

Current beta1 hard-codes `panelBuildChannel` in `panel_update.go` check/apply and `panel_update_worker.go` execution; `parsePanelIndex` in `panel_update_package.go` allows only `kas-web-ipk-<sha>` in experimental and `kas-web-vN.N.N` in stable; validation binds IPK `BUILD_INFO.Channel` to the candidate channel. Simply adding a UI dropdown would **not** work.

### 1. Selected update channel is per-installation preference, not the binary's build channel

- Add independent private persisted `selected_update_channel` with exact values `experimental` / `stable` (no arbitrary URL); preserve it through `opkg install`, upgrade, removal/recovery according to settings ownership. Default `experimental` on beta builds, `stable` on stable builds only when no persisted preference exists.
- Consider evolving `panelConfig` settings schema carefully; existing `Version=1` JSON must remain readable. Prefer a small isolated `/opt/etc/kas-control-center.update-channel` 0600 root-owned file or a backward-compatible optional settings field with atomic write/fdatasync. Do not make existing password/port setup invalidate channel selection.
- Backend API `GET/POST /api/updates/panel/channel`: GET read-only, POST exactly one validated channel, maximum body size, no duplicate/unknown fields, authenticated via existing router panel middleware, same-origin Host/Origin and confirmation header, reject during import/panel update/worker gate. No caller-supplied hosts/tags/assets/URLs. Re-check under app mutex; invalidate prior checked candidate when changed; log only channel name (no credentials).
- UI Settings shows RU/EN names, description and availability; changing selector requires explicit confirm and reports success/failure. Use existing CSS/accessibility. Only the current channel may propose an update; no silent background polling/cross-channel promotion.

### 2. Immutable canonical releases and stable channel

- **One** `v0.1.0-beta.2` GitHub prerelease containing 4 architecture-specific IPKs (marking untested ABI as experimental) and `SHA256SUMS`, all built from **one** checked source SHA. No duplicate `kas-web-ipk-<SHA>` release starting beta2.
- `kas-web-channel-experimental` and `kas-web-channel-stable` are channel pointers containing only `panel-update.json` and not package binaries. At index build time, exact asset URI points to `v0.1.0-beta.2` for beta or `kas-web-v0.1.0` (canonical stable tag to be settled without collision) for stable. Candidate release must be public and match prerelease flag appropriate to selected channel. GitHub repository `latest` remains KAS **Core** `v1.8.x`, never the WEB release.
- Existing beta1 experimental `kas-web-ipk-<sha>` parser/index path may remain only as migration fallback (not necessary to preserve upgrade from beta1 after manual owner transition), but do not break the currently installed 1010 until owner approves updating it. Under no circumstance use `GET /releases/latest` as updater authority or derive URL from browser input.

### 3. Strict runtime candidate validation across channel changes

- Candidate `Version` via real Entware `opkg compare-versions candidate >> installed`, never `>=`, lexicographic compare or `--force-downgrade`. `0.1.0~beta.2-1` should precede `0.1.0-1` using opkg semantics, and succeed after beta.1. Explicitly test this ordering.
- `panelBuildChannel` remains *source build provenance*, but does not hard-code *which update channel is selected*. In `panel_update_worker.go` replace `j.Channel == "experimental" && j.Channel == panelBuildChannel` with strict whitelisted selected-channel admission. Candidate `BUILD_INFO.Channel` must match the **candidate package's declared channel**; do not disable this check. The caller's chosen channel, candidate release class, source SHA, ABI/ELF, validated manifest and candidate package metadata all must agree. Establish desired cross-channel policy explicitly: stable→beta is opt-in and only if strictly newer; experimental→stable is allowed when stable strictly newer. Never let unknown/mismatched payload bypass validation.
- Check/apply/worker retain `checkedAt` 10-minute TTL, detached worker, lock/gate, private receipt, free-space checks and immutable configured release host. If the channel changes between check and apply/worker, fail closed (no stale approved candidate).
- After successful beta→stable package install/restart, confirm **the stable binary's runtime identity** with receipt; previous choice remains stable and the page reports stable as selected. Preserve port, credentials, br0 restriction, all Mihomo/MT files and active exclude filters.

### 4. CI and field acceptance for user-facing beta2

Test with disposable real opkg and native ARM64 runner, QEMU-user and Keenetic ported fixture, without claiming QEMU==hardware:

1. Fresh beta2 install + choose beta and save/reload preference, choose stable and save/reload, reboot equivalent, restart service, change port/auth without preference loss.
2. Synthetic source-pinned `beta2→beta3` canonical release (same channel); `beta2→stable` candidate (different prerelease class, same repo), real detached IPK install, validated final runtime `Version/SourceSHA`, credentials and config preserved, no repeat same-version prompt.
3. `stable→next stable` success; `stable→beta` only explicit + strictly newer; refuse equal/older versions.
4. Invalid tag/channel, prerelease mismatch, digest/size/ABI/ELF/SourceSHA forged, bad manifest JSON, missing index, GitHub 404, opkg lock, interrupted opkg, wrong runtime, stale checked candidate, cross-origin and unauthenticated POST — no dangerous write.
5. No second Mihomo process, no unintended Netfilter/config.yaml changes, no `latest` promotion or background auto-update.
6. Manually install beta2 on owner's KN-1010 after CI and verify settings/channel, Doctor, subscriptions, existing filters, self-update into a dummy next compatible beta or evidence-equivalent isolated target before release to broad users. Physical ARM64 acceptance remains separately limited.

### 5. Release+cleanup dependencies and status gates

- WEB integration PR [#291](https://github.com/saymer-alt/keenetic-auto-setup/pull/291) combines prior Draft PR stack onto current `main`; still review 141 file diff, and independent CI. Do not merge just to reduce branch count.
- Release cleanup archive: [`kas-web-legacy-tests-archive-20261030`](https://github.com/saymer-alt/keenetic-auto-setup/releases/tag/kas-web-legacy-tests-archive-20261030). Nine short-lived prereleases retired with immutable source tags retained; [Actions evidence](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/41031652114). Retain active experimental channel, its referenced beta1 alias, public beta1 and key field-test releases.
- Document compatibility and manual update of the **single** owner's beta1 pilot in beta2 release notes. Do not distribute beta2 or change channel indexes until source-pinned CI and explicit GO.
- Clean obsolete `publish/*` ref branches only with exact SHA/release-tag archival evidence; do not delete any still serving open PRs. All irreversible release cleanup requires source tag + binary/digest archival before deletion.
