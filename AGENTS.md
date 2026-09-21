# AGENTS.md — keenetic-auto-setup

Working instructions for AI agents (primarily ZCode): "before X, verify Y",
"do not do Z without confirmation". Items without a label are confirmed by code, docs/,
or Git history; "(proposal)" means an agent recommendation, not a repository rule.

## 1. Purpose

A POSIX-shell toolkit that turns a Keenetic router with Entware into a self-healing
VPN gateway: Mihomo (Clash Meta; VLESS/Reality) on 127.0.0.1:7890, DNS split routing
(MagiTrickle), VoIP bypass through iptables marks, tmpfs flash protection, and a watchdog.
Designed for small router fleets, including ~20 devices (docs/09). Documentation
is in Russian. This is not simply "VPN on a router", but a separation of layers
(ARCHITECTURE.md, docs/01): MagiTrickle decides where traffic goes; Mihomo is a separate
routing layer; transports are interchangeable.

## 2. Architecture

The product is the root-level scripts (there are no libraries):

| Script                    | Role |
|---------------------------|------|
| install.sh                | unified installer (architecture auto-detection: aarch64/armv7/mipsel/mips, including MT7621 — live test passed; modes `ram`\|`disk`, ram = tmpfs) |
| update-mihomo.sh          | updates the Mihomo binary from the entware-go package for all architectures: config test, automatic rollback, one-instance |
| update-watchdog.sh        | updates the watchdog copy in /opt/bin (sanity + sh -n + backup + mv) |
| mihomo-watchdog.sh        | cron every 5 min: WAN → port 7890 → socks5h tunnel → restart |
| 020-bypass-wa.sh          | netfilter.d hook: mark VoIP UDP 1400/3478/3482 → policy bypass_wa |
| S00ubifs                  | tmpfs on /opt/tmp, /opt/var/log, /opt/var/run (profiles by RAM) |
| mihomo-interface-check.sh | optional manual helper: Linux interface names for proxy-outbound `interface-name`; does not route `mitun0` |
| mihomo-proxy-selection-watch.sh     | read-only diagnostics of the current Mihomo proxy-group selection (GET /proxies only) |

Traffic flows (docs/01):
- normal: LAN → Proxy0 → Mihomo → VPN → Internet;
- VoIP (UDP): mangle MARK → policy bypass_wa → VPN directly, bypassing Mihomo;
- watchdog: cron → checks → sometimes restart S99mihomo.

The most sensitive parts — change only for an explicit task and with full understanding:
- watchdog logic: check order, lock file, jitter, cooldown, and the
  "no WAN → do not restart" rule (docs/04 explicitly asks not to touch them);
- idempotency of 020-bypass-wa.sh (the hook runs on every firewall rebuild);
- rollback chain in update-mihomo.sh and RAM gates;
- `dns-proxy intercept enable` (transit DNS interception) in both installers:
  installer-managed persistent config; before applying — grep against `show running-config`,
  `system configuration save` only when there is an actual change; this is not protection from DoH/DoT;
- A project-managed ProxyN is the Keenetic → Mihomo bridge. Its human-readable description is
  `mihomo t2sN` (N = interface number, Proxy0 → t2s0), synchronized with the t2s numbering
  in MagiTrickle; the internal Proxy0/Proxy1/… identifier must not be changed.
  On a clean router, the installer creates Proxy0; if the ID is occupied, Keenetic assigns
  the next free ProxyN — the label follows the number (in docs, Proxy0 is an example,
  not the only possible ID).
  Installers intentionally do not touch an existing Proxy0 (including its description).

## 3. Target platforms

- KeeneticOS + Entware (/opt). According to CHANGELOG, verified on KN-1810, KN-3811, KN-1913;
  updater — on ARM64 (note in the script).
