# Agent workflow, Git and documentation rules

> Detailed **on-demand** guidance extracted from the previous root `AGENTS.md` at commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6`. Task planning, proof and source accuracy, branch governance, handoffs, documentation and technical debt. Relative plain-text paths like `docs/06` are repository-root-relative. The binding entrypoint remains [AGENTS.md](../../AGENTS.md) and [KAS Constitution](../CONSTITUTION.md). These notes do not authorize relaxing safety or owner permission gates.

## 6. AI agent working rules

**MANDATORY — KAS-AGENT-001 / anti-monkey-paw task contract (owner decision, 2026-10-30).**
**Общая политика для всех репозиториев:** [saymer-alt/AGENT-TASK-CONTRACT.md](https://github.com/saymer-alt/saymer-alt/blob/main/AGENT-TASK-CONTRACT.md) (обязательна наряду с более строгим локальным KAS-AGENT-001).
Before drafting **or executing** a task for Z AI/ZCode/Codex/other agents, first apply the **mandatory compact KAS-AGENT-001 task gate** already present in [root AGENTS.md](../../AGENTS.md) and consult the applicable binding sections of [KAS Constitution](../CONSTITUTION.md). The complete local [docs/AGENT-TASK-CONTRACT.md](../AGENT-TASK-CONTRACT.md) is **preserved and binding**, not discarded: for routine narrow, demonstrably low-risk work use its applicable clauses as needed; for complex, security-sensitive, multi-project, destructive, release, deployment, live-router or ambiguous changes read the full contract and template before acting. This scoped-reading rule changes the *amount preloaded*, **not** the operator's intent, constraints, permissions, negative acceptance or evidence requirements. A technically literal but harmful outcome is FAIL even if all formal steps were completed. Any task affecting repository history, releases, IPKs, updater, running services, network or owner settings must be written with sufficient technical detail: human-visible goal, exact baseline SHA, existing work, scope/non-goals, protected state, dependencies, owner GO, negative cases, tests and Definition of Done. Do not infer destructive permissions from vague verbs such as "cleanup", "merge" or "release". For material ambiguity stop the risky action and continue safe authorized work. In final reports distinguish planned, implemented, CI-verified, field-tested, merged and published.

**Token efficiency practices (owner decision, 05.11.2026, issue #420):** agents additionally follow [docs/agent-token-efficiency.md](../agent-token-efficiency.md) — loop guard after two identical futile attempts, evidence reuse only for compatible SHA/environment/scope, environment facts with source/date/applicability, addressed tool calls, build economy, short evidence-navigating reports. These rules never justify weakening mandatory tests, release gates or safety contracts.


- **Source reading: risk before volume.** Start with the exact ref/SHA, affected function/block, callers, shared state and focused test located via the [component reading map](07-component-reading-map.md). A proven local wording/presentation/read-only helper fix may use bounded source reads; inspect consumers and negative tests before editing. Do not indiscriminately read full scripts or whole documentation trees.
- **Full read is still mandatory before safety-critical edits.** Read every **affected** install/update/import/migration, watchdog restart, locking/rollback, RAM/SWAP/storage, process-identity or persistent routing/DNS/firewall/ProxyN script **in full at the exact SHA once**; also read cross-script dependencies and their relevant contracts. Treat Doctor severity/prerequisite parsing and any unclear cross-component effects as high-risk. Examples: watchdog → docs/04; bypass_wa → docs/05; S00ubifs → docs/06; install → docs/03 and docs/07. If a local change crosses its proven boundary, escalate before editing; never trim safeguards or mandatory verification to save tokens.
- Repository search/index results are discovery aids, not proof of current branch state. Before asserting current content, editing, or comparing evidence, fetch the exact file/blob from the intended branch/ref and verify its SHA; search indexing may lag behind recent commits.
- Do not rewrite working architecture. Changes should be minimal diffs in the existing
  style: POSIX sh, log/warn/err functions, retry 3×, `command -v` checks.
- Do not shorten "redundant" fallback chains (jq → grep → repeated request → HTML →
  last-resort `opkg install mihomo` in install.sh; curl → wget in update-mihomo.sh):
  judging by history (dozens of iterative fixes to these files), the stages were added
  for real failures. Remove one only with an explicit task and an explanation of why
  it is no longer needed.
- Do not remove existing behavior merely to simplify it — many "strange" places have
  reasons behind them (consult [historical incidents](../archaeology/kas-agent-historical-context-2026.md) only if investigating that behavior).
- "`sh -n` passed" ≠ "it works": syntax is the first filter, not proof.
- Explicitly list which scenarios a change affects: installation (ram/disk), repeated
  install.sh run, update-mihomo (success and rollback), update-watchdog, reboot, watchdog
  behavior when WAN is unavailable. Live verification is performed by the operator
  on the device.
- Available checks after changes: sh -n on every changed .sh; if changing
  mihomo-watchdog.sh, preserve the sanity marker "MIHOMO WATCHDOG SCRIPT" (update-watchdog.sh
  depends on it); if changing log volume, account for 500/300-line rotation.
- When in doubt, stop and ask the operator. Missing information is not permission.

## 7. Working with Git

Default working rules:
- `main` is development; `stable` is production delivery. **Base work on an exact `main` ref and implement changes in a separate topic branch**; require
  green CI, promote through a `main → stable` pull request, and verify CI on the promoted
  commit. After a successful promotion, if `main` has not received newer development
  commits and `stable` is a descendant with the same promoted tree, fast-forward `main`
  to the `stable` merge commit (no force) so branch history is synchronized and GitHub
  does not advertise a misleading reverse `stable → main` PR. Then tag/release that exact
  production commit;
- before starting: `git status`; verify `main` baseline, your topic branch/HEAD and unrelated
  uncommitted changes; do not overwrite someone else's work (reset --hard / checkout -- files
  only with explicit instruction);
- inspect **relevant** file/function history for nontrivial or surprising logic (e.g. `git log -n 10 --oneline -- <file>`, targeted blame); preserve the reasons behind critical safeguards. Do not load an entire file's history merely to correct a harmless typo;
- commit only on explicit operator instruction; the message should say what and why;
  no force-push;
- VPS notes (ubuntu*.md, debian1.md, setup_debian12*.sh, mieru.md) were moved
  to the saymer-alt/vps-gateway-bootstrap repository (docs/archaeology/) and are no longer
  part of this repository.

## Issue → PR lifecycle

**Source of truth:** Issue описывает пользовательскую проблему, условия воспроизведения и критерии завершения; PR содержит конкретный diff, доказательства и риск. Использовать уже открытые Issue/PR, не создавать дубликаты. Для небольшой автономной правки (например, опечатка) допустим PR без Issue с кратким объяснением; не раздувать backlog формальностями.

1. **Issue:** записать ожидаемое/фактическое поведение, окружение, scope и отрицательные сценарии. Для полевых инцидентов явно указать условие закрытия (`FIELD PASS` на проверяемой модели/версии) и обезличивать логи. Issue не даёт разрешения на merge, release или доступ к устройству.
2. **Topic branch / PR:** исходить из проверенного SHA, сослаться на Issue и заполнить существующий PR template. `Refs #N` — обычный безопасный вариант при незавершённой аппаратной приёмке, backport, релизе или других оставшихся условиях. `Fixes #N` / `Closes #N` — только если намеренно допустимо автоматическое закрытие полностью решённой Issue при merge в default branch GitHub.
3. **Proof:** отдельно сообщить `IMPLEMENTED`, `CI PASS`, `EMULATOR PASS`, `FIELD PASS`, `MERGED`, `PUBLISHED` (либо `NOT TESTED`/`N/A`); ссылки на run и source SHA. `CI PASS` и merge **не равны** проверке на Keenetic. Для docs-only PR достаточно проверки ссылок/шаблона и релевантных лёгких тестов; не запускать тяжёлый QEMU без необходимости.
4. **Merge:** только после ревью/CI и отдельного owner GO; `main` — dev, `stable` — production с собственными gate. Не включать auto-merge и не публиковать релиз из принятия Issue/PR.
5. **Closure:** Issue закрывать только когда соблюдены **её** критерии готовности. Если merge состоялся, а FIELD/релиз/другой этап ещё не подтверждён, оставить Issue открытой и добавить PR/CI/field evidence и следующий шаг. Допускается несколько PR на одну Issue и один PR на несколько связанных Issue при осознанном небольшом scope.

