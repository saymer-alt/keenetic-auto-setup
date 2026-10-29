# Readable Doctor report — implementation plan

User approved implementation of #274 after KN-1010 acceptance of test13. Scope:
first stage, a localized interpretation of the existing read-only Doctor report.
The subsequent panel self-update remains #273; panel installation-path checks in
Doctor remain a later #274 step. No router writes or stable/main changes.

Proof: the supplied KN-1010 report contains model, storage class and free/total
space, RAM/swap, service and watchdog observations; users currently must interpret
English technical output. Alternatives: leave raw output (does not address the
reported support burden); change Doctor to a new machine protocol (larger shared
shell contract migration); bounded versioned parsing of the already-redacted
report (chosen as smallest useful stage). No dependencies or new commands.
Cost: maintain known line grammar alongside Doctor versions. Unknown versions,
missing/contradictory fields or incomplete footer must never become healthy facts.

Architecture: web/doctor-report.js is a pure bounded parser and text-only RU/EN
renderer. It receives the existing API details/summary/exit code; it independently
requires the complete consistent footer and a supported Doctor version. Only
recognized section-scoped fields become cards. All WARN/FAIL lines retain their
severity and section; raw report/copy stays unchanged. No server/API mutations,
localStorage, automatic probes, HTML from stdout or invented network diagnosis.

- [x] Write Node tests for the sanitized real KN-1010 output shape, warning/failure,
  missing/contradictory numbers, footer/version mismatch, CRLF/ANSI and unknown text.
  Observe RED, implement parser, observe GREEN.
- [x] Write integration tests for RU/EN redraw, missing data, no raw HTML insertion,
  no report persistence or extra Doctor calls. Implement accessible cards and
  findings; add real Chromium layout/translation/reload assertions.
- [ ] Run Node suite, Go test/vet, package tests, syntax/diff checks. Review branch,
  fix blockers, publish stacked draft PR and inspect exact-head CI.

Acceptance: show model/OS, internal/external/ram/unknown /opt, source/filesystem,
free/total MB, RAM and swap, observed services, watchdog heartbeat and event counts
with history interval. Unknowns remain visible. Findings are not dropped if their
text is unfamiliar: generic localized severity/category with original evidence.
Clock strings are reported as source-local strings without pretending they are UTC.
No healthy-heartbeat count is described as uptime, restart count or ISP reliability.

## Evidence / rulings

- Parser and UI integration initially failed on absent module/cards; subsequent
  grammar-correction and contradictory WARN/footer tests were observed RED→GREEN.
- 63 Node tests PASS; Go suite/vet PASS; 9 IPK tests PASS including real official
  Entware opkg in an isolated root; JS syntax and whitespace checks PASS.
- Ruling: scope is the Diagnostics view after explicit Doctor, not an automatic
  live storage meter in Overview. Reuse report data to avoid extra probes; label
  the observation as from the last Doctor run. Live storage refresh is separate.
- Ruling: unknown findings receive localized severity/category and retain their
  exact technical evidence rather than guessing an explanation; complete message
  translation remains later work. Unknown Doctor versions suppress this overview.
- Real Chromium and source-head emulated/packaging acceptance remain for CI;
  hardware acceptance of the readable overview has not occurred.

- Independent review found a real pre-section multi-Mihomo warning could lose its
  evidence. A regression was observed RED (0 findings instead of 1), then GREEN
  after assigning preamble findings to the generic category.

- Independent review: no critical findings; the important preamble-warning issue
  is fixed. Deferred minor: explicit no-swap output still shows unknown in the
  swap card, not “Not configured”; raw evidence and Doctor severity are retained.
