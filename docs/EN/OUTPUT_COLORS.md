# Terminal output colors

Canonical visual contract for user-facing `keenetic-auto-setup` CLI output.

| Color | Status/output | Meaning |
| --- | --- | --- |
| green | `[OK]`, `[ok]`, normal `[setup]`, `[config]`, `[updater]`, `[migrate]` | normal progress or successful result |
| cyan | `[INFO]`, `[info]` | informational; no repair is implied by the line alone |
| yellow | `[WARN]` | deviation or transient problem where the operation can still continue safely |
| red | `[ERROR]`, `[FAIL]` | fatal operation error or failed mandatory check |

Color is supplemental. Textual prefixes remain the source of truth, so monochrome terminals, captured output, screenshots and support chats remain understandable.

A failed attempt is not automatically a red error. If a download transport fails but a supported fallback succeeds, the attempt stays `WARN`; red is reserved for the final condition that actually aborts an operation or fails a required diagnostic check.

ANSI is emitted only to an interactive TTY. It is disabled when output is redirected, when `NO_COLOR` is non-empty, or when `TERM=dumb`.

Persistent `mihomo-watchdog.sh` logs are always plain text. Their `[OK]`, `[WARN]`, `[INFO]`, `[RESTART]`, `[RATE-LIMIT]` and `[INIT]` markers must never contain ANSI escapes because those logs are parsed and shared.

`S00ubifs` follows the same contract while preserving its existing white/default neutral labels.

The project controls only its own status lines. Raw output from `curl`, `wget`, `opkg`, init scripts or other external programs may have different presentation and is not recolored.

New user-facing scripts must preserve textual status markers, use this green/cyan/yellow/red severity mapping, keep recoverable fallbacks non-red, honor TTY/`NO_COLOR`/`TERM=dumb`, and keep persistent logs ANSI-free.

The same rules are pinned in [AGENTS.md](../../AGENTS.md) and the contract smoke tests.
