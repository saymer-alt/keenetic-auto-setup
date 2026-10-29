# Component updates implementation plan

> Inline execution under executing-plans; existing authorization covers implementation,
> draft publication and lab tests, not router operations or production promotion.

Goal: remove runtime/package version ambiguity and expose explicit MagiTrickle
maintenance using the documented Entware commands.

Architecture: retain the Mihomo canonical updater unchanged. Show its API version,
opkg metadata and validated project-state release separately. A matching runtime
without valid project state is not proof of an available package rebuild. Only a
newer runtime or a newer recorded package release enables normal update; unknown
runtime retains canonical repair. Invalid project state blocks package-only update.

For MT use the existing configured opkg repositories, not GitHub release guesses.
Manual check refreshes indices and reads `opkg status magitrickle` and
`opkg list-upgradable`; only an exact installed/current/candidate match is offered.
No upgrade row means no upgrade offered by opkg, not universal latest-version proof.
Explicit apply refreshes/rechecks and runs only `opkg install magitrickle`, then
the documented init restart and executable-matched process verification. No force,
upgrade-all, arbitrary args/URLs or repo installation. Package manager owns its
conffile and maintainer-hook semantics; no transactional MT rollback is claimed.

MT requires a confirmed running service and uptime over 300 seconds before apply:
the upstream postinst unconditionally restarts by default and the Keenetic init has
a background startup loop during early boot. Refuse unknown/stopped/early-boot state
rather than silently enable a stopped service. A package update can temporarily
interrupt DNS/routing. Config snapshots/digests before and after detect unexpected
changes; do not silently overwrite concurrent configuration edits.

All check/apply calls use fixed origin/confirmation/JSON guards and the panel's
exclusive maintenance slot. Check-only opkg processes have bounded context; package
installation is independent of browser cancellation and is never timeout-killed.
UI distinguishes MT and Mihomo results and resumes the single worker status.

Approaches: chosen documented opkg maintenance because MT is package managed;
direct GitHub binary replacement would bypass package ownership and conffiles.
Bundling MT into the panel would add unrelated lifecycle/version ownership.

Review focus: stale opkg metadata, package hooks returning success without a process,
stopped service unexpectedly starting, config edits during upgrade, stale status in
another tab. Tests cover each modeled boundary; real firmware acceptance remains
separate from redirected command fixtures.

Tasks:
- [x] RED/GREEN provenance parsing: protected KAS state vs API/file size/arch;
      separate opkg version; same/newer/older release and stale state fixtures.
- [x] RED/GREEN MT runner and HTTP: fixed command sequence, exact status parsing,
      check/apply failures, exclusive slot, cancelled browser, process/config checks.
- [x] RED/GREEN RU/EN UI: separate cards, manual check, confirmation, disable on
      no upgrade, common busy state and component-specific results.
- [ ] Go/race/vet, Node/Chromium, package checks, fresh whole-branch review;
      draft PR on tested #268. No hardware release before CI.

Evidence sources: repository docs/12-updates.md; upstream MagiTrickle commit
042e15c6a45d7f8acfc107d8df909fdb67fc7275, files/entware/_ipk/control/{postinst,conffiles}
and files/entware_kn/etc/init.d/S99magitrickle. Upstream conffiles includes
/opt/var/lib/magitrickle/config.yaml and /opt/etc/config/magitrickle.conf.

Qualification ledger:
- Go suite/race/vet, 44 Node tests and Chromium navigation/confirmation/MT result
  and common busy states pass; four widths, RU/EN and existing flows retained.
- Actual Entware opkg with a local fixture feed upgrades, retains both modified
  conffiles and performs a second no-op without reinstall/restart. The mandatory
  IPK CI job now runs this fixture using the verified official opkg executable.
- Eight existing panel IPK tests and 484 local Markdown links pass.
- Fresh whole-change review found one P2: cancelling opkg metadata could leave
  wget holding the output pipe and panel slot. Reproduced RED (4s wait despite
  100ms cancellation), fixed GREEN with 2s WaitDelay and metadata-only process
  group cancellation. A delayed child-write regression proves downloader exit.
  install/restart have no request cancellation hook and are not timeout-killed.
- Empty duplicate KAS receipt key reproduced RED and fixed GREEN; old opkg
  metadata still cannot authorize a package-only binary update.
- Lost HTTP response with the old successful operation ID reproduced RED for
  both components; neither old result is now presented as the new operation.
- Process/uptime/init seams remain synthetic; physical MT update acceptance and
  exact published-source CI remain pending. No real router writes or main merge.
