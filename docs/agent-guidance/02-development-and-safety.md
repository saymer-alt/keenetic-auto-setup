# Development principles and sensitive operations

> Detailed **on-demand** guidance extracted from the previous root `AGENTS.md` at commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6`. Idempotency, update transactions, downloads, rollback, production safety and network risk zones. Relative plain-text paths like `docs/06` are repository-root-relative. The binding entrypoint remains [AGENTS.md](../../AGENTS.md) and [KAS Constitution](../CONSTITUTION.md). These notes do not authorize relaxing safety or owner permission gates.

## 4. Development principles

Confirmed by code and docs:
- Re-running install.sh is designed to be safe: mutating steps are guarded by checks
  (pkg_ensure; `show ip policy` / `show interface Proxy0` before creation; grep before
  appending to crontab; is_mounted in S00ubifs). An already installed executable Mihomo at a
  canonical path is now left untouched by repeat install.sh runs; replacing an existing binary
  belongs exclusively to transactional `update-mihomo.sh`. install.sh only enters the Mihomo
  package-download/opkg path when no executable canonical binary exists. Mihomo service restart
  is change-aware as well: an unchanged running binary/config is not restarted; a restart is
  reserved for installer-driven binary/bootstrap changes, while a stopped service is started to
  satisfy the install contract.
- Idempotency of 020-bypass-wa.sh is not a style preference, but a functional requirement:
  the hook is invoked on every firewall rebuild, so `-C` before `-A` and `-F` instead
  of recreating the chain are mandatory (docs/05).
- Reversibility of updates: backup in /tmp and rollback on any critical error
  (update-mihomo.sh); backup + sanity + sh -n + atomic mv (update-watchdog.sh).
- Simplicity is more important than features (docs/10): do not add a feature that
  complicates the system and raises breakage risk.
- **Proof Before Build (owner decision 2026-10-26):** before implementing a new feature or major integration, first defend the need, reproduce the problem, compare alternatives including native KeeneticOS/wait/no change, evaluate technical/economic benefit, full maintenance costs, risks and measurable acceptance criteria. Follow [docs/PROOF-BEFORE-BUILD.md](../PROOF-BEFORE-BUILD.md). A one-issue short assessment suffices; a failed proof means defer/skip, not expanding scope. Existing safety contracts and routine narrowly scoped bug fixes are not waived.
- User-facing terminal status colors are a project contract, not decoration. Follow
  [docs/18-output-colors.md](../18-output-colors.md): normal progress and OK are green,
  INFO is cyan, WARN is yellow, ERROR/FAIL are red. Textual prefixes remain mandatory;
  color must never be the only carrier of severity. Emit ANSI only to an interactive TTY,
  honor `NO_COLOR` and `TERM=dumb`, and keep redirected/captured output plain.
  Persistent logs (especially `mihomo-watchdog.sh`) must never contain ANSI escapes.
  Recoverable retries/fallbacks stay WARN even if an underlying command failed; red is
  reserved for a final fatal operation or a failed diagnostic/check. Bounded managed
  download retries must be quiet per attempt: suppress repeated curl/wget stderr and
  per-attempt status spam, then emit at most one project status line when a transport
  is exhausted before moving to the next fallback. Do not weaken the retry count or
  remove the fallback chain merely to make output shorter.
- Do not fight KeeneticOS: integration is through ndmc / RCI (localhost:79) / netfilter.d.

(proposal) expose new configurable parameters as variables at the top of the script —
like WAN_PRIMARY_TARGETS/PROXY in the watchdog; (proposal) do not expand the dependency set
beyond what is already used (curl, jq, gzip, wget, cron, ca-bundle, nano).

## 5. Security: risk zones

Delivery detail: `main` is the development branch and `stable` is the production
delivery branch. Production project fetches default to `stable`; development/testing may
override the project ref explicitly. Remote delivery is a reliability contract learned from
a real `raw.githubusercontent.com` reset during installation:
- project-managed script acquisition must use bounded fallbacks where applicable:
  raw GitHub via bounded normal `curl` → one bounded `curl --curves X25519` compatibility retry → the same raw URL via `wget` → GitHub Contents API raw media;
- failed file transfers must remove partial/non-empty candidates before the next transport;
- do not reuse the short metadata/script total timeout for package assets. Live KN-1010 acceptance on 2026-09-28 showed that the ~12.8 MB mipsel IPK can exceed a 20 s total transfer window even when the path is otherwise healthy. Metadata/project scripts keep the short bounded window; large asset downloads in installer/updater use a separate 180 s bounded transfer window while retaining the 5 s connect/TLS gate and IPv4+X25519 compatibility retry;
- shell candidates must be staged before execution, be non-empty, start with `#!/bin/sh`,
  and pass `sh -n`; destination replacement remains atomic where a managed file is installed;
