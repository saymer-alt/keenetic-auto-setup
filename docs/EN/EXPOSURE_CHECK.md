# KAS local exposure audit (read-only)

`kas-exposure-check.sh` is a standalone read-only utility ([#159](https://github.com/saymer-alt/keenetic-auto-setup/issues/159)) for analysing which TCP ports the router actually listens on and how they are bound. It changes nothing and scans no foreign networks — only the router's own sockets and its own configuration.

## Owner contract (#159, 2026-11-01)

A Mihomo Controller **without a password and with open accessibility** is an accepted KAS architectural decision. The audit records facts and never treats as a violation: an open binding, `allow-lan`, a missing/empty/YAML-null `secret`, or an HTTP 200 answer to an unauthenticated request. The only `FAIL` is a **contradiction** between the declared (config) and the observed (probe) authentication state. The tool changes nothing and never demands a password.

## What is checked

The tool keeps three distinct concepts apart:

1. **A socket listens on an address** — a fact from `/proc/net/tcp` and `/proc/net/tcp6` (primary source — works even without `ss`/`netstat`): port, family, bind class.
   - loopback (`127.0.0.1`, `::1`) → PASS;
   - wildcard (`0.0.0.0`, `::`) → INFO fact "listens on all interfaces; external reachability depends on firewall/NAT and is NOT verified here" — **not** counted as a vulnerability;
   - a specific address → UNKNOWN (reachability from other routed subnets is not excluded).
2. **A local unauthenticated request is answered** — a live unauthenticated `GET /version` probe (localhost vantage only):
   - 200 → CONFIRMED (a confirmed fact; with declared DISABLED this is the expected contract behavior);
   - 401/403 → REJECTED (authentication enforced);
   - down/error → UNKNOWN.
3. **The API is actually reachable from outside** — **not checked** by this tool (firewall/NAT is not parsed); the verdict always states `NOT verified`.

Additionally: the **Mihomo config** (`mixed-port`/`port`/`socks-port`, `allow-lan` — INFO "by design", `bind-address`, `external-controller` — loopback → PASS, otherwise an INFO fact per the contract); the **declared authentication state** `Controller authentication: ENABLED / DISABLED / UNKNOWN` — from the `secret:` line: an empty value, an unquoted `null`/`~` or empty quotes = DISABLED, any non-empty quoted string (including `"null"`) = ENABLED, an unbalanced quote = UNKNOWN; the secret value is intentionally never printed. **ProxyN evidence** from `show running-config` — filtered safe lines only.

## Key limitations (stated in the tool's verdict)

- **LISTENING ≠ reachable, and a localhost answer does not prove external access.** Keenetic firewall/NAT rules are not parsed; the tool expresses no opinion about WAN reachability (NOT verified).
- A Keenetic may serve home/dacha/work/VPN subnets: binding to `br0` does not protect clients of other routed networks — no universally "correct" bind is assumed.
- UDP listeners are not audited (different `/proc/net/udp` state semantics).
- Missing sources (no config, no ndmc, no curl) yield `NOT TESTED`/`UNKNOWN`, not guesses; with no socket evidence at all the verdict is `inconclusive` (exit 3), not "clean".

## Running

```sh
sh kas-exposure-check.sh
```

Statuses: `PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED`; `[INFO]` lines are observed facts. Exit codes: `0` — facts collected, declared vs observed authentication consistent; `1` — a contradiction (e.g. a `secret` is configured but the API answers HTTP 200 without Authorization); `2` — usage error; `3` — no socket evidence available at all (inconclusive).

Environment overrides (tests / special layouts): `KAS_EXPOSURE_PROC_ROOT`, `KAS_EXPOSURE_CONFIG`, `KAS_EXPOSURE_CONTROLLER_URL`.

## Tests

`tests/exposure-check-regression.py` — synthetic `/proc` and config fixtures: loopback-only, wildcard IPv4/IPv6 (facts, exit 0), a specific address (including the little-endian `/proc` byte order), `allow-lan`/open `external-controller` as INFO, a full `secret:` matrix (bare colon, `null`, `~`, `""`, `''`, quoted `"null"`/`'null'`, a value with a trailing comment, `#` inside quotes, an unbalanced quote), declared-vs-observed consistency (ENABLED+401, DISABLED+200 — exit 0; ENABLED+200, DISABLED+401 — contradiction, exit 1), Controller down, 5xx, all sources missing (exit 3), usage error. The suite also asserts the secret value never appears in the output.

## Evidence limits

The regression proves the logic on fixtures; a real-hardware run (which ports Entware/Mihomo/the panel actually listen on, and what `show running-config` looks like on 5.1.x) belongs to the owner. The tool does not check Keenetic firewall rules and does not recommend configuration changes.
