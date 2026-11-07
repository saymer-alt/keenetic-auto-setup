# KAS agent guidance — topical index

The original root `AGENTS.md` (at commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6`, 2026-11-07) was moved into **six focused guides** instead of one oversized archive. The entire original policy and operational text has been carried forward; section bodies are preserved, with only Markdown links adjusted to their new relative paths. The source version remains available in Git history.

**Do not preload the whole collection.** Start with [root AGENTS.md](../AGENTS.md) and read only the document(s) relevant to the current task. [docs/CONSTITUTION.md](CONSTITUTION.md), explicit owner decisions and live exact-ref code remain authoritative for safety, permissions and the current implementation.

| Need | Focused guide | Original sections |
| --- | --- | --- |
| Scripts, architecture, hardware, resources | [Architecture and platforms](agent-guidance/01-architecture-and-platforms.md) | §§1–3 |
| Idempotency, downloads, rollback, risky code | [Development and safety](agent-guidance/02-development-and-safety.md) | §§4–5 |
| Codex/ZCode behavior, Git, docs, technical debt | [Agent workflow and Git](agent-guidance/03-agent-workflow-and-git.md) | §§6–8, §12, Technical debt |
| CI limitations, portability, parsing rules | [Testing and portability](agent-guidance/04-testing-and-portability.md) | §9 |
| Past incidents, older field evidence, pitfalls | [History and pitfalls](agent-guidance/05-history-and-pitfalls.md) | §§10–11 |
| Work-first decision, licensing constraints | [Owner policy and licensing](agent-guidance/06-owner-policy-and-licensing.md) | Intro and owner decision |

## What to treat as current

- **Binding safety:** [Constitution](CONSTITUTION.md) and [root AGENTS.md](../AGENTS.md). A terse summary cannot override a stricter established requirement.
- **Actual implementation:** exact current script/ref/SHA and focused docs (not delayed search-index excerpts).
- **Task progress:** current Issues/PRs, actual CI for the final SHA, separately labelled field evidence.
- **Historical evidence:** the history guide documents *why* earlier decisions were made, not proof that specific hardware, firmware or versions are still current.
- **Token efficiency:** do not scan all six guides as a ritual; read the relevant source once, inspect impacted dependencies, preserve crucial facts in a compact handoff.

This index is intentionally compact. It is not a second master policy and must not grow into another full `AGENTS.md`.