- Architectures: aarch64, armv7, mipsel, mips — one install.sh for all, including
  MT7621 (live test passed); there is no separate installer anymore.
  ipk suffixes:
  aarch64-3.10 / armv7-3.2 / mipsel-3.4 / mips-3.4 (packages come from the current
  saymer-alt/entware-go release; the final fallback if the GitHub path fails is
  `opkg install mihomo` from the configured Entware feed, whose version may be older).
- Resource-profile contract `20260921_1` (live-detected from /proc/meminfo, /proc/swaps, /proc/mounts; never guessed; rationale and vendor links in docs/06): 128 MB-class remains best-effort/experimental and install.sh REFUSES it unless /opt is verified external AND external storage-backed active swap is >=384 MB (project-specific floor; zRAM never counts). 256 MB-class requires one active backend: native KeeneticOS zRAM OR verified external storage-backed swap, independent of /opt placement. Vendor guidance says not to combine zRAM with disk/file swap; Installer/Doctor/Updater warn if both are active but never change them. 512 MB+ may use internal/external /opt and does NOT require zRAM/swap; absence of swap alone is not a warning. update-mihomo.sh never blocks an existing legacy install solely for a resource-profile violation: it warns and continues while keeping all transaction safety gates. The project never creates/enables/formats/mounts/resizes swap or storage.
- MIPS/mipsel: upstream Mihomo publishes official MIPS/MIPSLE builds, and the current universal install.sh AND update-mihomo.sh both support the packaged `mipsel-3.4` / `mips-3.4` paths from saymer-alt/entware-go. Do not substitute random third-party binaries.
- Shell dialect is busybox/ash: do not use bashisms; `local` is allowed
  (busybox supports it and it is already used in the watchdog). $RANDOM, pidof, ss, netstat
  may be absent — preserve selective `command -v` checks in the code.

## 4. Development principles

Confirmed by code and docs:
- Re-running install.sh is designed to be safe: mutating steps are guarded by checks
  (pkg_ensure; `show ip policy` / `show interface Proxy0` before creation; grep before
  appending to crontab; is_mounted in S00ubifs). However, the mihomo ipk is downloaded and
  installed on every run (opkg skips the same version and installs a newer one); how an upgrade
  handles a user `/opt/etc/mihomo/config.yaml` depends on package conffiles and has not been
  verified here.
- Idempotency of 020-bypass-wa.sh is not a style preference, but a functional requirement:
  the hook is invoked on every firewall rebuild, so `-C` before `-A` and `-F` instead
  of recreating the chain are mandatory (docs/05).
- Reversibility of updates: backup in /tmp and rollback on any critical error
  (update-mihomo.sh); backup + sanity + sh -n + atomic mv (update-watchdog.sh).
- Simplicity is more important than features (docs/10): do not add a feature that
  complicates the system and raises breakage risk.
- Do not fight KeeneticOS: integration is through ndmc / RCI (localhost:79) / netfilter.d.

(proposal) expose new configurable parameters as variables at the top of the script —
like WAN_PRIMARY_TARGETS/PROXY in the watchdog; (proposal) do not expand the dependency set
beyond what is already used (curl, jq, gzip, wget, cron, ca-bundle, nano).

## 5. Security: risk zones

Delivery detail: until the separate stable delivery channel is promoted for a release,
the public one-liners and installer-managed downloads still use raw.githubusercontent.com/main,
so a commit to main can reach the next user's `curl | sh` (already installed watchdog
copies on routers do not update themselves). Minimal GitHub Actions CI now runs shell
syntax, committed contract smoke tests and whitespace checks on main and the future
stable branch. Green CI is necessary, but real-hardware acceptance still matters.

Without an explicit task and operator confirmation, do not:
- change persistent router configuration through ndmc (`system configuration save`,
  `ip policy` policies, Proxy0 interface);
- modify iptables outside the 020-bypass-wa.sh pattern: work only in table mangle and
  the custom chain _CUST_BYPASS_WA_; global `-F`/`-X` and removing `-C` checks for
  this hook are forbidden — without them, rules duplicate on every firewall rebuild;
