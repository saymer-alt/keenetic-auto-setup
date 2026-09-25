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
| setup.sh                  | simple front-end: classifies `/opt` as internal/external, selects the normal `ram`/`disk` profile, then delegates all mutations and safety gates to `install.sh` |
| install.sh                | unified installer (architecture auto-detection: aarch64/armv7/mipsel/mips, including MT7621 — live test passed; modes `ram`\|`disk`, ram = tmpfs) |
| config-import.sh          | safe config transaction: TTY/file candidate → contract check → one-Mihomo validation → persistent previous-config backup → atomic config commit → runtime verification/rollback |
| update-mihomo.sh          | updates the Mihomo binary from the entware-go package for all architectures: config test, automatic rollback, one-instance |
| update-watchdog.sh        | updates/migrates the canonical watchdog using validation + same-filesystem staging + atomic rename |
| mihomo-watchdog.sh        | cron every 5 min: WAN → port 7890 → socks5h tunnel → restart |
| 020-bypass-wa.sh          | netfilter.d hook: mark VoIP UDP 1400/3478/3482 → policy bypass_wa |
| S00ubifs                  | tmpfs on /opt/tmp, /opt/var/log, /opt/var/run (profiles by RAM) |
| mihomo-interface-check.sh | optional manual helper: Linux interface names for proxy-outbound `interface-name`; does not route `mitun0` |
| mihomo-proxy-selection-watch.sh     | read-only diagnostics of the current Mihomo proxy-group selection (GET /proxies only) |
| mihomo-route-check.sh                | focused read-only diagnostic for one domain/IP: DNS, project ProxyN evidence, local 7890, current Controller selection and SOCKS5h target probe; never claims client-policy classification |

Traffic flows (docs/01):
- normal: LAN → Proxy0 → Mihomo → VPN → Internet;
- VoIP (UDP): mangle MARK → policy bypass_wa → VPN directly, bypassing Mihomo;
- watchdog: cron → checks → sometimes restart S99mihomo.

The most sensitive parts — change only for an explicit task and with full understanding:
- watchdog logic: check order, lock file, jitter, cooldown, and the
  "no WAN → do not restart" rule (docs/04 explicitly asks not to touch them);
- idempotency of 020-bypass-wa.sh (the hook runs on every firewall rebuild);
- rollback chain in update-mihomo.sh and RAM gates;
- config-import.sh transaction: never validate by launching a second Mihomo beside the daemon; keep the maintenance marker, previous-config backup, same-filesystem atomic commit, runtime verification and rollback ordering intact;
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

- KeeneticOS + Entware (/opt). Direct retained release acceptance covers **KN-1010 (MT7621AT / mipsel)** plus **KN-1012, KN-3811, KN-3812 and the operator's home Netcraze Ultra NC-1812 (AArch64 / ARM64)**. NC-1812 and Keenetic Titan KN-1812 are different market models built on the same MT7988D-class hardware platform; never relabel evidence from one model as a physical test of the other. Preserve the exact `model` / `hw_id` reported by the tested router. Official references still establish the architecture family: KN-1010 uses the mipsel archive; KN-1012/3811/3812 use MT7981B AArch64; NC-1812/KN-1812 are MT7988D-class AArch64. Earlier field use also includes other Keenetic models; hardware tests complement, not replace, CI.
- Architectures: aarch64, armv7, mipsel, mips — one install.sh for all, including
  MT7621 (live test passed); there is no separate installer anymore.
  ipk suffixes:
  aarch64-3.10 / armv7-3.2 / mipsel-3.4 / mips-3.4 (packages come from the current
  saymer-alt/entware-go release; the final fallback if the GitHub path fails is
  `opkg install mihomo` from the configured Entware feed, whose version may be older).
