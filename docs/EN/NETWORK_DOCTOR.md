# Network Doctor: staged diagnosis for one target

`kas-network-doctor.sh` is a standalone staged network diagnostic (issues [#158](https://github.com/saymer-alt/keenetic-auto-setup/issues/158), [#166](https://github.com/saymer-alt/keenetic-auto-setup/issues/166), [#266](https://github.com/saymer-alt/keenetic-auto-setup/issues/266), [#270](https://github.com/saymer-alt/keenetic-auto-setup/issues/270)). Unlike the regular local Doctor, this tool **performs network probes** - and only when the user explicitly runs it. For one target it walks the delivery chain **DNS -> TCP -> TLS -> HTTP**, then reports the observed egress address, the local Mihomo path (port 7890, read-only Controller lookups, SOCKS5h probe) and read-only MagiTrickle/Keenetic ProxyN evidence.

The regular `mihomo-doctor.sh` stays local and offline-safe: it still performs no external probes. `mihomo-route-check.sh` continues to work as the narrow single-site check.

## What the tool does and does not do

- Changes nothing: DNS, routes, firewall, interfaces, ProxyN, policies, Mihomo, MagiTrickle and configuration are untouched; certificate verification is never disabled.
- Request budget: **<= 12 small requests** per run (DNS queries count), each bounded by `--connect-timeout 6` / 15 s timeout / `--max-filesize 256 KiB`. The counter is printed in the report and JSON.
- The `MIHOMO_API_SECRET` is **never printed**; the selected proxy-server name is withheld ("selected leaf (name withheld)") so reports are safe to attach. curl arguments in the request log are sanitized: the Authorization header appears as `[authorization header]`.
- No cause is declared confirmed: the verdict names only the confirmed failing stage; everything else is labeled H: (hypothesis) and N: (next step). A router-side success does not prove a LAN client path - `client.vantage` stays `NOT TESTED`.
- UDP transport beyond the implicit resolver exercise is `UNSUPPORTED` (honest, no fabricated PASS).

## Running

```sh
sh kas-network-doctor.sh --target example.com
sh kas-network-doctor.sh --target https://example.com/path
sh kas-network-doctor.sh --target 192.0.2.10 --port 80       # plain HTTP
sh kas-network-doctor.sh --target example.com --dns-server 1.1.1.1
sh kas-network-doctor.sh --target example.com --json /opt/tmp/net-report.json
sh kas-network-doctor.sh --target example.com --report /opt/tmp/net-report.txt --brief
MIHOMO_PROXY_GROUP='GLOBAL' MIHOMO_API_SECRET='...' sh kas-network-doctor.sh --target example.com
sh kas-network-doctor.sh --target example.com --no-egress    # skip the egress observation
```

Statuses: `PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED`. Exit codes: `0` chain confirmed (DNS+TCP+TLS answered, HTTP answered with any status); `1` confirmed stage failure; `2` usage error; `3` inconclusive (nothing FAILed, but the chain never completed).

## Stages and stable check ids

| Check id | What it shows |
| --- | --- |
| `tools.curl` | curl availability (without it most stages are `UNSUPPORTED`, verdict inconclusive) |
| `dns.router` | system-resolver lookup with explicit NXDOMAIN / SERVFAIL / REFUSED / timeout classification; `NOT TESTED` for IP targets |
| `dns.custom` | the same name via `--dns-server`; disagreement with `dns.router` is printed as a fact |
| `tcp.connect` | TCP to host:port via the curl telnet trick; `curl 7` refused/unreachable; `curl 56` on telnet means the connection was established (peer closed the probe) |
| `tls.handshake` | TLS handshake with verification enabled: `curl 35` (handshake), `60/19` (certificate: clock/CA), `43` (malformed), `56` (mid-handshake reset -> UNKNOWN) |
| `http.response` | HTTP status after bounded redirect handling, final URL; 4xx/5xx = "transport healthy, application answered" (a fact, not a network failure) |
| `egress.direct` | observed direct egress address (api.ipify.org, one tiny request); disable with `--no-egress` |
| `mihomo.socks-port` | whether the local port 7890 is listening (netstat/ss) |
| `mihomo.controller` | Controller reachability (GET /version; 401/403 = secret not accepted) |
| `mihomo.controller.selection` | whether the group has a selected leaf (GET /proxies + jq; name withheld) |
| `mihomo.socks-probe` | whether HTTP reaches the target through the local SOCKS5h path; the printed limitation: this does not classify any LAN client |
| `egress.via-mihomo` | egress address through the Mihomo path; the comparison with `egress.direct` is a fact (same/different) |
| `magitrickle.process` | magitrickled process running (pgrep/pidof, read-only) |
| `keenetic.proxyn` | ProxyN bridge to 127.0.0.1:7890 in running-config (ndmc, read-only, filtered) |
| `udp.transport` | always `UNSUPPORTED` - no reliable UDP probe with verified semantics on BusyBox/Entware |
| `client.vantage` | always `NOT TESTED` - router-side observations; client paths need client-side evidence |

## Interpretation

- Facts are printed separately from hypotheses: the "Hypotheses" section starts with an explicit "NOT confirmed causes" label. Typical hypotheses: NXDOMAIN (name error/interception), curl 35 (known docs/03 field case - X25519/IPv6 path; DPI is one hypothesis among several), 60/19 (device clock or `ca-bundle`), mid-TLS cut (DPI/MTU/server, undiagnosed), captive-portal redirect (final URL on a private address), 4xx/5xx (service side).
- Stage consistency is printed as a "consistency: ..." line (e.g., DNS answered, TCP refused -> later failures are expected).

## JSON contract for KAS Web beta.4

`--json FILE` writes `network-diagnostics/v1` in plain POSIX sh (jq is not required for writing or reading): schema, tool version, UTC time, exit code, verdict (summary/first_failed_stage/hypotheses/next_steps), target, vantage (`router`), budget (timeouts, limits, counters), egress observations, status counts and a `checks` array with stable `id`/`status`/`detail`/`observed` fields. All statuses come from the fixed vocabulary. The Doctor 1.2.18/1.2.19 parser (doctor-report.js) is untouched.

## Testing and evidence boundaries

- `tests/network-doctor-regression.py` - offline regression: mock curl/nslookup/ndmc/netstat/jq/pgrep injected via PATH, ~36 behavioral cases per shell (dash-compatible sh and BusyBox ash): NXDOMAIN/SERVFAIL/REFUSED/timeout, TCP refused/reset/timeout, TLS 35/60/56/28, HTTP 200/403/500/redirect, captive portal, resolver disagreement, missing curl, unreachable Controller, disabled egress, positive Mihomo/ProxyN/MagiTrickle paths, exact request counts, JSON validity on happy and failure paths, PATH isolation, "the secret never appears in any output".
- Executed on host sh and BusyBox ash 1.37: **MOCK PASS on both dialects**. This proves the logic, not a field result.
- **QEMU: NOT RUN** (the router-emulator lab (#208) was not engaged in this work), **PHYSICAL: NOT TESTED** - the first hardware check requires a separate owner GO.