- change the default route or DNS (resolv.conf, DoH in config.yaml) "for testing":
  a mistake in these areas can cut Internet access for the entire LAN and may close SSH access
  to the router;
- weaken resource-profile handling or config/transaction safety: install.sh hard-gates unsupported 128/256 new installs, Doctor mirrors that state read-only, update-mihomo.sh only warns for legacy profile violations but must still enforce one-Mihomo/config/architecture/free-space/atomic-commit/rollback safety; watchdog cooldown and whitelist fallback protect against restart loops;
- run network experiments on a live router without a task.

If a change in these areas is required, first understand the dependency
(§2 and the relevant doc), make the smallest change, and list verification scenarios
for the operator.

Risk-zone specifics:
- update-mihomo.sh is transactional: acquire/download/extract while the old service runs, verify destination free space, same-filesystem stage beside the canonical binary, create/verify the volatile /tmp rollback backup, controlled one-Mihomo stop, runtime/config pre-flight, then a single same-filesystem rename commit followed by verification/start. There is no rm-old-then-copy window. Change this order only with full understanding.
- watchdog: restart only when WAN is confirmed and the proxy/tunnel check fails; on total
  WAN failure the script exits without action — an intentional decision (comment in code,
  README: "WAN failure does not mean Mihomo is broken").
- S00ubifs: tmpfs data is lost on reboot — by design; on 128 MB-class devices, tmpfs
  destabilizes the system; expanding the directory list requires a RAM assessment.
- Tunnel MTU: the symptom "slow / some sites do not work" points to MTU
  (working values 1200–1300, docs/09), not routing.

## 6. AI agent working rules

- Before changing a script, read it in full and read the relevant doc: watchdog → docs/04,
  bypass_wa → docs/05, S00ubifs → docs/06, install → docs/03 and docs/07.
- Do not rewrite working architecture. Changes should be minimal diffs in the existing
  style: POSIX sh, log/warn/err functions, retry 3×, `command -v` checks.
- Do not shorten "redundant" fallback chains (jq → grep → repeated request → HTML →
  last-resort `opkg install mihomo` in install.sh; curl → wget in update-mihomo.sh):
  judging by history (dozens of iterative fixes to these files), the stages were added
  for real failures. Remove one only with an explicit task and an explanation of why
  it is no longer needed.
- Do not remove existing behavior merely to simplify it — many "strange" places have
  reasons behind them (see §10).
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

Default working rules (there is no separate repository policy; history indicates that
the owner edits main directly, with commit messages like "Update X"):
- before starting: `git status`; make sure you are on main and there are no unrelated
  uncommitted changes; do not overwrite someone else's work (reset --hard / checkout -- files
  only with explicit instruction);
- before modifying a file, inspect its history (`git log --oneline -- <file>`):
  many commits are series of small fixes to one script; the reason for the change
  matters more than the change itself;
- commit only on explicit operator instruction; the message should say what and why;
  no force-push;
- VPS notes (ubuntu*.md, debian1.md, setup_debian12*.sh, mieru.md) were moved
  to the saymer-alt/vps-gateway-bootstrap repository (docs/archaeology/) and are no longer
  part of this repository.

## 8. Documentation

- README.md (RU+EN) is the project entry point: the Russian version is primary and first,
  with the full English version below; it contains a conceptual introduction, architecture,
  use cases, ecosystem (link-generators), and Quick Start; do not duplicate details in README,
  put them in HOWTO/docs instead.
- docs/HOWTO.md and docs/HOWTO_RU.md are the complete step-by-step guide (preparation,
  installation, modes, configuration, MagiTrickle, watchdog, update, rollback,
  diagnostics, MT7621, common problems). Keep README and HOWTO aligned with each other
  and with the code.
- ARCHITECTURE.md is the main architecture document (RU): three traffic paths, roles of
  Keenetic/MagiTrickle/Mihomo, ProxyN vs mitun0, interface-name ≠ WAN, DNS architecture,
  guarantee boundaries. README links to it as the primary architecture reading.
