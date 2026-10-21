# setup.sh — simple installation wizard

The normal KAS installation command starts **`bootstrap.sh`**, not `setup.sh` directly. The latter is the next-stage wizard automatically invoked by the launcher.

It does not replace `install.sh`. It classifies the real `/opt` storage, selects the normal profile, delegates all safety gates to the canonical installer, then starts safe Mihomo config import.

## Why bootstrap.sh exists

`bootstrap.sh` is a small first-stage loader for networks where GitHub raw fetches can fail. It does **not** install Mihomo or MagiTrickle, and does not change KeeneticOS settings. It downloads `setup.sh` over GitHub raw, retries through IPv4/X25519 and GitHub Contents API if needed, checks that the file is non-empty, has a `#!/bin/sh` header and expected project markers, passes `sh -n`, then runs it and propagates its exit status.

Full sequence: `bootstrap.sh` → `setup.sh` (select `ram`/`disk`) → `install.sh` (installation and safety gates) → `config-import.sh` (on success, with interactive input available).

The initial HTTPS **bootstrap.sh** itself is piped directly to `sh` by the short public command; this stream is not prevalidated. A [staged and validated alternative](../03-install.md#расширенная-установка-с-проверкой-первой-загрузки) is available for failed initial fetches or stricter first-hop validation.

## Run

```bash
opkg update && opkg install curl && curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh
```

## Flow

1. Verify OPKG and curl.
2. Classify the actual `/opt` mount.
3. Select `ram` for internal Keenetic storage or `disk` for external persistent storage.
4. Download `install.sh` from the same project ref using a bounded delivery chain: raw GitHub via `curl` → raw GitHub via `wget` → GitHub Contents API.
5. Require every downloaded script candidate to be non-empty, start with `#!/bin/sh`, and pass `sh -n`.
6. Run the canonical installer.
7. Download and start `config-import.sh` through the same resilient chain when an interactive TTY is available.
8. Print the Doctor command.

The short command streams the first `bootstrap.sh` over HTTPS to `sh`, using `curl -fSsL`: errors remain visible, progress is suppressed, and no extra overall timeout is specified for this initial request. This is an explicitly accepted first-fetch risk (no staging/validation of the initial stream). Once running, `bootstrap.sh` downloads `setup.sh` via raw → IPv4/X25519 → Contents API and validates it before execution. The staged three-path first-fetch option and offline/SCP alternative remain in the [advanced installation guide](../03-install.md#расширенная-установка-с-проверкой-первой-загрузки). TLS certificate checks are not disabled.

The wrapper never bypasses installer contracts for components, RAM/swap, EXT4, ProxyN, DNS interception, or other safety checks.

If storage cannot be classified safely, it stops instead of guessing. Use the [advanced installation guide](../03-install.md) for unusual layouts.

## Config import

After successful installation the wizard continues into safe config import. Paste the full generated YAML and press Ctrl+D once. Type `s` to skip.

Details: [safe config import](CONFIG_IMPORT.md).

## Web interfaces

MagiTrickle is available after installation. MetaCubeXD becomes available after importing a full generated `config.yaml` that configures `external-controller`.

```text
MetaCubeXD:   http://192.168.1.1:9090/ui/
MagiTrickle:  http://192.168.1.1:8080/
```

If Config Import is skipped with `s`, the minimal bootstrap keeps only `mixed-port: 7890`, so port 9090 is not expected.

Replace the address when your Keenetic uses another LAN IP. For the first MetaCubeXD open after full config import, use the base `/ui/` path.

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

---

`setup.sh` and the canonical installer use the same project-wide traffic-light status palette. TTY, `NO_COLOR`, redirect and persistent-log rules are documented in [terminal output colors](OUTPUT_COLORS.md).