- Secure-DNS component contract: because the supported traffic path always uses KeeneticOS Proxy Client / ProxyN, new installs require **at least one** of `dns-tls` (DNS-over-TLS proxy) or `dns-https` (DNS-over-HTTPS proxy). This is an OR requirement, not AND: Keenetic's Proxy Client guide warns proxy Internet access may be unreliable without DoT/DoH and recommends enabling either DoT or DoH. The project does not auto-select a resolver; whitelist-network reachability remains operator-specific.
- External-storage contract: if Entware `/opt` is on external persistent storage, new installs support **EXT4 only**. `install.sh` reads the actual deepest `/opt` mount from `/proc/mounts`; external non-EXT4 is a hard preflight error. External `/opt` additionally requires KeeneticOS component ids `ext` and `ext-utils` from `show version`. Internal UBIFS installs are not subject to these two storage-component requirements. Doctor mirrors violations as FAIL; update-mihomo.sh only warns for an already-existing legacy non-EXT4 install and continues servicing it. The project never formats, converts or repairs storage automatically. `ext-utils` is required for the platform filesystem check/repair tooling; do not claim automatic fsck on every boot without separate evidence.
- Resource-profile contract `20260921_3` (live-detected from /proc/meminfo, /proc/swaps, /proc/mounts; never guessed; rationale and vendor links in docs/06): 128 MB-class remains best-effort/experimental and install.sh REFUSES it unless /opt is verified external AND external storage-backed active swap is >=384 MB (project-specific floor; zRAM never counts). 256 MB-class and 512 MB-class are expected to have one active backend: native KeeneticOS zRAM OR verified external storage-backed swap; absence is WARN and does not block installation. When external swap is chosen on 256/512 MB-class, 1x detected RAM is the project warning floor: below 1x is WARN, while 1x..3x is informational only. The preferred sizing target remains 3x detected RAM capped at 2 GiB; external swap above 2 GiB is an install ERROR / Doctor FAIL. The 1x floor and 3x target are project policy, not vendor minimums. Vendor guidance says not to combine zRAM with disk/file swap; Installer/Doctor/Updater warn if both are active but never change them. Above the 512 MB-class, swap/zRAM is optional. update-mihomo.sh never blocks an existing legacy install solely for a resource-profile violation: it warns and continues while keeping all transaction safety gates. The project never creates/enables/formats/mounts/resizes swap or storage.
- MIPS/mipsel: upstream Mihomo publishes official MIPS/MIPSLE builds, and the current universal install.sh AND update-mihomo.sh both support the packaged `mipsel-3.4` / `mips-3.4` paths from saymer-alt/entware-go. Do not substitute random third-party binaries.
- Shell dialect is busybox/ash: do not use bashisms; `local` is allowed
  (busybox supports it and it is already used in the watchdog). $RANDOM, pidof, ss, netstat
  may be absent — preserve selective `command -v` checks in the code.

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
- Do not fight KeeneticOS: integration is through ndmc / RCI (localhost:79) / netfilter.d.

(proposal) expose new configurable parameters as variables at the top of the script —
like WAN_PRIMARY_TARGETS/PROXY in the watchdog; (proposal) do not expand the dependency set
beyond what is already used (curl, jq, gzip, wget, cron, ca-bundle, nano).

## 5. Security: risk zones

Delivery detail: `main` is the development branch and `stable` is the production
delivery branch. Public one-liners and installer-managed project downloads use
`raw.githubusercontent.com/.../stable/...` by default; development/testing may override
the project ref explicitly. Minimal GitHub Actions CI runs shell syntax, committed contract/
regression smoke tests, local Markdown-link validation and whitespace checks on both branches. Promotion is `main → stable` only
after green CI and focused acceptance; release tags are placed on the exact production
commit. Green CI is necessary, but real-hardware acceptance still matters.

Without an explicit task and operator confirmation, do not:
- change persistent router configuration through ndmc (`system configuration save`,
  `ip policy` policies, Proxy0 interface);
- modify iptables outside the 020-bypass-wa.sh pattern: work only in table mangle and
  the custom chain _CUST_BYPASS_WA_; global `-F`/`-X` and removing `-C` checks for
  this hook are forbidden — without them, rules duplicate on every firewall rebuild;