- **Owner decision, 2026-10-22 (KAS #180):** public fresh-install UX is a short, familiar HTTPS `curl | sh` command for the initial `bootstrap.sh`, explicitly accepting a less strict first-hop trust/error-propagation model than #165. Do not silently revert that decision to an opaque `sh -c`/mktemp command in normal README/Quick Start. The copyable public command uses `curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh` after `opkg update && opkg install curl` (explicit owner choice, 2026-10-22). `-fSsL` hides the progress indicator but shows HTTP/network errors on stderr; it does not add an overall 25-second transfer timeout. TLS/CA validation remains mandatory (no HTTP, no `--insecure`). Do not silently re-add connect/transfer timeout flags to the user-facing quick command; the internal installer downloaders retain their own bounded retries.
- **Documented accepted risk:** POSIX pipeline status normally follows `sh` rather than `curl`; an empty/failed first response may leave a 0 pipeline exit and a partial or altered first-stage shell stream is not prevalidated. Never call the short command equivalent to staged first-fetch or tamper-proof. Explain this briefly at the user-facing entry point. The `bootstrap.sh` stage itself remains responsible for securely staging and validating `setup.sh` before execution, with raw → IPv4/X25519 → GitHub Contents API fallbacks. `setup.sh` and `install.sh` safety invariants, including KAS-SAFETY-001, remain unchanged.
- **Advanced first-fetch stays available** in `docs/03-install.md`: private staging, shebang/project-marker/`sh -n` checks, three-path first-fetch fallback, bounded timeouts, TLS/CA. This provides a stronger operator choice without burdening the default command.
- RU/EN README and onboarding guides must show the same quick command; regression tests must exercise the *actual documented string* with mocked network/OPKG and separately exercise advanced full first-fetch. Do not edit tests to claim the short pipe has the same guarantees as the advanced staged path. If first raw fetch fails, recommend the advanced first-fetch or offline/SCP path.
- a caller-provided custom source URL remains authoritative: do not silently replace a failed
  override with a different project payload.
External package sources that do not have a project Contents-API equivalent still need the
strongest available existing fallback (for example curl → wget, GitHub API → HTML/feed).
Minimal GitHub Actions CI runs shell syntax, committed contract/regression smoke tests,
local Markdown-link validation and whitespace checks on both branches. Promotion is
`main → stable` only after green CI and focused acceptance; release tags are placed on the
exact production commit. Green CI is necessary, but real-hardware acceptance still matters.

Without an explicit task and operator confirmation, do not:
- change persistent router configuration through ndmc (`system configuration save`,
  `ip policy` policies, Proxy0 interface);
- modify iptables outside the 020-bypass-wa.sh pattern: work only in table mangle and
  the custom chain _CUST_BYPASS_WA_; global `-F`/`-X` and removing `-C` checks for
  this hook are forbidden — without them, rules duplicate on every firewall rebuild;
- change the default route or DNS (resolv.conf, DoH in config.yaml) "for testing":
  a mistake in these areas can cut Internet access for the entire LAN and may close SSH access
  to the router;
- weaken storage/resource-profile handling or config/transaction safety: external Entware `/opt` is EXT4-only for new installs and requires `ext` + `ext-utils`; install.sh hard-gates the unsupported 128 MB prerequisite failures, a missing zRAM/external-swap backend on the 512 MB-class, and external swap above 2 GiB; 256 MB missing-backend remains WARN-only. Doctor mirrors those severities read-only, while update-mihomo.sh rejects dual zRAM/external SWAP and only warns for other legacy profile violations, but must still enforce one-Mihomo/config/architecture/free-space/atomic-commit/rollback safety; watchdog cooldown and whitelist fallback protect against restart loops;
- run network experiments on a live router without a task.

If a change in these areas is required, first understand the dependency
([architecture and platform contracts](01-architecture-and-platforms.md) and the relevant component doc), make the smallest change, and list verification scenarios
for the operator.

Risk-zone specifics:
- Watchdog installer/updater share the existing lifecycle lock and identical managed-file helpers. Successful managed executables require root:root/0755; legacy backups remain 0600 outside cron. Normalize only recognized active five-minute routes; preserve unknown schedules for manual review. Correct repeat runs preserve managed content/inode/mtime.
- Absence of `pidof` is not evidence that Mihomo is stopped. The identical standalone `mp_state` contract returns 0 running / 1 stopped / 2 unknown, with executable-identity `/proc` fallback. Safety-critical stop/probe/commit/start decisions fail closed on unknown; lifecycle ownership is still required. The B4 canonical inode verifier remains a separate, stricter check.
- Native zRAM is identified by actual zram block-device identity, not substring matching in swap source names. All three scanners share `swap_is_zram`: active partition, numeric zramN device name, block-device metadata and matching sysfs major/minor. Missing/conflicting evidence is unverified. Resource thresholds are unchanged.
- MIPS migration rollback must use the current run's config snapshot, never the historical `.pre-mips` artifact. Restore through a same-filesystem stage/rename with permissions preserved; retain the snapshot on recovery failure.
- Binary rollback stays under the shared lifecycle lock: confirmed stop → verified same-filesystem rollback stage → atomic binary rename → project-state restore → optional previous-service start and canonical executable-inode verification. Failure in recovery must remain an ERROR with manual backups retained; never report success merely because `pidof` finds a process. INT/TERM/HUP are already handled; repeated signals during recovery must not re-enter it.
- update-mihomo.sh is transactional: acquire/download/extract while the old service runs, verify destination free space, same-filesystem stage beside the canonical binary, create/verify the volatile /tmp rollback backup, controlled one-Mihomo stop, runtime/config pre-flight, then a single same-filesystem rename commit followed by verification/start. There is no rm-old-then-copy window. Change this order only with full understanding.
- watchdog: restart only when WAN is confirmed and the proxy/tunnel check fails; on total
  WAN failure the script exits without action — an intentional decision (comment in code,
  README: "WAN failure does not mean Mihomo is broken").
- S00ubifs: tmpfs data is lost on reboot — by design; on 128 MB-class devices, tmpfs
  destabilizes the system; expanding the directory list requires a RAM assessment.
- Tunnel MTU: "slow / some sites do not work" can be a path-MTU symptom. Do not treat 1200–1300 as a universal default: 1200 is a live-working anchor for the documented nested Keenetic WARP-over-ProxyN/Mihomo topology. Distinguish the Keenetic WireGuard/WARP MTU from Mihomo `tun.mtu` (`mitun0`); see docs/09 and encyclopedia/34.


## Current operational pitfalls (verified against scripts on PR #433 base; not historical inventory)

These are **active implementation guardrails**, separated from the incident chronology in [the history archive](../archaeology/kas-agent-historical-context-2026.md). Before changing behavior, re-check the exact target SHA; old field models, firmware and dates are evidence, not current configuration.

- **Watchdog error handling:** `mihomo-watchdog.sh` intentionally does not use blanket `set -e`; many probe failures are handled by `if`/explicit status logic. Do not add `set -e` without tracing all failure/cleanup/restart paths. The watchdog's managed five-minute cron wrapper and lifecycle lock must remain consistent with `update-watchdog.sh`. Duplicate managed cron routes must be prevented; unknown/user-managed schedules remain untouched unless explicitly authorized.
- **Mihomo executable identity:** `update-mihomo.sh` and `migrate-mihomo-mips.sh` prefer a positively identified running `/proc/<pid>/exe` at canonical `/opt/sbin/mihomo` or `/opt/bin/mihomo`; when the canonical running executable cannot be established, fallback search prefers executable `/opt/sbin/mihomo`, then `/opt/bin/mihomo`. Do not select nested backup copies or infer daemon identity solely from `pidof`; preserve one-Mihomo/process-state safety gates.
- **Netfilter hook invocation:** current `020-bypass-wa.sh` requires both `type=iptables` and `table=mangle` before modifying rules. Manual execution without those netfilter.d values is intentionally a no-op. Historical descriptions that mention only `$table` are incomplete; inspect the live hook before changing it.
- **External dependency and platform evidence:** a CI Ubuntu command, a past KN/NC model test, or a historical `run-parts` observation is not universal proof for every KeeneticOS/Entware environment. For targeted changes use [testing/portability requirements](04-testing-and-portability.md) and verify the current device or report NOT_TESTED.
- **Release/source-of-truth:** for current published behavior consult exact refs/tags and current `README.md`/scripts, not old pinned-binary or uninstall notes in the archived pitfalls section. Keep historical records as explanations, not executable instructions.
