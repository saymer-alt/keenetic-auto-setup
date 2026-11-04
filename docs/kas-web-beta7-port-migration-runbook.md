# KAS WEB beta.7 — guarded one-time legacy port 8081 migration

**Scope:** only a saved version-1 settings file whose port is exactly `8081`, when started with the normal IPK `-lan -listen auto` and default `-initial-port 18080`. Other saved ports, explicit listeners, non-LAN mode, and settings with invalid content are untouched.

## Startup transaction

1. Load the original private `/opt/etc/kas-control-center.settings.json` (existing `0600` file). This config contains the effective auth mode and potentially the password hash. Home-only is a separate file and is never written.
2. Bind an actual TCP listener to `0.0.0.0:18080`; on `EADDRINUSE` only, try `18081` … `18090` in order. Do **not** probe ports separately and do not move on permission/bind errors.
3. Re-read settings and compare the persisted fields, then create an exclusive, private, synced backup `/opt/etc/kas-control-center.settings.json.pre-beta7-8081.bak`. A mismatched or unsafe pre-existing backup fails closed; it is never overwritten.
4. After confirming settings still match, atomically replace the active JSON with the chosen port. Preserve `auth_mode` and `password_hash` unchanged; `auto_port_fallback` records only a nondefault selected port.
5. On success, serve the newly selected address and emit `LEGACY_PORT_MIGRATED` plus the actual `PANEL_ADDRESS` through the existing filtered init-script startup/status output. The Settings page reports the migration and links to the new address only after the existing trusted-host check. KeenDNS rules remain administrator-owned.

**Safety:** any failure to bind or safely persist settings aborts startup and closes the bound socket; do not replace settings with a guessed port. A subsequent normal launch sees a saved port other than 8081 and does not migrate again. No firewall, routing, Home-only, proxy origin, password, Mihomo, MagiTrickle, KAS Core or update gate changes.

## Manual recovery / rollback (operator only)

Before installing any field candidate, export the current settings and separately document the working URL, authorization and KeenDNS mapping. Keep the original `8081` backup private (may contain a password hash). Do not paste its contents into public issues or Doctor reports.

If the panel cannot start after migration:

1. Inspect `sh /opt/etc/init.d/S98kas-control-center status` and the latest filtered startup report; check the actual `PANEL_ADDRESS` and any `LEGACY_PORT_MIGRATED` marker.
2. If service is running, visit `http://<router-LAN-IP>:<chosen-port>/` and use the normal Settings UI to select another available port if required. Update any KeenDNS mapping manually.
3. If the settings must be rolled back, **stop the service**, keep a copy of the migrated JSON, verify the private `.pre-beta7-8081.bak` copy and restore it through an atomic same-directory file replacement under a controlled maintenance procedure. Restoring `8081` while beta.7 automatic migration remains enabled will just migrate again; first use an explicitly configured listener/approved older build, and **only** when `8081` is actually free. Do not automatically replace the backup or downgrade by overwriting live binaries.
4. No automatic package rollback is claimed. Never clear the durable self-update gate as a migration workaround. If an update is gated, use the separately documented explicit recovery procedure.

## Release/field gates

- Offline: initial free 18080, EADDRINUSE fallback 18081, exhausted 18080–18090, EACCES fail-closed, mismatched or symlink backup refusal, first-run vs saved custom ports, persisted credentials; no implicit auth/Home-only changes.
- NC-4210: actual legacy settings 8081 → 18080/18081, reboot stability, protected password modes, Home-only, old URL failure and new URL availability, no Opkg/Mihomo/MT impact.
- KN-1012 SE: clean install plus migration fixtures; LAN/WAN per existing KeeneticOS policy, and standard KeenDNS GET/POST proxy including Origin/Host. All device installation requires separate owner GO.
- Candidate cross-build all four ABI using `kas-web-candidate-build.yml` **after** PR review and integration; no Release/Pages before owner GO.

**Important limitation:** old settings do not record whether port 8081 was manually selected or inherited from defaults. The only objectively available migration predicate is the exact legacy port together with the standard IPK auto-listener. This must be disclosed during field acceptance, not presented as historical provenance.
