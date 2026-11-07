# AGENTS.md — KAS stable: production agent essentials

For Codex/ZCode on production `stable`. Read this first; use [full detailed policy](docs/AGENT-DETAILED-REFERENCE.md) by relevant section, not as a startup dump. Dated field history is not current proof. No permission to alter production.

## Authority, owner GO and working-first

- [KAS Constitution](docs/CONSTITUTION.md) is **binding in all tasks**, especially KAS-SAFETY-001. Exact source at the intended ref, explicit owner decisions, and applicable detailed [stable rules](docs/AGENT-DETAILED-REFERENCE.md) define implementation constraints; old observations are not live evidence. If uncertain, investigate read-only, then stop the unsafe step.
- **Explicit owner GO** is required separately for code commit/push, merge, moving `main`/`stable`, tag/release/`latest`, deploy, deleting data, or any live router/VPS mutation. A task to inspect, draft a PR or correct docs is not permission for publishing. No reset-hard, force-push, overwriting another agent's edits, or silent broad cleanup.
- **WORKING-FIRST / licence decision (2026-10-11):** prioritize functioning independent software, IPKs, safety and CI. Routine global licence audits are deferred to [KAS #126](https://github.com/saymer-alt/keenetic-auto-setup/issues/126); do not repeatedly re-open them. This **does not** grant redistribution rights to third-party code, waive copyright/NOTICE, excuse a confirmed violation, or bypass security/release approval. Read [original owner policy](docs/AGENT-DETAILED-REFERENCE.md) when that issue is in scope.
- `main` is development, `stable` is what production installs fetch. Never import an entire diverged `main` branch or assume its docs/tests/runtime match `stable`. For release promotion, review exact-SHA runtime drift, CI, and hardware-dependent acceptance; tag the specifically approved production commit only. No automatic router test.

## Never weaken safety contracts

- **KAS-SAFETY-001:** verified native KeeneticOS zRAM **together with** external storage-backed swap is forbidden on every RAM class and `/opt` mode. Installer **ERROR before download/mutation**; Doctor **FAIL**; `update-mihomo.sh` **ERROR before stopping the service/binary mutation**. Never downgrade to WARN/INFO, add overrides/exceptions, infer backend from a filename alone, or auto-toggle SWAP. The standalone [Constitution](docs/CONSTITUTION.md) is the authoritative specification.
- **RAM/storage resource profile `20261012_1`:** new 128 MB installs are best-effort and require verified external `/opt` and ≥384 MB **external** swap (zRAM does not qualify); 256 MB missing zRAM/external-swap is WARN; 512 MB without one *verified* backend is Installer ERROR / Doctor FAIL (no AP or model exception). On external swap, below 1× RAM is WARN, 3× RAM is the preferred target and 2 GiB is the maximum supported new-install size; above 512 MB swap is optional, absent other violations. No automatic formatting, repairing, enabling, resizing or mounting swap/storage. See [resource/mount guide](docs/06-s00ubifs.md) and full [platform rules](docs/AGENT-DETAILED-REFERENCE.md).
- For new external Entware `/opt`, require actual deepest mount **EXT4** and KeeneticOS `ext` + `ext-utils`. Internal `/opt` needs verified enabled/executable S00ubifs and live tmpfs mounts for `/opt/tmp`, `/opt/var/log` and `/opt/var/run`. Doctor failures remain FAIL; existing legacy updater limitations are distinct from installer gates.
- Keep a **single Mihomo instance**, executable-identity proof, lock ownership, same-filesystem staged atomic commits, per-run backup/rollback, project binary provenance and prior-service restoration. `pidof` absence never proves a process stopped; UNKNOWN stops a safety-critical transaction. Never replace a verified canonical binary during an unchanged repeat install. Managed download retries must be **quiet per attempt**: no per-attempt transport stderr/WARN spam; retain bounded retries (including X25519 compatibility), one exhaustion summary before the next fallback, and safe config-import/updater transaction ordering. See [lock guide](docs/19-lifecycle-lock.md) and [install](docs/03-install.md) / [updates](docs/12-updates.md).
- Preserve watchdog **WAN-before-restart**, cooldown and lock; no restart loop on external WAN failure. Preserve `020-bypass-wa.sh` idempotent mangle custom chain, no global firewall flush, and existing ProxyN ownership/name. Do not modify foreign interfaces, router policy, firewall, DNS, routes, user config or subscribers without separate explicit operator permission.
- Router runtime is **BusyBox ash/POSIX**, not GNU. Guard optional utilities and options (e.g. no GNU `stat -c` on field BusyBox 1.37); `show version` can hard-wrap IDs, but `show running-config` line breaks are semantic. Ambiguous or unavailable external evidence is UNKNOWN, not an optimistic PASS. Never post credentials, subscriptions or unredacted fleet diagnostics.

## Task gate and token economy

1. State the **observable user goal**, exact repository branch/base/head SHA and evidence of already completed work. For critical work specify protected state, dependencies, non-goals, negative cases and precise Definition of Done; a technically literal but harmful change is FAIL. Do not invent hidden permissions from “cleanup”, “release” or “merge”.
2. Locate affected functions, callers, shared state and relevant tests using [SCRIPTS inventory](docs/SCRIPTS.md). **Proven low-risk local wording/read-only changes** may start with bounded exact-ref reads; **before any safety-critical script change**, read every affected script **fully once for the exact unchanged SHA** plus connected contracts and regressions. Ambiguous impact escalates to full review; do not read an entire repository by default.
3. Preserve working fallback chains and use the smallest safe diff. Run cheap syntax/targeted regressions first (`sh -n` for every changed shell script, `sh tests/contracts.sh` if relevant); all required exact-SHA CI, BusyBox and release gates still apply. Host CI/mock/QEMU does **not** prove a physical Keenetic acceptance. No live experiments without owner GO.
4. **Loop guard:** after two futile identical attempts at the same state, change hypothesis or mark BLOCKED; avoid repeated full log reads. Reuse evidence only for matching SHA, environment and test scope. Logs should cite an actual failed step; do not silently weaken tests or create broad harnesses for narrow bugs.
5. Report actual change SHA, passed/failed/not-tested gates, evidence links, blockers, rollback risk and exact next step. Separate PLANNED / IMPLEMENTED / CI PASS / EMULATOR PASS / FIELD PASS / MERGED / PUBLISHED. No fabricated PASS, silent scope expansion or automatic release.

## Read on demand — NOT every session

| Task | Relevant **stable** source |
| --- | --- |
| Detailed historical binding instructions, architecture, policy, risk zones, Git, testing and known pitfalls | [Full stable agent reference](docs/AGENT-DETAILED-REFERENCE.md) — **only relevant sections** |
| zRAM/SWAP absolute blocker | [Constitution](docs/CONSTITUTION.md), [resource profile](docs/06-s00ubifs.md) |
| Installation, import and rollback | [Install](docs/03-install.md), [config import](docs/13-config-import.md), [update/maintenance](docs/12-updates.md), [lifecycle lock](docs/19-lifecycle-lock.md) |
| ProxyN/MagiTrickle/TUN/DNS | [Architecture](ARCHITECTURE.md), [bypass](docs/05-bypass-wa.md) |
| Watchdog / executable output | [Watchdog](docs/04-watchdog.md), [output severity](docs/18-output-colors.md) |
| Tests, hardware evidence, release gate | [Testing Strategy](docs/TESTING_STRATEGY.md) — prefer required gate and relevant section; old field cases are not current fleet state |

Production behavior is governed by the actual `stable` code and the above constraints, never by a later `main`-only prototype. Keep this startup guide short; place detailed and dated evidence only in its matching on-demand reference.
