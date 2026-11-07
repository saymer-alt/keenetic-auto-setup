# Testing, BusyBox and external CLI parsing

> Detailed **on-demand** guidance extracted from the previous root `AGENTS.md` at commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6`. What CI proves, live-router limitations, BusyBox compatibility and parser-specific negative regressions. Relative plain-text paths like `docs/06` are repository-root-relative. The binding entrypoint remains [AGENTS.md](../../AGENTS.md) and [KAS Constitution](../CONSTITUTION.md). These notes do not authorize relaxing safety or owner permission gates.

## 9. Testing

The project testing policy is documented in `docs/TESTING_STRATEGY.md`. Prefer real installation states and cross-component contracts, then extend the existing permanent regression harness with the smallest scenario that preserves a real failure. Heavy adversarial matrices are reserved for high-consequence invariants such as atomic replacement/rollback, locking, one-Mihomo discipline, service-state restoration, and watchdog recovery. Do not build a full KeeneticOS emulator for a narrow task.

Repository CI now provides shell syntax, contract/regression smoke tests, repository-local Markdown-link checks and whitespace checks, but it does not make a change automatically safe — do not invent results.
The committed lightweight cross-component smoke test is `sh tests/contracts.sh`; it preserves a few real installation/diagnostic contracts without emulating KeeneticOS.

### Keenetic runtime portability contract

The target is **KeeneticOS + BusyBox ash + Entware**, not a normal GNU/Linux distribution.
Linux CI hosts are useful syntax/regression runners, but the commands and options they expose are
not evidence that the router runtime exposes the same applets or GNU extensions.

- Before introducing a new runtime command or option, first prefer an already proven project primitive.
  If a new dependency is genuinely needed, either verify it on the target BusyBox/Entware environment
  or guard it with `command -v` plus a safe fallback/UNKNOWN path. Do not assume availability because
  Ubuntu, Debian, macOS, WSL, shellcheck, or CI accepts it.
- Prefer shell builtins, `/proc`, `/sys`, POSIX/basic `awk`/`sed`/`grep`, and already field-proven
  BusyBox forms. Do not replace these with shorter GNU-only one-liners.
- Known field boundary: Keenetic BusyBox 1.37 `stat` does **not** provide GNU `-c`. Runtime code must
  not use `stat -c`; use the project-proven alternatives (`ls -ldn`, `ls -ln` + sysfs major:minor,
  or `test -ef`) according to the fact being checked.
- Treat `pidof`, `ss`, `ndmq`, `timeout`, checksum applets and similar helpers as optional unless the
  installer explicitly guarantees them. A missing optional helper must not silently become proof of
  a stopped service, missing capability, or failed identity check.
- Process-unique temporary/staging names must use a real uniqueness source such as shell PID `$$`
  (or an established lifecycle-owned adjacent stage). A literal single `$` in a staging suffix is a
  bug, not an acceptable placeholder.
- If a change depends on a command-output format or BusyBox option not already covered by retained
  hardware evidence, call that out explicitly in the review and require the smallest focused live test
  before production promotion. Never describe host-CI execution as Keenetic runtime proof.
- When a real router exposes a portability failure, preserve both lessons: add the smallest permanent
  regression/static sentinel that can catch the known bad assumption, and document the runtime boundary
  here or in `docs/TESTING_STRATEGY.md`.
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

