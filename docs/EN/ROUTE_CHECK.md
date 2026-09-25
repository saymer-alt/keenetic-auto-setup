# mihomo-route-check.sh — focused domain/IP diagnostic

`mihomo-route-check.sh` is a read-only helper for one domain, IP address, or URL.

It complements Doctor by answering a narrower question: can the current local Mihomo path reach this specific target?

## Run

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-route-check.sh -o /tmp/mihomo-route-check.sh && \
sh /tmp/mihomo-route-check.sh github.com
```

Examples:

```bash
sh /tmp/mihomo-route-check.sh https://www.cloudflare.com/
sh /tmp/mihomo-route-check.sh 1.1.1.1
```

## Checks

The helper reports:

1. normalized target;
2. DNS resolution;
3. project ProxyN evidence from Keenetic running-config;
4. local TCP port 7890;
5. current Mihomo selection from Controller `GET /proxies`;
6. an HTTP(S) request through SOCKS5h on `127.0.0.1:7890`.

## Interpretation

A successful SOCKS5h probe proves that Mihomo can reach the target through its current proxy path.

It does **not** prove that a specific LAN client was classified into the expected Keenetic/MagiTrickle policy. Client-policy problems need separate policy, MagiTrickle, DNS and connection-state evidence.

## Read-only contract

The helper does not change proxy selection, trigger delay tests, modify iptables/policies/DNS, restart Mihomo, or write config.

Controller access is read-only.

## Controller secret

Prefer an environment variable:

```bash
MIHOMO_API_SECRET='secret' sh /tmp/mihomo-route-check.sh github.com
```

Optional environment overrides:

- `MIHOMO_CONTROLLER_URL`;
- `MIHOMO_SOCKS_HOST`;
- `MIHOMO_SOCKS_PORT`;
- `MIHOMO_PROXY_GROUP`.

## Why this is separate from Doctor

Doctor answers whether the overall stack is healthy.

This helper answers whether one target works through the current local Mihomo path, without turning Doctor into a heavy tracer.
