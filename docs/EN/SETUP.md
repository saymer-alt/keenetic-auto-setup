# setup.sh — simple installation wizard

`setup.sh` is the recommended entry point for a normal installation on Keenetic + Entware.

It does not replace `install.sh`. It classifies the real `/opt` storage, selects the normal profile, delegates all safety gates to the canonical installer, then starts safe Mihomo config import.

## Run

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

## Flow

1. Verify OPKG and curl.
2. Classify the actual `/opt` mount.
3. Select `ram` for internal Keenetic storage or `disk` for external persistent storage.
4. Download and syntax-check `install.sh`.
5. Run the canonical installer.
6. Download and start `config-import.sh` when an interactive TTY is available.
7. Print the Doctor command.

The wrapper never bypasses installer contracts for components, RAM/swap, EXT4, ProxyN, DNS interception, or other safety checks.

If storage cannot be classified safely, it stops instead of guessing. Use the [advanced installation guide](../03-install.md) for unusual layouts.

## Config import

After successful installation the wizard continues into safe config import. Paste the full generated YAML and press Ctrl+D once. Type `s` to skip.

Details: [safe config import](CONFIG_IMPORT.md).

## Web interfaces

```text
MetaCubeXD:   http://192.168.1.1:9090/ui/
MagiTrickle:  http://192.168.1.1:8080/
```

Replace the address when your Keenetic uses another LAN IP. For the first MetaCubeXD open, use the base `/ui/` path.

## Re-running

Repeat installation is designed to be safe. An already installed unchanged Mihomo should not be needlessly replaced or restarted, and the installer does not overwrite the user's `config.yaml`.

## When to use install.sh directly

Use the advanced path when you need explicit `ram|disk`, a documented storage override, offline/SCP delivery, or a non-standard storage layout.

## After installation

Run Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

For one-domain/IP diagnostics see [mihomo-route-check.sh](ROUTE_CHECK.md).
