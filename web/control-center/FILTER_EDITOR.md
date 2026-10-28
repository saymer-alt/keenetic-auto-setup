# KAS Web — scoped Exclude Filter editor (R&D Stage 1 + 2)

## Decision
Reuse the opt-in local Mihomo provider-names snapshot from [KAS PR #261](https://github.com/saymer-alt/keenetic-auto-setup/pull/261), then offer a **separate** local editor of `proxy-providers.<name>.exclude-filter`. Do **not** embed the full link-generators builder, subscription downloader, HWID management or Cloudflare Worker.

## Stage 1 scope
- Pure Go, no new dependency: `patchProviderFilter` modifies **one exact YAML line** or removes it; the rest of the YAML stays byte-for-byte. Never return the full modified config through HTTP.
- Only explicitly selected HTTP providers; exact selected Unicode names escaped with Go regexp.QuoteMeta; 512-name / 8 KiB regex bounds. Replacement or explicit clear, not hidden merging of an existing manual regex.
- Deliberately unsupported YAML provider shapes (inline/flow mapping, YAML anchors/merge, multiline filter, duplicate keys, unusual indentation) fail closed. Use ordinary full YAML importer for these.
- Read-only discovery (`GET /api/filter/providers`) and preview (`POST /api/filter/preview`): sanitized names, existing filter, full-file SHA256, candidate digest. Node names verified against the sanitized live Mihomo provider API; never raw YAML, subscription URLs or credentials in responses or logs.

## Stage 2 scope (this branch): explicit apply through the canonical importer
- `POST /api/filter/apply` — same origin/content-type/`X-KAS-Confirm: apply`/Sec-Fetch-Site guards as preview; one mutating operation at a time (shared single-flight slot with YAML import and Doctor); strict JSON; no client-controlled paths.
- The candidate and the operator-approved source snapshot are staged as two private 0600 temp files with unpredictable O_EXCL names and deleted after the run. The snapshot is handed to the canonical importer via the **opt-in `KAS_EXPECTED_SOURCE` gate** (config-import.sh): under the lifecycle lock and **before Mihomo is stopped**, the on-disk config must still be byte-identical to the approved snapshot, and the same comparison repeats immediately before the atomic rename. Any change between preview and the transaction aborts with a clear error and never applies the stale variant.
- All transactional work remains in the stock `config-import.sh`: project contract check, lifecycle lock, one-Mihomo validation (`mihomo -t`), previous-config backup, same-filesystem atomic replace, start/port verification, rollback and service-state restoration. The web adapter duplicates none of it.
- No-op detection: applying an identical replacement or clearing when no filter exists returns `applied:false` without touching Mihomo.
- Clearing works **without** node names and without a Mihomo names snapshot: already excluded nodes may be absent from the runtime listing.
- Unset `KAS_EXPECTED_SOURCE` keeps the importer's historical behavior byte-for-byte (gate is read-only, uses the project-proven `cmp -s` primitive, fails closed when `cmp` is unavailable).

## Concurrency contract (honest boundary)
- Against KAS tools that honor the lifecycle lock, the gate is airtight: the approved version is proven under the lock.
- A writer that ignores the lock (manual `nano` over SSH, `scp`, `rsync`) is detected if it lands before the pre-commit comparison. A write landing strictly between that final comparison and the rename itself is overwritten by the candidate and is NOT retained in `config.yaml.bak`; the backup contains the earlier config. Do not edit or copy `config.yaml` with other tools during an apply operation. This residual window is real, is pinned by `tests/config-import-filter-gate-regression.py` (writer injected at reproducible transaction seams), and must not be described as eliminated.
- Prevention against arbitrary non-cooperating writers is impossible on Keenetic/Entware without invasive measures (immutable flags are unsupported on UBIFS/tmpfs, flock/fcntl only bind cooperating processes). The supported contract is: operator approval + lock serialization + version re-proof + retained backup.

## Tests
- Go regressions: guards, stale 409, busy 409, no-op, clear without loaded names, unloaded node rejection, staging permissions, expected-source env passing, no config/URL leakage in any response.
- `tests/config-import-filter-gate-regression.py` runs the REAL importer in a lab: gate A abort before stop (writer's bytes preserved), gate B abort during the validate/backup window (service restored), the residual-window boundary demonstration, fail-closed without `cmp`, rollback on validation/start failure, and unset-gate compatibility — under `sh` and BusyBox ash where available.
- `tests/transaction-invariants.py` pins the gate ordering inside the transaction.
- Native: `.github/workflows/web-filter-native-e2e.yml` (stage `web-filter`) runs the editor in the Router Emulator guest with two real HTTP providers served from the committed fixtures, verifies the actual Mihomo provider listing after apply and clear, and exercises the real importer gate directly on the guest.

This PR must stay Draft until the native web-filter E2E and independent hardware results pass plus owner GO.
