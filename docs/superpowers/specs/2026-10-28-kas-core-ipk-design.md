# KAS packages and Web maintenance — approved direction

Approved by the owner on 2026-10-28 after the packaging/status discussion.

## Intent

One consistent set of existing KAS scripts, usable from SSH and the optional Web
panel. Package scripts rather than rewrite their lifecycle algorithms. Keep
Mihomo and MagiTrickle as independent packages. Display installed versions and
manually check available updates; no automatic installation.

Proposed split: `kas-core` (scripts), `kas-control-center` (UI and dependency on a
compatible core), optional `kas-full` dependency-only convenience package.
The package split is conditional on proving safe adoption and replacement of
existing files. Removing the UI must leave KAS operational.

## Approaches

1. Put live watchdog/init/netfilter files directly in data.tar.gz. Simplest,
   but acceptable only if replacement, failure and removal preserve KAS safety.
2. Package a validated script bundle and activate operational files through
   existing transactional installers/updaters. Adds a deployment boundary but
   preserves lifecycle locking and atomic replacement. The bundle is an input;
   the deployed canonical watchdog remains the only scheduled watchdog.
3. Keep separate embedded script copies in the UI. Rejected by the approved
   direction: console and Web copies would drift and require parallel upkeep.

The owner approved testing the first two approaches, with evidence before
committing to either. An IPK archive does not imply execution of its scripts.

## First deliverable: packaging qualification

Produce a non-release laboratory `kas-core` archive containing current project
scripts, provenance and per-file hashes in `/opt/libexec/kas`. It must not place
files in active init/cron/netfilter namespaces or change router configuration.
Use real Entware opkg offline-root to check install/upgrade/remove and modified
file protection. Characterize direct live-file packaging separately with
synthetic scripts, including failed postinst and package removal.

This is NOT the production core migration or a usable replacement for an
installed KAS. Do not add a panel dependency on this lab package. Do not publish
it as an installable release. Qualification results determine the activation
adapter, adoption policy and uninstall contract for the next deliverable.

## Subsequent deliverables

- Activate recognized canonical files through existing transactional mechanisms;
  reject modified/foreign files and unproven downgrade cases. Removal must not
  leave active cron/init references to removed payload.
- Panel version/build identity, component inventory and GitHub link. Runtime
  Mihomo version comes from the local API, never a second concurrent Mihomo.
- Doctor reports optional Web presence/version and provider filters without
  subscription URLs, keys or secrets. Missing optional Web is informational.
- Manual update checks with explicit unavailable/unknown states, followed by
  fixed allowlisted maintenance actions through canonical scripts.
- Interface, selected proxy and site diagnostics; migration actions only after
  applicable preconditions and confirmation. No arbitrary shell endpoint.

## Constraints and acceptance

No real-router operations, main/stable/latest changes, automatic update or Web
uninstall in this work. Preserve settings/YAML/credentials and existing
rollback, resource and lifecycle contracts. Source SHA alone does not order
versions. Test classes must distinguish offline-root opkg, host Linux, QEMU
user-mode, guest firmware and physical routers.

Full acceptance also requires guest boot with the actual panel IPK installed;
existing native web stages do not establish this. Host package tests must not
be described as guest boot or hardware acceptance.