- docs/00–10 are detailed guides;
  CHANGELOG.md contains changes (tags v1.0.0–v1.2.0).
- If documentation and code disagree, the code is the source of truth. Known case:
  docs/04-watchdog.md describes an older watchdog version (pidof check, one WAN URL,
  ~100-line rotation), while the current script uses two-stage WAN + port + socks5h
  and 500/300-line rotation.
- When script behavior changes, consider updating README and the relevant doc in the same
  change; a significant shift should get a CHANGELOG entry (the "same commit" format is
  a proposal).

## 9. Testing

The project testing policy is documented in `docs/TESTING_STRATEGY.md`. Prefer real installation states and cross-component contracts, then extend the existing permanent regression harness with the smallest scenario that preserves a real failure. Heavy adversarial matrices are reserved for high-consequence invariants such as atomic replacement/rollback, locking, one-Mihomo discipline, service-state restoration, and watchdog recovery. Do not build a full KeeneticOS emulator for a narrow task.

Repository CI now provides shell syntax, contract smoke-test and whitespace checks, but it does not make a change automatically safe — do not invent results.
The committed lightweight cross-component smoke test is `sh tests/contracts.sh`; it preserves a few real installation/diagnostic contracts without emulating KeeneticOS.
What is always available:
- `sh -n <script>` for every changed .sh (mandatory);
- review for busybox/POSIX compatibility (no bashisms or GNU-only options);
- check coupling between scripts: watchdog sanity marker, /opt/etc/cron.5mins paths
  versus /opt/bin, filenames in raw.githubusercontent links in install.sh;
- (proposal) shellcheck locally, if available — useful but not a repository requirement;
- live scenarios (installation, update, rollback, reboot, watchdog without WAN) are
  performed by the operator on the device; (proposal) not on the only production router.
The agent must clearly separate what was verified by sh -n/review from what requires
a live run.

## 10. Historical context (why it is this way)

- deploy.sh (the first installer: jsdelivr CDN, sw.ext.io mirror, interactive nano)
  was removed on 2026-09-17 by operator decision; history remains in Git. install.sh
  was created, removed, and recreated.
- install_7621.sh (removed in 2026-09; history is in Git and CHANGELOG) appeared because of
  observed TLS download failures on MT7621 (not confirmed as a platform property):
  `--insecure` + sw.ext.io HTTP mirror + fallback to pinned
  mihomo_1.19.23-1_mipsel from this repository's `mihomo` release tag. At the time,
  upstream was believed not to publish MIPS builds; upstream now publishes official
  MIPS/MIPSLE builds (at least since 1.19.31).
- The primary source of the mihomo ipk for install.sh is releases from the sibling
  saymer-alt/entware-go repository (in the workspace, ../entware-go; its CI builds and
  publishes ipk). Changing the package there changes what install.sh installs here.
- The two-stage WAN check with a whitelist (gosuslugi/ya.ru/mail.ru/vk) grew out of
  operation in restricted-access networks: the whitelist distinguishes "no Internet"
  from "only primary targets are unavailable"; complete WAN failure → no restarts.
- Jitter uses `date +%s % 25`, not RANDOM — busybox may not have $RANDOM (docs/04).
- bypass_wa uses netfilter.d instead of one-time iptables because Keenetic rebuilds the
  firewall itself; docs/05 ("learned the hard way"): run-parts is unreliable, iptables
  creates duplicates — hence `-C`/`-F`.
- The canonical watchdog is /opt/bin/mihomo_watchdog.sh. /opt/etc/cron.5mins/mihomo_watchdog
  is the managed thin wrapper that execs the canonical file. update-watchdog.sh recognizes
  known legacy layouts where the full script lived in cron.5mins, preserves a bounded
  legacy backup, and migrates them; unknown/user-modified files are preserved.
- Logs in tmpfs disappear on reboot — an intentional tradeoff to preserve flash.

## 11. Known pitfalls

