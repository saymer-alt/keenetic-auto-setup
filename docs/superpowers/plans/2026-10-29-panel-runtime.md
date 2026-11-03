# Useful panel overview and Doctor results

User approved continuing the previously described panel work, without another
approval round. Existing isolated feat/kas-core-ipk worktree; no router writes.

Problem proven on KN-1010: installed scripts display absent package/unconfirmed
watchdog, service cards only show files, Doctor exit wording hides findings.

Design: fixed read-only process identity inspection through /proc; bounded local
Mihomo GET /version, never execute Mihomo. MagiTrickle package version is explicitly
labelled as package metadata, not running executable version. No shell status
scripts (they can have side effects), arbitrary HTTP targets or config/secret reads.
Existing optional exporter API credentials may be reused only against loopback.
Watchdog without receipt shows actual digest, not invented semantic version.
Doctor summary counts/verdict must match its final anchored summary and exit code;
missing/malformed summary stays unknown; nonzero command failure remains distinct.

Steps: write failing Go/Node regressions; implement parsers/inspection and UI;
run Go/race/vet, Node, package tests and browser fixture; review; publish draft
branch changes and inspect CI. No automatic release, merge or router actions.
Future gate: actual guest panel-IPK reboot and core adoption policy remain open.
Packaging numbering must use monotonic numeric CI run counter for future releases; Git SHA
alone is not an upgrade order. No release will be made from this unverified work.

## Evidence / decisions

- Go summary, version, process and metadata tests were first observed failing on
  missing behavior; Node regressions failed on old file-only labels, generic
  Doctor command failure, and unconfirmed script watchdog. All now pass.
- Restricted proc regression reproduced false stopped; now returns unknown.
- Go full test/race/vet pass. Node 34/34, real Chromium (including new overview
  and Doctor warnings, 4 widths/dark mode), panel IPK 8/8 with real Entware opkg,
  and 484 docs links pass locally.
- Fresh reviewer found no blockers. Source-description nit corrected; source
  timestamp ordering concern resolved by using GitHub workflow run counter.
- Actual pinned Entware opkg compare-versions confirms 0.0.1~testRUN.SHA-1
  supersedes both released 0.0.0~git versions; a higher RUN supersedes a lower RUN
  even when its Git SHA sorts earlier. Same-run retry retains the same version.
- No semantic version is invented for older watchdog files: show actual SHA256.
- Published-head CI and physical acceptance of this new revision remain open.
  Existing KN-1010 acceptance applies to 894a524, not these new changes.
