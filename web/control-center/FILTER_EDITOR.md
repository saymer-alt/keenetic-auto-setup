# KAS Web — scoped Exclude Filter editor (R&D Stage 1)

## Decision
Reuse the opt-in local Mihomo provider-names snapshot from [KAS PR #261](https://github.com/saymer-alt/keenetic-auto-setup/pull/261), then offer a **separate** local editor of `proxy-providers.<name>.exclude-filter`. Do **not** embed the full link-generators builder, subscription downloader, HWID management or Cloudflare Worker.

## Stage 1 scope (this PR)
- Pure Go, no new dependency and no changes to the running router: `patchProviderFilter` modifies **one exact YAML line** or removes it; the rest of the YAML stays byte-for-byte. Never return the full modified config through HTTP.
- Only explicitly selected HTTP providers; exact selected Unicode names escaped with Go regexp.QuoteMeta; 512-name / 8 KiB regex bounds. Replacement or explicit clear, not hidden merging of an existing manual regex.
- Deliberately unsupported YAML provider shapes (inline/flow mapping, YAML anchors/merge, multiline filter, duplicate keys, unusual indentation) fail closed. Use ordinary full YAML importer for these.
- Pure regression tests cover first add/replace/clear, untouched provider and secret, no-op, malformed/unsupported, double selection, and digests.

## Following gates
1. Add read-only provider discovery & preview: sanitized names, existing filter, selected names, config SHA256 concurrency guard. Never reveal subscription URLs, UUIDs, passwords or raw config in responses/logs.
2. Add explicit confirmation and *only* the existing canonical `config-import.sh` transaction for apply: exact YAML snapshot digest, maintenance lock, `mihomo -t`, controlled stop/start and rollback. Confirm the race window with external concurrent file writers is closed before enabling writes.
3. Read-after-apply: reload provider names, status; note that already excluded nodes can disappear from Mihomo's provider API. Provide a clear-filter action, and do not claim current API lists all originally available nodes.
4. Natively validate on Router Emulator and then on a spare Keenetic; simulate two providers, malformed YAML, external edits, Unicode, empty providers, 401, 5xx, reboot, and rollback. No change to main/stable until GO.

This PR does **not** yet provide a working HTTP mutation endpoint. Do not promise ready-to-deploy UI until gates 1–4 pass.
