# KAS local exposure audit (read-only)

`kas-exposure-check.sh` is a standalone read-only utility ([#159](https://github.com/saymer-alt/keenetic-auto-setup/issues/159)) for analysing which TCP ports the router actually listens on and how they are bound. It changes nothing and scans no foreign networks — only the router's own sockets and its own configuration.

## What is checked

- **Actual listening sockets** from `/proc/net/tcp` and `/proc/net/tcp6` (primary source — works even without `ss`/`netstat`): port, family, bind class.
  - loopback (`127.0.0.1`, `::1`) → PASS;
  - wildcard (`0.0.0.0`, `::`) → FAIL finding "risk, depends on firewall/NAT";
  - a specific address → UNKNOWN (reachability from other routed subnets is not excluded).
- **Mihomo config** (`/opt/etc/mihomo/config.yaml`): `mixed-port`/`port`/`socks-port`, `allow-lan`, `bind-address`, `external-controller` (loopback → PASS, otherwise FAIL).
- **Controller secret**: only the **fact of presence** is classified (SET / empty / missing); the secret value is intentionally never printed.
- **Live Controller probe**: unauthenticated `GET /version` — 401/403 = authentication enforced (PASS), 200 = passwordless API (FAIL).
- **ProxyN evidence** from `show running-config` — filtered safe lines only; a full config dump is deliberately never printed.

## Key limitations (stated in the tool's verdict)

- **LISTENING ≠ reachable.** Keenetic firewall/NAT rules are not parsed; the tool expresses no opinion about WAN reachability (NOT TESTED).
- A Keenetic may serve home/dacha/work/VPN subnets: binding to `br0` does not protect clients of other routed networks — no universally "correct" bind is assumed.
- UDP listeners are not audited (different `/proc/net/udp` state semantics) — an honest v0.1.0 limitation.
- Missing sources (no config, no ndmc, no curl) yield `NOT TESTED`/`UNKNOWN`, not guesses; with no socket evidence at all the verdict is `inconclusive` (exit 3), not "clean".

## Running

```sh
sh kas-exposure-check.sh
```

Statuses: `PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED`. Exit codes: `0` — no unauthenticated non-loopback wildcard listener found; `1` — risky findings exist; `2` — usage error; `3` — no socket evidence available at all (inconclusive).

Environment overrides (tests / special layouts): `KAS_EXPOSURE_PROC_ROOT`, `KAS_EXPOSURE_CONFIG`, `KAS_EXPOSURE_CONTROLLER_URL`.

## Tests

`tests/exposure-check-regression.py` — synthetic `/proc` and config fixtures: loopback-only, wildcard IPv4/IPv6, a specific address (including the little-endian `/proc` byte order), enabled `allow-lan`, a non-loopback `external-controller`, secret SET/empty/missing, Controller 401/200/down, missing ndmc, all sources missing (exit 3), usage error. The suite also asserts the secret value never appears in the output.

## Evidence limits

The regression proves the logic on fixtures; a real KN-1010 run (which ports Entware/Mihomo/the panel actually listen on, and what `show running-config` looks like on 5.1.x) belongs to the owner. The tool does not check Keenetic firewall rules and does not recommend configuration changes.