- change the default route or DNS (resolv.conf, DoH in config.yaml) "for testing":
  a mistake in these areas can cut Internet access for the entire LAN and may close SSH access
  to the router;
- weaken storage/resource-profile handling or config/transaction safety: external Entware `/opt` is EXT4-only for new installs and requires `ext` + `ext-utils`; install.sh hard-gates the unsupported 128 MB prerequisite failures and external swap above 2 GiB; on 256/512 MB-class devices a missing zRAM/external-swap backend is WARN-only by contract. Doctor mirrors those severities read-only, while update-mihomo.sh only warns for legacy profile violations but must still enforce one-Mihomo/config/architecture/free-space/atomic-commit/rollback safety; watchdog cooldown and whitelist fallback protect against restart loops;
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
- Tunnel MTU: "slow / some sites do not work" can be a path-MTU symptom. Do not treat 1200–1300 as a universal default: 1200 is a live-working anchor for the documented nested Keenetic WARP-over-ProxyN/Mihomo topology. Distinguish the Keenetic WireGuard/WARP MTU from Mihomo `tun.mtu` (`mitun0`); see docs/09 and encyclopedia/34.

## 6. AI agent working rules

- Before changing a script, read it in full and read the relevant doc: watchdog → docs/04,
  bypass_wa → docs/05, S00ubifs → docs/06, install → docs/03 and docs/07.
- Repository search/index results are discovery aids, not proof of current branch state. Before asserting current content, editing, or comparing evidence, fetch the exact file/blob from the intended branch/ref and verify its SHA; search indexing may lag behind recent commits.
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

Default working rules:
- `main` is development; `stable` is production delivery. Develop on `main`, require
  green CI, promote through a `main → stable` pull request, and verify CI on the promoted
  commit. After a successful promotion, if `main` has not received newer development
  commits and `stable` is a descendant with the same promoted tree, fast-forward `main`
  to the `stable` merge commit (no force) so branch history is synchronized and GitHub
  does not advertise a misleading reverse `stable → main` PR. Then tag/release that exact
  production commit;
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

- README.md is the concise Russian project entry point; `docs/EN/README.md` is its synchronized English counterpart. Keep both task-oriented and move detailed behavior to HOWTO/docs instead of duplicating long explanations in the entry pages.
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

## 9. Testing

The project testing policy is documented in `docs/TESTING_STRATEGY.md`. Prefer real installation states and cross-component contracts, then extend the existing permanent regression harness with the smallest scenario that preserves a real failure. Heavy adversarial matrices are reserved for high-consequence invariants such as atomic replacement/rollback, locking, one-Mihomo discipline, service-state restoration, and watchdog recovery. Do not build a full KeeneticOS emulator for a narrow task.

Repository CI now provides shell syntax, contract/regression smoke tests, repository-local Markdown-link checks and whitespace checks, but it does not make a change automatically safe — do not invent results.
The committed lightweight cross-component smoke test is `sh tests/contracts.sh`; it preserves a few real installation/diagnostic contracts without emulating KeeneticOS.

### Parsing external command output

Treat every parsed Keenetic/Entware command as an **external input protocol**. A visually convenient CLI sample is not automatically a stable machine format.

- Prefer structured RCI/JSON when the same fact is available there and using it does not create a worse dependency.
- Human-readable/display output may wrap logical values across physical lines. The proven example is `ndmc -c "show version"`: its `components:` value can split one component ID inside the token.
- Configuration streams such as `show running-config` are different: physical lines are commands/block structure. **Never apply global newline removal or generic line joining to running-config.**
- Normalize only a field whose continuation grammar is understood. Stop at the next field/block boundary; do not concatenate the whole command output.
- After normalization, match IDs/tokens exactly. Prefix/substrings are unsafe: `opkg-kmod-netfilter-addons` must never satisfy `opkg-kmod-netfilter`.
- If output is empty, truncated or cannot be positively identified, classify it as UNKNOWN/UNVERIFIED rather than silently turning it into NOT_FOUND.
- Read back critical persistent mutations from a fresh observation. A command returning success is not proof that KeeneticOS accepted/applied it.
- When several scripts independently interpret the same producer output, a regression must exercise every parser implementation so they cannot drift silently.
- Every real formatting/integration failure should leave the smallest permanent regression using a sanitized fixture that preserves the **shape** of the real output. Do not publish private router configuration or secrets.
- Synthetic tests prove only modeled shapes. A green CI run is not evidence that every firmware/model prints the same human-readable representation.

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

