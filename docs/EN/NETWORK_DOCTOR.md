# Network Doctor: staged diagnosis for one target

`kas-network-doctor.sh` is a standalone staged network diagnostic (issues [#158](https://github.com/saymer-alt/keenetic-auto-setup/issues/158), [#166](https://github.com/saymer-alt/keenetic-auto-setup/issues/166), [#266](https://github.com/saymer-alt/keenetic-auto-setup/issues/266), [#270](https://github.com/saymer-alt/keenetic-auto-setup/issues/270)). Unlike the regular local Doctor, this tool **performs network probes** - and only when the user explicitly runs it. For one target it walks the delivery chain **DNS -> TCP -> TLS -> HTTP**, then reports the observed egress address, the local Mihomo path (port 7890, read-only Controller lookups, SOCKS5h probe) and read-only MagiTrickle/Keenetic ProxyN evidence.

The regular `mihomo-doctor.sh` stays local and offline-safe: it still performs no external probes. `mihomo-route-check.sh` continues to work as the narrow single-site check.

## What the tool does and does not do

- Changes nothing: DNS, routes, firewall, interfaces, ProxyN, policies, Mihomo, MagiTrickle and configuration are untouched; certificate verification is never disabled.
- Request budget: **<= 12 small requests** per run (DNS queries count), each bounded by `--connect-timeout 6` / 15 s timeout / `--max-filesize 256 KiB`. The counter is printed in the report and JSON.
- The `MIHOMO_API_SECRET` is **never printed**; the selected proxy-server name is withheld; raw running-config lines are withheld (a filtered evidence summary is printed instead). curl arguments in the request log are sanitized (Authorization -> `[authorization header]`); URLs in the report and JSON are redacted: userinfo -> `[credentials withheld]`, query/fragment -> `[query withheld]`. Direct probes run with `--noproxy '*'`, so `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` from the environment cannot distort the direct-path claims (socks probes use the explicit `--socks5-hostname`). DNS probes are limited to 6 s via `timeout` when available (otherwise the missing limit is stated). The Controller `/proxies` response is capped with `--max-filesize`.
- No cause is declared confirmed: the verdict names only the confirmed failing stage; everything else is labeled H: (hypothesis) and N: (next step). A router-side success does not prove a LAN client path - `client.vantage` stays `NOT TESTED`.
- UDP transport beyond the implicit resolver exercise is `UNSUPPORTED` (honest, no fabricated PASS).
- A DNS probe runs only when a `timeout` utility exists (6 s limit); without it the stage is honestly `NOT TESTED` - an unbounded wait on a slow router is impossible.

## Quick start on a new router from `stable`

You need SSH access to Keenetic/Netcraze, working Entware (`/opt`, `opkg`), Internet access, and `curl`. If `curl` is missing, install **only this utility** first: `opkg update && opkg install curl`. KAS Web is not required; absent Mihomo/MagiTrickle/ProxyN components are reported as untested or unsupported rather than preventing the tool from starting.

Download the reviewed `stable` script into temporary `/tmp`, check shell syntax, then probe a target (replace `example.com` with your domain):

```sh
curl -fSsL --retry 2 --max-time 60 -o /tmp/kas-network-doctor.sh \
  https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-network-doctor.sh &&
sh -n /tmp/kas-network-doctor.sh &&
sh /tmp/kas-network-doctor.sh --target example.com
```

To save both report formats after downloading:

```sh
sh /tmp/kas-network-doctor.sh --target example.com \
  --report /tmp/kas-network-report.txt --json /tmp/kas-network-report.json
```

The `&&` chain **will not execute the script** if downloading or syntax checking fails. Network Doctor intentionally makes bounded external network requests when invoked; this is **not a KAS installation**, a configuration change, or a background service. `/tmp` files are temporary and may disappear after a reboot. If GitHub is unreachable, transfer the script to `/tmp` using SCP and run `sh /tmp/kas-network-doctor.sh --target example.com`.

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

Target and port rules: the URL path and query are preserved and probed as given (`--target https://example.com/missing` really probes `/missing`; a query-only URL like `https://example.com?token=abc` is probed with its query); port priority is explicit `--port` > the port inside the URL > the scheme default (443/80); IPv6 literals and non-numeric ports are an explicit usage error, never a silent probe of another address, and usage errors never echo the raw input. Report policy: **the path and the query are never printed** - in stdout, the text report and the JSON any non-root path appears as `[path withheld]`, the query as `[query withheld]`, userinfo as `[credentials withheld]`; the network probe always uses the full URL.

Statuses: `PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED`. Exit codes: `0` chain confirmed (DNS+TCP+TLS answered, HTTP answered with any status); `1` confirmed stage failure; `2` usage error; `3` inconclusive (nothing FAILed, but the chain never completed); the verdict prints an exact inventory of confirmed stages and missing evidence instead of "nothing is proven".

## Stages and stable check ids

| Check id | What it shows |
| --- | --- |
| `tools.curl` | curl availability (without it most stages are `UNSUPPORTED`, verdict inconclusive) |
| `dns.router` | system-resolver lookup with explicit NXDOMAIN / SERVFAIL / REFUSED / timeout classification; `NOT TESTED` for IP targets |
| `dns.curl-path` | side evidence only: when the independent DNS stage could not run (no `timeout`, no nslookup or exhausted budget) but the target was reached via TLS/HTTP, records `PASS` "the name resolved on the curl path". NOT an independent DNS stage, not part of the verdict chain, not a substitute |
| `dns.custom` | the same name via `--dns-server`; disagreement with `dns.router` is printed as a fact |
| `tcp.connect` | TCP to host:port via the curl telnet trick; telnet support is first detected from `curl -V` - a curl built without telnet skips the TCP-only probe without spending a request (`NOT TESTED`), and TLS/HTTP evidence confirms TCP instead; `curl 7` refused/unreachable; `curl 56` on telnet means the connection was established (peer closed the probe). When the TLS/HTTP stage proves the server exchange, TCP is recorded as proven and the disagreeing telnet observation is flagged explicitly |
| `tls.handshake` | TLS handshake with verification enabled: `curl 35` (handshake), `60/19` (certificate: clock/CA), `43` (malformed), `56` (mid-handshake reset -> UNKNOWN) |
| `http.response` | HTTP status and the redirect target (`%{redirect_url}`); **redirects are not followed** - one bounded request; 3xx comes with the redirect target and a captive-portal hypothesis; 4xx/5xx = "transport healthy, application answered" (a fact, not a network failure) |
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

## JSON contract for future KAS Web integration

`--json FILE` writes `network-diagnostics/v1` in plain POSIX sh (jq is not required for writing or reading): schema, tool version, UTC time, exit code, verdict (summary/first_failed_stage/hypotheses/next_steps), target, vantage (`router`), budget (timeouts, limits, counters), egress observations, status counts and a `checks` array with stable `id`/`status`/`detail`/`observed` fields. All statuses come from the fixed vocabulary. The Doctor 1.2.18/1.2.19 parser (doctor-report.js) is untouched.

## Testing and evidence boundaries

- `tests/network-doctor-regression.py` - offline regression: mock curl/nslookup/ndmc/netstat/jq/pgrep injected via PATH, behavioral and dedicated regression scenarios on both shells (dash-compatible sh and BusyBox ash): NXDOMAIN/SERVFAIL/REFUSED/timeout, TCP refused/reset/timeout, TLS 35/60/56/28, HTTP 200/403/500/redirect, captive portal, resolver disagreement, missing curl, unreachable Controller, disabled egress, positive Mihomo/ProxyN/MagiTrickle paths, exact request counts, JSON validity on happy and failure paths, PATH isolation, "the secret never appears in any output".
- Executed on host sh and BusyBox ash 1.37: **MOCK PASS on both dialects**. This proves the logic, not a field result.
- **QEMU (separate read-only guest run): PASS for executing both new scripts** in disposable KeeneticOS Ported 5.1.8 / Entware (DRIVER_OK, 254 s). Network Doctor executed, its `network-diagnostics/v1` JSON was valid and `checks[].id` were unique; isolated-guest DNS failure was classified. With WAN `restrict=on` and curl absent, **successful external networking in QEMU: NOT TESTED**. The green GitHub `native-kas / ported-lab` CI proves the general KAS lifecycle, not this separate guest script exercise. **PHYSICAL: NOT TESTED** - actual Keenetic hardware requires a separate owner GO.
