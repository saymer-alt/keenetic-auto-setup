# KAS documentation map for agents

Only the essential [root AGENTS.md](../AGENTS.md) is loaded at startup. All files below are **optional, demand-driven** context, not mandatory pre-reading. Binding safety policy: [CONSTITUTION.md](CONSTITUTION.md). Current code and exact refs always supersede historical examples about implementation state.

## Active guidance (by current task)

| Task | Reference |
| --- | --- |
| Locate relevant code, callers and focused tests **without dumping whole scripts** | [Component reading map — risk-tiered](agent-guidance/07-component-reading-map.md) |
| Architecture and current platform contracts | [Architecture/platforms](agent-guidance/01-architecture-and-platforms.md) |
| Installer, updater, watchdog and safety-sensitive code | [Development/safety](agent-guidance/02-development-and-safety.md) |
| Git/PR workflow, documentation, technical debt | [Agent workflow](agent-guidance/03-agent-workflow-and-git.md) |
| BusyBox, testing, CI-versus-field evidence | [Testing/portability](agent-guidance/04-testing-and-portability.md) |
| Owner licence decision when applicable | [Owner policy/licensing](agent-guidance/06-owner-policy-and-licensing.md) |

## Archival evidence — not agent onboarding

- [Historical KAS incidents and past pitfalls](archaeology/kas-agent-historical-context-2026.md): old runtime observations, **not current instructions**.
- [Historical router model/field inventory](archaeology/kas-platform-field-inventory-2026.md): field examples from old `AGENTS.md` that must **never** be assumed to describe current equipment.

Original sections from the 2026-11-07 base `AGENTS.md` commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6` are preserved between the active topical guides and these two archives.

For findings, implementation status and **future recommendations not to auto-execute**, see [Agent context audit — 2026-11-07](agent-guidance/AGENT-CONTEXT-AUDIT-2026-11-07.md). The archive is for relevant historical investigations only; do not auto-read it or paste it into normal coding prompts.