Ключевое исключение: если PR исправляет саму программу, но проверка на физическом Keenetic ещё впереди, **не ставить `Fixes #N` для преждевременного автозакрытия**. Использовать `Refs #N`, а Issue закрывать вручную после FIELD PASS или явно документированного изменения критериев владельцем.

## 8. Documentation

- README.md is the concise Russian project entry point; `docs/EN/README.md` is its synchronized English counterpart. Keep both task-oriented and move detailed behavior to HOWTO/docs instead of duplicating long explanations in the entry pages.
- **README brevity decision (2026-10-22):** the RU and EN READMEs are copy/paste-oriented landing pages, not long HOWTOs. Preserve the nine Common commands and the exact copyable stable installer *in both Common commands and Installation*, plus concise prerequisites, critical zRAM/SWAP and 512-MB gates, first-run config import and links to detailed guides. Target <=8000 characters for each README (enforced by `tests/bootstrap-readme-regression.py`). Do not restate curl transport details, retries, TLS internals, or long safety reasoning in the Common commands block; use `docs/03-install.md` and `docs/14-setup.md` instead. The full script inventories live in `docs/SCRIPTS.md` and `docs/EN/SCRIPTS.md` rather than repeated in landing pages.
- docs/HOWTO.md and docs/HOWTO_RU.md are the complete step-by-step guide (preparation,
  installation, modes, configuration, MagiTrickle, watchdog, update, rollback,
  diagnostics, MT7621, common problems). Keep README and HOWTO aligned with each other
  and with the code.
