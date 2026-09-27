# Practical MagiTrickle field configuration

This repository includes a **real MagiTrickle user export** used by Saymer as a
working baseline on client routers.

Field snapshot:

- [`saymer-field-2026-09-27.mtrickle`](../examples/magitrickle/saymer-field-2026-09-27.mtrickle)

The 2026-09-27 snapshot contains 8 groups and 287 rules:

- 217 `namespace`
- 48 `subnet`
- 11 `domain`
- 9 `wildcard`
- 2 `regex`

Seven normal routing groups use **`mitun0`**; the ad/tracking blocking group uses
`blackhole`. The `*.com` experimental group is present but disabled in the export.

## Important scope

This is **not an official service-domain catalogue**, not a universal recommended
configuration, and not a completeness guarantee. It is field evidence accumulated
through real use, community/chat lists, practical observations, and service testing.

Domains, APIs, CDNs, ASN ranges and IP networks change over time. Broad CDN/cloud
subnets, whole-domain regexes and other wide rules may route much more traffic than
a different user expects.

Treat the file as either:

1. a complete field example that you may import after taking your own backup; or
2. a source of candidate rules from which to build smaller service-specific groups.

## Importing the snapshot

Open MagiTrickle at:

```text
http://<router-IP>:8080/
```

Back up your existing setup with **Export Config** first, then use **Import Config**.

After import, verify that:

- `mitun0` exists in the active Mihomo config;
- the intended groups are enabled;
- the required services actually work through the intended path;
- broad subnet/wildcard/regex rules are appropriate for your network.

For a safer from-scratch workflow, see
[the MagiTrickle domain-list guide](../HOWTO.md#64-building-a-domain-list-and-a-magitrickle-group-from-scratch).

## Sources and subscriptions

OpenCCK is only one possible source. A practical list can combine:

- public databases;
- browser/network observations;
- community lists;
- direct operational evidence.

MagiTrickle also supports subscriptions to remote lists. A user can keep their own
list in GitHub/Gist or another HTTP location and let multiple routers consume the
same maintained source.

This repository does **not yet present this full field snapshot as a supported
public subscription**. It is preserved as a dated full-config sample. A future
maintenance path may split reviewed service-specific lists (OpenAI, Gemini, Claude,
YouTube, Telegram, Meta/WhatsApp, TikTok, Netflix, Apple, etc.) into separate raw
subscription-friendly files.

## Maintenance model

Do not silently rewrite this historical snapshot when services change. Add a new
dated snapshot or maintain separate current lists instead. Keep these concepts
separate:

- **field evidence** — what was actually used;
- **current maintained list** — what is believed to be current now;
- **official source** — a list published by the service itself, if one exists.
