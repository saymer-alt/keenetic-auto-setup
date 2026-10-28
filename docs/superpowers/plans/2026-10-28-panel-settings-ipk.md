# Panel settings and optional IPK implementation

Goal: deliver approved settings and optional packages without affecting KAS core.
Architecture: private versioned JSON, immutable live authentication snapshot, live port rebind that reserves the new listener before persistence/closing the old one, independent opkg lifecycle.

- [x] Strict confirmed same-origin Go settings API; serialization with importer/Doctor; private atomic persistence; no credential output or fail-open on corrupt files.
- [x] Auth disabled / kas separate salted password / root current Entware password. Never store or change system credentials; retain legacy optional password support. Check wrong/changed/locked credentials.
- [x] Fresh port8081; explicit legacy18081 retained. Bind/save failure preserves old listener/settings; successful switch returns new URL. Shutdown drains imports and listeners.
- [x] Settings UI with clear conflict errors and credential confirmation, no passwords persisted in browser.
- [x] Optional IPK artifacts, safe separate ownership/init, preserve user settings/KAS core, no automatic KAS installation.
- [ ] Node/Go/race, crossbuild, Chromium, package archive/hooks and native CI checks. Do not reuse earlier UI-only emulator evidence for these changes.