- 2026-09-19 the operator's **NC-1812 / KeeneticOS 5.1.5** already showed the same `show version` presentation class: a component ID could be split across adjacent physical lines (for example `ike-` / `client`). That observation was treated as harmless display wrapping and no parser regression was created. This was an early warning we failed to promote into a general rule.
- 2026-09-25 KN-3811 before/after 5.1.5 -> 5.1.6 made the consequence explicit: `ndmc -c "show version"` hard-wrapped required IDs (`dns-` / `filter`, `opkg-kmod-` / `netfilter`), so line-oriented matching produced false missing-component evidence. Never test required component IDs line-by-line against the raw dump. Normalize only the understood `components:` continuation field, then exact-match comma-delimited IDs. This applies to both Doctor and installer; `opkg-kmod-netfilter-addons` must never satisfy `opkg-kmod-netfilter`. The permanent regression now splits every required component ID at every possible internal position.
- Do **not** generalize the `show version` fix into a universal "join wrapped lines" helper. `show running-config` uses line boundaries as configuration semantics; joining those lines can merge unrelated commands/blocks and create false ownership/state conclusions. Parser behavior must be defined per producer/output type, not by appearance alone.
- Evidence naming is part of correctness: NC-1812 and KN-1812 are different market models on the same hardware platform. A successful run on NC-1812 is valuable MT7988D/AArch64 evidence, but it must stay recorded as NC-1812 unless KN-1812 itself was actually tested.
- 2026-09-25 field A/B/C on KN-1010 / KeeneticOS 5.1.6 proved why
  `opkg-kmod-netfilter` is a hard project prerequisite: with the component present,
  `xt_multiport` and the UDP multiport MARK/CONNMARK/RETURN rules exist; after removing
  Netfilter modules and rebooting, Entware iptables and the bypass policy/chain survived
  but `xt_multiport` disappeared and `_CUST_BYPASS_WA_` was empty; restoring only
  `opkg-kmod-netfilter` (Xtables-addons still disabled) restored the module and rules.
  Do not replace this with a chain-exists-only check; runtime health requires the actual
  ruleset.

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
- External Entware storage: supported new-install profile is EXT4 only. NTFS/exFAT/FAT or an unverified external `/opt` must not be silently accepted; external `/opt` requires `ext` + `ext-utils`. Do not make installer formatting/repair automatic.
- 128 MB RAM: known low-headroom risk (docs/06). New installation is allowed only as best-effort/experimental with verified external /opt + >=384 MB external storage-backed active swap (project-specific floor; zRAM does not count). 256 MB and 512 MB-class devices should have zRAM OR verified external storage-backed swap; missing both is WARN. External swap below 1x detected RAM is WARN; 1x..3x is INFO with 3x as the preferred target, capped at 2 GiB; >2 GiB is invalid for new installs. Above the 512 MB-class, swap/zRAM is optional. If zRAM and disk/file swap are both active, warn per vendor guidance; never auto-toggle either backend. Do not weaken these profile rules or try to "make it work" by silently bypassing them.
- Nested-tunnel MTU is topology-specific. In the documented Keenetic WARP-over-ProxyN/Mihomo chain, MTU 1200 is live-working; 1200–1300 is only a troubleshooting range, not a universal default. Do not confuse the router WireGuard MTU with Mihomo `tun.mtu` (docs/09, encyclopedia/34).
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
- A commit to `main` is development only. Production one-liners use `stable`.
  Do not move `stable` casually: CI must be green and focused live-router acceptance
  still matters when hardware behavior is involved.
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
