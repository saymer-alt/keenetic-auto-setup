# User feedback: links, theme and diagnostic follow-up

Owner feedback 29 October: open MT and MetaCubeXD in separate tabs, link the
configuration generator, offer a manual dark theme, and expand site diagnostics.
Inline execution in an isolated feature branch on #269; no router or production edits.

Chosen approach: ordinary browser links to the current HTTP router hostname at
standard MT :8080/ and MetaCubeXD :9090/ui/. Never hard-code 192.168.1.1, transfer
credentials/query strings or frame/proxy another panel. Mark ports as defaults;
custom ports are not discovered. HTTPS/reverse-proxy origin cannot establish the
local service address, so leave service links unavailable with an explanation.
Generator is the existing HTTPS Pages application, not embedded/copied into KAS.

Theme: auto/light/dark, initialized before CSS from a validated kas_theme browser
preference. Auto follows OS CSS media preference. Manual light overrides dark OS
and vice versa. No router settings writes or backend request for this choice.
Reuse existing design tokens rather than adding a second stylesheet/framework.

Tasks:
- [x] RED/GREEN UI tests: current-host links, new-tab/no-opener, HTTPS refusal,
      generator target, theme persistence and invalid preference fallback.
- [x] Implement theme.js, index controls, RU/EN text and existing CSS tokens.
- [x] Chromium: manual/auto themes, reload, storage failure, four widths and
      existing MT/Mihomo/settings/filter flows. Node/Go/package checks and review.
- [ ] Publish a stacked draft; do not imply these changes exist in test9/test10.

Diagnostics follow-up is deliberately a separate deliverable, tracked in the
feedback issue and #222. Existing mihomo-route-check.sh v1.0.0 checks DNS, filtered
ProxyN evidence, local SOCKS port, selected group and bounded SOCKS5h request.
Web integration needs target validation/argv-only execution, explicit action,
shared maintenance exclusion, bounded process-tree cancellation/output/redaction,
and client/router vantage labels. Exit 0 is not site/client health. Do not infer
DNS-cache cause or reset networking automatically from one report.

Retained real scenario: after a domain was added to MT it opened on other LAN
devices but not one PC until network settings were reinitialized. Cause unknown.
Acceptance must compare affected client DNS answer, browser secure DNS/proxy/VPN,
IPv4/IPv6, current connections and MT policy with the router report. Keep the
existing Doctor report and copy action; do not replace them with this target check.

Follow-up issue: https://github.com/saymer-alt/keenetic-auto-setup/issues/270.

Qualification ledger:
- Seven new UI scenarios failed before implementation; all 51 Node tests pass.
- Chromium verifies explicit dark on a light OS, explicit light on a dark OS,
  automatic media changes and preference after reload, alongside existing flows
  and four widths. Storage failures are covered by the Node fixture.
- Go suite and all eight panel IPK tests pass; 484 local links pass.
- Fresh review found no must-fix product defects. Its required test fix was
  reproduced by the browser timeout: navigation resets to Overview on reload,
  so reopen Settings before waiting for its theme control. Fixed; Chromium passes.
- Deferred minor coverage: the URL fixture tests query/hash removal but not
  userinfo explicitly; IPv6 browser URL construction also lacks a dedicated case.
  Source clears username/password and uses URL host/port semantics.
- No diagnostic execution adapter is shipped here; #270 retains that scope and
  the unconfirmed affected-PC scenario. No router settings/services changed.
