# Historical incidents and known pitfalls

> **ARCHIVAL ONLY** material extracted from the previous root `AGENTS.md` at commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6`. Historical evidence from past firmware, routers and scripts; NOT a statement about current HEAD or current hardware. Relative plain-text paths like `docs/06` are repository-root-relative. This archive is not part of routine agent onboarding. The binding entrypoint remains [AGENTS.md](../../AGENTS.md) and [KAS Constitution](../CONSTITUTION.md). Historical evidence is never proof of current source SHA, equipment or firmware. These notes do not authorize relaxing safety or owner permission gates.

## 10. Historical context (why it is this way)

- 2026-09-28 live NC-1812 C2/C3 acceptance exposed a platform boundary hidden by CI: built-in BusyBox 1.37.0 `stat` accepts only `-l/-t`, not GNU `-c`. Router runtime paths must not depend on `stat -c`. Managed-file owner/mode checks use `ls -ldn`; B4 exact executable identity uses `test -ef`; zRAM device identity uses `ls -ln` plus sysfs major:minor. Keep this pinned by regressions because Linux CI hosts normally provide GNU coreutils.
- 2026-09-28 pre-release review found a second host-CI blind spot: `MAGITRICKLE_REPO_STAGE` had regressed to a literal `magitrickle-add-repo.$` path. It was syntactically valid and ordinary CI did not object, but concurrent installer runs would share one stage path. Staging-path uniqueness is therefore a runtime contract: use real `$$`/lifecycle-owned unique names and pin exact managed staging forms in contracts.
- 2026-09-28 live NC-1812 evidence isolated a TLS bootstrap compatibility failure before Doctor execution: Entware `curl 8.15.0 + OpenSSL 3.5.5` sent a default TLS 1.3 ClientHello of about 1578 bytes to `raw.githubusercontent.com` and received no ServerHello; `--curves X25519` reduced it to about 512 bytes and completed TLS/HTTP2 immediately. OpenSSL 3.5 changed default keyshares toward hybrid PQC groups, but the project does not claim OpenSSL itself is universally broken: treat this as a path/middlebox/MTU compatibility case. Normal TLS stays first; the compatibility fallback is explicitly IPv4 + X25519 (`-4 --curves X25519`), never `--insecure`. Current field evidence proves that combination; it does not prove that either IPv4 forcing or X25519 alone is universally sufficient.

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

- Duplicate lines in /opt/etc/crontab → watchdog runs twice (docs/08/09).
  Installer/updater normalize recognized five-minute routes; unknown custom routes
  require manual review.
- run-parts in Entware is unreliable — hence the fallback to a direct path in crontab.
- External Entware storage: supported new-install profile is EXT4 only. NTFS/exFAT/FAT or an unverified external `/opt` must not be silently accepted; external `/opt` requires `ext` + `ext-utils`. Do not make installer formatting/repair automatic.
- 128 MB RAM: known low-headroom risk (docs/06). New installation is allowed only as best-effort/experimental with verified external /opt + >=384 MB external storage-backed active swap (project-specific floor; zRAM does not count). 256 MB-class devices should have zRAM OR verified external storage-backed swap; missing both remains WARN. **512 MB-class is explicitly unsupported without one active backend:** native zRAM OR verified external storage-backed swap is mandatory, missing both is installer ERROR / Doctor FAIL, with no AP/extender or low-memory override. External swap below 1x detected RAM is WARN; 1x..3x is INFO with 3x as the preferred target, capped at 2 GiB; >2 GiB is invalid for new installs. Above the 512 MB-class, swap/zRAM is optional under the current contract. If zRAM and disk/file swap are both active, reject new installations, report Doctor FAIL, but reject existing-install updates before mutation; never auto-toggle either backend. Do not weaken these profile rules or try to "make it work" by silently bypassing them.
- Nested-tunnel MTU is topology-specific. In the documented Keenetic WARP-over-ProxyN/Mihomo chain, MTU 1200 is live-working; 1200–1300 is only a troubleshooting range, not a universal default. Do not confuse the router WireGuard MTU with Mihomo `tun.mtu` (docs/09, encyclopedia/34).
- DoH: fast ≠ working; docs/08 recommendations are cloudflare-dns / dns.google / quad9.
- Incorrect system time → SSL errors → "opkg update failed"; start diagnosis with `date`.
- Re-running install.sh normalizes managed watchdog cron routes, but does not remove unrelated old components.
- update-mihomo.sh, migrate-mihomo-mips.sh and migrate-mihomo-tun.sh determine the binary deterministically:
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

