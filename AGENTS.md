# AGENTS.md — KAS agent essentials

Small startup contract for Codex, ZCode and other coding agents. **Do not load whole documentation trees or historical archives by default.** Instructions here are binding summaries; [docs/CONSTITUTION.md](docs/CONSTITUTION.md) and explicit owner decisions define non-negotiable policy. Read task-specific docs only when needed.

## Goal and scope

KAS is a KeeneticOS + Entware toolkit for Mihomo/ProxyN, MagiTrickle, bypass rules, storage protection and watchdog. Improve demonstrable user behavior with minimal, reversible changes. Do not rewrite proven routing or rollback paths merely to simplify code. New features/major integrations require [Proof Before Build](docs/PROOF-BEFORE-BUILD.md); narrowly scoped defect fixes need proportional evidence.

**KAS-AGENT-001:** satisfy the actual user objective, not a literal but harmful interpretation. **Before drafting or executing any KAS agent task**, consult [docs/CONSTITUTION.md](docs/CONSTITUTION.md) and [docs/AGENT-TASK-CONTRACT.md](docs/AGENT-TASK-CONTRACT.md); for a narrow routine task, read the applicable rules, not unrelated examples. For complex/risky work, use the complete task contract: goal, exact refs/SHA, existing work, scope/non-goals, protected state, negative cases, permissions/GO and Definition of Done. An ambiguous "clean up", "release" or "merge" is NOT permission to destroy or publish. Pause only the unsafe step, proceed with safe authorized work.

## Never weaken these safety contracts

- **KAS-SAFETY-001:** verified native zRAM **together with** external storage-backed SWAP is prohibited: installer ERROR before mutation, Doctor FAIL, updater ERROR before service/binary mutation. No downgrade to WARN, overrides, automatic backend changes or exceptions. See [docs/CONSTITUTION.md](docs/CONSTITUTION.md).
- Preserve RAM/storage gates: 512 MB new installs need native zRAM OR valid external swap; new external /opt requires EXT4 plus `ext`/`ext-utils`; internal /opt needs verified S00ubifs/tmpfs. Never auto-format or alter swap. Detailed 128/256/512 MB rules: [docs/06-s00ubifs.md](docs/06-s00ubifs.md).
- Preserve lifecycle lock, one-Mihomo discipline, atomic same-filesystem commit, rollback, config backup, process identity and prior service state in installers/updaters/import/migration. Unknown safety evidence => STOP that mutation, not optimistic success.
- Preserve watchdog WAN-before-restart rule, cooldown/lock, idempotent `020-bypass-wa.sh` custom iptables mangle chain, and ownership of ProxyN. Do not modify foreign interfaces, user subscriptions, routes, firewall, DNS or live router configuration without explicit operator permission.
- Runtime is **BusyBox ash/POSIX**, not GNU/Linux; guard optional commands/options (for example no GNU `stat -c` on target BusyBox). `show version` may wrap component identifiers; never merge lines of `show running-config`. Missing or ambiguous evidence is UNKNOWN.
- Public code must not expose credentials or real router inventories. WORKING-FIRST does not grant permission to redistribute third-party code without rights; keep licence notices, avoid repeated global license-audit loops for unrelated components.

## Git and release control

- `main` is development; `stable` is production. Verify branch/HEAD, working tree, current Issue/PR and actual file/blob SHA. Search indexes and old reports are not current proof. Don't overwrite unrelated edits, reset hard, force-push or silently modify shared branches.
- Commit/push, merge, release, delete, deploy, change `latest`/update channels or operate physical routers **only with explicit owner GO for the respective action**. Permission for a PR is not permission for publication.
- Promote `main → stable` only after exact-SHA CI, required review/acceptance and owner GO. Before each Core release report **runtime-file drift** between main/stable (included and excluded changes); do not merge unrelated unfinished development.
- Keep evidence states distinct: PLANNED / IMPLEMENTED / CI PASS / EMULATOR PASS / FIELD PASS / MERGED / PUBLISHED. Linux CI and emulator results are not proof from physical Keenetic hardware.

## Focused working loop (and token economy)

1. Determine the affected component and exact baseline. Read relevant code and task-focused documentation; do not recursively read the repository or all historical files. For safety-critical script modifications, read that script fully **once per relevant SHA**, then use targeted reads.
2. Make the smallest safe diff with a negative/regression case; preserve working fallbacks. Run cheap local checks before costly CI/QEMU; never skip mandatory release gates. `sh -n` for every changed shell script; `sh tests/contracts.sh` for cross-component smoke when applicable.
3. **Loop guard:** after two identical futile attempts without changed evidence, change hypothesis or mark BLOCKED. Reuse tests only for matching SHA, environment and scope. Follow [token efficiency](docs/agent-token-efficiency.md).
4. Preserve output severity and no ANSI in persistent logs. Bounded managed downloads must remain **quiet per attempt**; see [output contract](docs/18-output-colors.md).
5. Report final SHA, exact checks and evidence, gaps, risks and next step; never invent hardware acceptance. Don't silently expand a task to clean unrelated technical debt.

## Read on demand — NOT every session

| Task | Relevant reference |
| --- | --- |
| Routing, TUN, DNS, ProxyN | [ARCHITECTURE.md](ARCHITECTURE.md), [architecture guidance](docs/agent-guidance/01-architecture-and-platforms.md) |
| Install, update, rollback, watchdog, storage, VoIP | [development/safety guide](docs/agent-guidance/02-development-and-safety.md), focused docs/03–07 and docs/12 |
| Git/review/documentation | [agent/Git workflow](docs/agent-guidance/03-agent-workflow-and-git.md) |
| Portability, test strategy, parser bugs | [testing/portability](docs/agent-guidance/04-testing-and-portability.md), [testing strategy](docs/TESTING_STRATEGY.md) |
| Licensing decision | [owner policy](docs/agent-guidance/06-owner-policy-and-licensing.md) when relevant |

Historical incidents and old device lists are **archival evidence only**, not ordinary agent instructions. The [documentation index](docs/AGENT-DETAILED-REFERENCE.md) can locate them when investigating a specific old incident. Never infer today's device fleet or code state from an archive.