- Duplicate lines in /opt/etc/crontab → watchdog runs twice (docs/08/09);
  install.sh adds an entry only if absent, but manual crontab editing can easily create
  duplicates.
- run-parts in Entware is unreliable — hence the fallback to a direct path in crontab.
- 128 MB RAM: known low-headroom risk (docs/06). New installation is allowed only as best-effort/experimental with verified external /opt + >=384 MB external storage-backed active swap (project-specific floor; zRAM does not count). 256 MB requires one active backend: zRAM OR verified external storage-backed swap. 512 MB+ does not require swap/zRAM. If zRAM and disk/file swap are both active, warn per vendor guidance; never auto-toggle either backend. Do not weaken these profile rules or try to "make it work" by silently bypassing them.
- Tunnel MTU 1500 → "everything is slow / does not work"; working values 1200–1300
  (docs/09).
- DoH: fast ≠ working; docs/08 recommendations are cloudflare-dns / dns.google / quad9.
- Incorrect system time → SSL errors → "opkg update failed"; start diagnosis with `date`.
- Re-running install.sh does not clean an existing crontab or remove old components.
- update-mihomo.sh and migrate-mihomo-mips.sh determine the binary deterministically:
  /proc/<pid>/exe of the running daemon if it points to /opt/sbin/mihomo or
  /opt/bin/mihomo, otherwise /opt/sbin/mihomo, otherwise /opt/bin/mihomo (mirrors the
  init script PATH order; nested copies such as meta-backup are not selected). The updater
  also intentionally removes old .backup/.old/.bak files next to the binary (space cleanup,
  not accidental data loss).
- The watchdog does not use `set -e`; failed checks are handled with `if` — do not add
  `set -e` without analyzing all paths.
- 020-bypass-wa.sh exits immediately when run manually ($table is empty) — this is normal.
- When run standalone, the watchdog assumes /opt/var/log exists (note in code);
  install.sh creates the directory.
- Tags: v1.x are toolkit releases; the `mihomo` tag is storage for the pinned mipsel ipk,
  not a release.

## 12. Agent working style

- Determine which components the task touches (§2), reread the risk zones (§5),
  and read the relevant doc before editing, not after.
- Any action on a live router requires an operator task.
- Until the stable delivery channel is promoted, a commit to main can still change what
  the next user's `curl | sh` executes. Minimal CI must be green, but it is not a
  substitute for focused live-router acceptance when hardware behavior matters.
- Do not claim "it works" if verification was limited to sh -n: list what was checked
  and what requires a live run on a device.
- If the task looks like "rewrite everything properly", stop and reread §4 and docs/10:
  stability matters more than elegance.

## Technical debt

- Treat technical debt as a separate engineering risk, but do not confuse it with cosmetics, personal style preferences, or merely "ugly" working code.
- For each debt item, provide evidence first and classify its impact: **High** (breakage/security/data-loss risk or blocks operation), **Medium** (impedes development, creates duplication or logic divergence, or materially increases maintenance cost), **Low** (local complexity with little current risk).
- Do not refactor for cleanliness alone. Pay down debt when the benefit and risk reduction justify the change; do not rewrite stable, verified code without a concrete reason.
- Debt fixes must keep minimal scope, preserve existing safety boundaries, and pass the project's normal regression/safety checks. If the fix creates greater risk or new debt, stop and propose a safer alternative.
- If debt is discovered outside the current task, do not silently expand scope: record the finding and recommendation, and implement it only when it is in scope or explicitly approved by the operator.
- If debt is discovered outside the current task, do not change code or documentation solely to record the finding. In the final report, state the location, brief description, evidence, **High / Medium / Low** level, risk, and recommended action. If the finding deserves separate tracking, propose creating a GitHub Issue. Create an Issue, add a `TODO`, or change files to record debt only with explicit operator permission. `TODO (TechDebt ...)` is acceptable when such a comment is within the approved scope and is genuinely needed next to the code.
