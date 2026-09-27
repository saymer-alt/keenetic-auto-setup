# setup.sh — simple installation wizard

`setup.sh` is the recommended entry point for a normal installation on Keenetic + Entware.

It does not replace `install.sh`. It classifies the real `/opt` storage, selects the normal profile, delegates all safety gates to the canonical installer, then starts safe Mihomo config import.

## Run

```sh
SCRIPT=setup.sh
TMP="/tmp/keenetic-auto-setup-${SCRIPT}.$$"
RAW="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/${SCRIPT}"
API="https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents/${SCRIPT}?ref=stable"

opkg update && opkg install curl && \
rm -f "$TMP" && \
( curl -fSsL "$RAW" -o "$TMP" || \
  { rm -f "$TMP"; wget -qO "$TMP" "$RAW"; } || \
  { rm -f "$TMP"; curl -fSsL \
      -H "Accept: application/vnd.github.raw+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$API" -o "$TMP"; } ) && \
[ -s "$TMP" ] && \
[ "$(head -n 1 "$TMP" 2>/dev/null)" = "#!/bin/sh" ] && \
sh -n "$TMP" && \
sh "$TMP"
RC=$?
rm -f "$TMP"
[ "$RC" -eq 0 ]
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

The first bootstrap no longer depends on one `raw.githubusercontent.com`/`curl` path. The command above tries raw through `curl`, then the same raw URL through `wget`, then the GitHub Contents API. Partial files are removed between transports, and the candidate must be a non-empty `#!/bin/sh` script that passes `sh -n` before execution. Once `setup.sh` starts, the same resilient-delivery model continues inside the project for child files.

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