- ARCHITECTURE.md is the main architecture document (RU): three traffic paths, roles of
  Keenetic/MagiTrickle/Mihomo, ProxyN vs mitun0, interface-name ≠ WAN, DNS architecture,
  guarantee boundaries. README links to it as the primary architecture reading.
- numbered docs are focused guides; `docs/12-updates.md` and `docs/EN/UPDATES.md` are the user-facing maintenance guides. `CHANGELOG.md` records release history and current unreleased work.
- If documentation and code disagree, the code is the source of truth. The watchdog guide
  (`docs/04-watchdog.md`) is expected to track the current two-stage WAN + port + socks5h
  logic, 20-minute healthy heartbeat, mkdir lock and 500/300-line rotation; do not preserve
  stale "known difference" notes when the guide has already been updated.
- When script behavior changes, consider updating README and the relevant doc in the same
  change; a significant shift should get a CHANGELOG entry (the "same commit" format is
  a proposal).

- **Ownership journal phase (issue #179, 2026-10-22):** journal-on-install is a separate deliverable from uninstall. Only a proven freshly created/enabled resource is recorded in `/opt/etc/keenetic-auto-setup/ownership.v1` after verification; an old compatible ProxyN, preexisting DNS intercept, reused `magitrickle` package/repository or policy MUST NOT be retrospectively claimed. Writes are atomic under the lifecycle lock; invalid/symlinked log means fail closed. The journal is evidence, never sufficient authorization to remove anything. Keep `uninstall.sh --remove/--purge` out of production until independently tested (lab KN-1010 acceptance) and user-approved. Keep README concise and point to `docs/24-ownership-ledger.md` when detailed provenance is needed.

## 12. Agent working style

- Determine which components the task touches (use the [component reading map](07-component-reading-map.md) and [architecture/platforms](01-architecture-and-platforms.md)); read applicable [safety-sensitive sections](02-development-and-safety.md) and the task's focused documentation **before** editing, not the entire docs tree.
- Any action on a live router requires an operator task.
- A commit to `main` is development only. Production one-liners use `stable`.
  Do not move `stable` casually: CI must be green and focused live-router acceptance
  still matters when hardware behavior is involved.
- Do not claim "it works" if verification was limited to sh -n: list what was checked
  and what requires a live run on a device.
- If the task looks like "rewrite everything properly", stop and reread the [development principles](02-development-and-safety.md) and docs/10:
  stability matters more than elegance.

## Technical debt

- Treat technical debt as a separate engineering risk, but do not confuse it with cosmetics, personal style preferences, or merely "ugly" working code.
- For each debt item, provide evidence first and classify its impact: **High** (breakage/security/data-loss risk or blocks operation), **Medium** (impedes development, creates duplication or logic divergence, or materially increases maintenance cost), **Low** (local complexity with little current risk).
- Do not refactor for cleanliness alone. Pay down debt when the benefit and risk reduction justify the change; do not rewrite stable, verified code without a concrete reason.
- Debt fixes must keep minimal scope, preserve existing safety boundaries, and pass the project's normal regression/safety checks. If the fix creates greater risk or new debt, stop and propose a safer alternative.
- If debt is discovered outside the current task, do not silently expand scope: record the finding and recommendation, and implement it only when it is in scope or explicitly approved by the operator.
- If debt is discovered outside the current task, do not change code or documentation solely to record the finding. In the final report, state the location, brief description, evidence, **High / Medium / Low** level, risk, and recommended action. If the finding deserves separate tracking, propose creating a GitHub Issue. Create an Issue, add a `TODO`, or change files to record debt only with explicit operator permission. `TODO (TechDebt ...)` is acceptable when such a comment is within the approved scope and is genuinely needed next to the code.
