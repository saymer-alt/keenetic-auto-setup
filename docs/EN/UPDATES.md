# Updates and maintenance

Maintenance tools share a PID/starttime lifecycle lock. Do not run old and new
tool copies concurrently; retry a busy operation after its owner finishes, without
deleting live ownership state. See the [lock and recovery protocol (RU)](../19-lifecycle-lock.md).

This is the short user-facing path for updating Mihomo, MagiTrickle and the watchdog,
plus migrating the TUN stack. Deeper implementation details remain in the
[full HOWTO](../HOWTO.md).

## Mihomo update

Supported path:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

Force reinstall of the currently available version:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh -s -- --force
```

The updater:

- detects the Entware architecture through `opkg print-architecture`;
- gets the architecture-specific Mihomo `.ipk` from `saymer-alt/entware-go:latest`;
- never selects `nohf` variants;
- never executes a second Mihomo beside a running daemon;
- completes network acquisition before planned downtime;
- stages the candidate on the destination filesystem and commits with atomic rename;
- restores the previous binary on failed post-commit verification;
- preserves the previous service state;
- never overwrites the user `config.yaml`; the updater replaces the Mihomo binary, not the user's configuration;
- never auto-downgrades.

After an update:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

When replacing `config.yaml` itself, use `config-import.sh`: it keeps the previous config as `config.yaml.bak`, validates the candidate and rolls back if startup or the contract-port check fails.

The B3/B4 development rollback first confirms daemon shutdown, copies the backup
to a stage beside the canonical binary, checks bytes, permissions and version,
and restores the binary by atomic rename. Project binary state (including prior
absence) is restored only afterwards; opkg metadata is untouched. A previously
running service is started only after both restorations, and its `/proc/<pid>/exe`
must match the restored canonical inode. INT/TERM/HUP after commit/start use this
same recovery; further signals are ignored during recovery. Failed recovery is
an ERROR with retained manual backups, never a success based on `pidof` alone.
No automatic start follows file/state restoration failure; unverifiable restored
runtime is stopped again. If stop itself fails, a process may remain running.
Backups in `/tmp` are volatile; subsequent updater runs do not sweep other runs'
recovery backups. Hardware acceptance of these changes is still pending.

## MagiTrickle update

MagiTrickle uses its normal Entware/opkg package path:

```bash
opkg update && opkg install magitrickle
/opt/etc/init.d/S99magitrickle restart
```

Check the installed package version:

```bash
opkg list-installed | grep '^magitrickle '
```

Re-running `install.sh` intentionally does not act as a hidden MagiTrickle updater.

## Watchdog update

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh
```

Canonical layout:

- full watchdog: `/opt/bin/mihomo_watchdog.sh`;
- cron wrapper: `/opt/etc/cron.5mins/mihomo_watchdog`;
- staged copy is committed by same-filesystem atomic rename;
- known managed legacy layouts are migrated automatically;
- unknown/user-modified files are preserved and reported;
- managed duplicate scheduling is normalized without deleting unrelated crontab entries.

## Legacy config: add TUN / `mitun0`

Use `migrate-mihomo-tun.sh` for old `config.yaml` files that have **no top-level `tun:` section at all**. It does not rewrite proxy/rules/DNS content and never normalizes an existing TUN block.

Read-only preview:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh -s -- --check
```

Apply:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh
```

When TUN is absent, the migrator appends the generator's normal router profile:

```yaml
tun:
  enable: true
  device: mitun0
  stack: mips        # Mihomo >= 1.19.31; otherwise gvisor
  auto-route: false
  auto-detect-interface: true
```

Stack policy:
- Mihomo **>= 1.19.31** → prefer `mips`;
- older versions → use compatibility `gvisor` and explain that MIPS needs an update;
- if the version looks eligible but the real `mihomo -t` rejects MIPS, rebuild/validate with `gvisor`;
- if the stopped binary cannot be safely probed, leave the config untouched.

The transaction preserves the one-Mihomo invariant, keeps both a per-run rollback copy and persistent `config.yaml.pre-tun`, validates before same-filesystem atomic commit, preserves prior service state, and—when the service was running—requires the process, port 7890 and real `/sys/class/net/mitun0` to become ready or rolls back automatically.

If `tun:` already exists, this migrator is a no-op. Use `migrate-mihomo-mips.sh` separately for an existing `stack: gvisor` → `stack: mips` migration.

Doctor v1.2.16 checks for a top-level `tun:` section. If it is absent, Doctor prints an INFO hint for `migrate-mihomo-tun.sh --check` and explains the version-dependent stack choice.

## MIPS TUN migration

Use `migrate-mihomo-mips.sh` only for Mihomo configs with TUN when migrating
`stack: gvisor` to `stack: mips`.

Read-only check:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-mips.sh | sh -s -- --check
```

Apply:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-mips.sh | sh
```

The script changes only `stack:` values, feature-gates support with `mihomo -t`,
preserves the one-Mihomo invariant, keeps `config.yaml.pre-mips`, rolls back on
validation/start/port failure, and is idempotent.

In the B3/B4 development version, `.pre-mips` remains the historical first-run
backup. Transaction rollback uses a separate `.config.yaml.mips-backup.<pid>`
snapshot of the current config, staged and renamed on the same filesystem with
permissions preserved. A failed candidate commit also restores this current
snapshot, never historical config. Successful completion/recovery removes the
per-run copy; failed recovery retains it and reports its path. These changes do
not promote development to `stable`.

It does **not** add a missing `tun:` block or create `mitun0` from scratch; its current scope is an existing TUN with `stack: gvisor`. Doctor v1.2.16 emits an INFO hint when that legacy stack is present and the observed Mihomo version meets the documented 1.19.31 minimum. That is only a readiness hint; the migrator's own `mihomo -t` probe remains the definitive feature gate.

## After maintenance

Run Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

If maintenance fails, follow [Troubleshooting](../08-troubleshooting.md) instead of
manually replacing binaries.

---

Updater and migrator status lines use the shared project palette: green = normal progress/OK, cyan = INFO, yellow = WARN, red = ERROR/FAIL. See [terminal output colors](OUTPUT_COLORS.md).
