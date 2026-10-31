# KAS script download and GitHub reachability diagnostics

`kas-download-check.sh` is a standalone **read-only** diagnostic (issues [#158](https://github.com/saymer-alt/keenetic-auto-setup/issues/158), [#266](https://github.com/saymer-alt/keenetic-auto-setup/issues/266), [#270](https://github.com/saymer-alt/keenetic-auto-setup/issues/270)). It checks, stage by stage, the same chain that KAS install/update uses: tools -> time/CA -> DNS -> TCP -> TLS/HTTP -> bounded transfer -> received-file validation. The regular Doctor performs no external network probes; this is a separate explicit mode.

## What it does and does not do

- Changes nothing: DNS, routes, firewall, interfaces, ProxyN, Mihomo, MagiTrickle and configuration are untouched.
- Downloaded bytes are **never executed**: only the shebang, project markers and `sh -n` are checked (same as `bootstrap.sh`).
- Never prints subscriptions, passwords, tokens or YAML; the report is size-bounded.
- Never declares a cause (DPI, provider blocking, GitHub outage) as established: each source is reported separately, and one alternative success does not prove a shared cause.
- Per-attempt limits: connect 7s, total 25s, max 256 KiB — matching the KAS loader.

## Running

```sh
sh kas-download-check.sh                     # stable ref, setup.sh
sh kas-download-check.sh --ref main          # another ref
sh kas-download-check.sh --script config-import.sh
sh kas-download-check.sh --report /opt/tmp/kas-dl-report.txt
KAS_MOSHUB_URL='https://…' sh kas-download-check.sh --moshub   # optional mirror
```

Statuses: `PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED`. Exit codes: `0` — at least one source returned a valid script; `1` — none; `2` — usage error.

## Sources checked (separately)

| Source | Meaning |
| --- | --- |
| RAW normal TLS | the primary install/update path |
| RAW IPv4 + X25519 | the docs/03 compatibility path (the `curl (35)` field case); `UNSUPPORTED` when curl lacks `--curves` |
| RAW via wget | an independent transport; `NOT TESTED` when wget is absent |
| GitHub Contents API | raw media without the raw CDN |
| Mirror (Mos.Hub) | only with `--moshub` and `KAS_MOSHUB_URL`; no verified public mirror is recorded in this repository yet — otherwise `NOT TESTED` |

## Reading typical results

- `exit 6` — DNS: check the router resolver; later stages fail accordingly.
- `exit 7` — TCP 443 unreachable: routing/provider, not TLS.
- `exit 35` — TLS handshake: the known field case #255; the IPv4+X25519 compatibility path and Contents API are reported separately.
- `exit 60` — certificate verification: typical causes are a wrong device clock or a missing `ca-bundle`.
- `HTTP 404/5xx` — wrong ref/URL or a service problem; the exact URL and ref are printed.
- `mid-transfer` (18) — the connection dropped mid-body; a partial file can never be executed.

The tool keeps confirmed observations (exit codes, http_code, sizes, markers) separate from hypotheses (the actual network failure cause). The full report (`--report`) is suitable for pasting into an Issue.

## Limitations

- POSIX sh / BusyBox ash / Entware; optional tools (`wget`, `nslookup`, `mktemp`) may be absent — this is reflected as `NOT TESTED`/`UNKNOWN` statuses, not a crash.
- The TCP stage uses curl's `telnet://` support; a curl built without it is reported `UNKNOWN` for that stage.
- The Windows/CI run and the offline regression (`tests/download-check-regression.py`, 19 cases + report + PATH isolation) prove the logic but are **not** a field PASS on Keenetic/Entware — the first hardware run on KN-1010 belongs to the owner.
