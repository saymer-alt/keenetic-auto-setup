# Updates and maintenance

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

## After maintenance

Run Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

If maintenance fails, follow [Troubleshooting](../08-troubleshooting.md) instead of
manually replacing binaries.
