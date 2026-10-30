# KAS panel navigation implementation plan

Goal: make the existing panel navigable and usable on desktop and phones.
Architecture: static HTML/CSS plus a small local navigation script; existing app.js remains the API adapter.
Tech stack: embedded HTML, CSS, vanilla JavaScript, Go.
Spec: docs/superpowers/specs/2026-10-28-panel-navigation-design.md

Constraints: no external fonts, scripts or router dependencies; retain canonical importer and all operation guards; RU/EN parity; never equate binary presence with service health.
Review focus: switching views during imports; hidden selected search rows; keyboard focus; long provider/node names; mobile overflow.

- [x] Restructure web/control-center/web/index.html into five views preserving existing control IDs; add web/navigation.js for local view switching and keyboard navigation.
- [x] Restyle web/style.css with responsive sidebar, cards, separated node rows, accessible controls and system dark theme.
- [x] Update app.js copy, navigation translations, binary-presence cards, search and selection count without changing request handling.
- [x] Run existing Node and Go checks; exercise real Chromium at desktop/mobile widths with sanitized API fixtures, including preview/apply/clear, cancellation, search and language changes.
- [x] Review the diff and capture desktop/mobile previews. Keep the change on a feature branch; do not merge stable or alter a router.
