# KAS panel navigation and visual refresh

The KN-1010 operator reports that the working panel is hard to use: every function is in one long column and node labels have no visual separation. The supplied rendered text confirms the problem.

Use five local views: Overview, Subscriptions, Configuration, Diagnostics, Settings. Desktop navigation is a sidebar; narrow screens use a wrapping navigation bar. Keep one HTML document, embedded assets, system fonts and no runtime dependencies. Preserve every existing API and importer guard. Status cards explicitly describe binary presence, never infer running services or network health.

Alternatives: restyling the long page is cheap but retains navigation friction; separate server routes duplicate structure and introduce unnecessary backend work; client-side view switching gives direct access without backend changes. Native KeeneticOS cannot arrange this experimental KAS panel. No change leaves the reported problem unresolved. Benefit is high for routine operator use, implementation/maintenance cost is low, no router dependencies are added.

Subscriptions get separated checkbox rows, local name search, a selected count and clear operation messages. Hidden search matches remain selected and the count includes them. Navigation and language changes must preserve selections, pasted YAML and in-flight operation polling. Technical explanations stay in expandable help. Light/dark appearance follows the system. A narrow screen must have no horizontal page overflow; keyboard navigation and visible focus remain available.

Acceptance: existing 12 browser-contract tests and Go tests remain green; real-browser checks cover view navigation, mobile width, translations, search selection preservation and filter apply/clear request ordering. No backend, service lifecycle, authentication or router configuration changes.

## Owner delivery requirements, 28 Oct 2026

- The panel remains a separately installed, optional experimental component. Do not add it automatically to normal KAS installations. Bundling can be revisited after acceptance by other real owners, beyond the KN-1010 operator's tests.
- Target new-install port: 8081. Existing installations retain their explicitly recorded port; migration must preserve the old experimental 18081 address until an explicit change. Fresh IPK/runtime default is now8081. The legacy manual helper explicitly retains initial18081; a saved port overrides both.
- Port conflict must produce a specific error with the address/port. Never stop the other application or silently select a different port. On a requested port change, reserve the new listener before abandoning the old one; a failed bind/save must leave the existing panel reachable. Bind failure remains authoritative, because an earlier availability probe alone races with other services.
- Deliver an architecture-specific `kas-control-center` IPK with binary, init service and opkg-managed ownership. Test installation, update, retained settings, removal, occupied-port failure and failed-update recovery in the emulator. Uninstall must preserve KAS core, Mihomo/config/backups, MagiTrickle and operator settings. Do not blindly combine the manual helper's ownership digest with opkg-managed file replacement.
- Initially publish explicit experimental IPK assets with checksums; a package feed is a later distribution improvement, not a prerequisite for an optional test package.
- Settings scope: optional Home-only source restriction; authentication disabled / Entware account / separate panel password; editable panel port. Entware mode means the existing account/password, not a hardcoded root/keenetic pair and not the KeeneticOS admin account. Reusing the account does not authorize the panel to change the system password.

Implementation adds a dedicated confirmed settings API, credential helpers, transactional live port replacement, explicit startup conflict output and optional IPKs. Local Go/race/browser and actual Entware opkg offline-root checks pass. New source-pinned CI/emulator runs and publication remain acceptance gates.
