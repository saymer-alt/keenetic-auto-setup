# Entware curl/libcurl version skew (issue #254)

## Incident (field, 2026-11-17, Hopper 4G+, Entware `aarch64-3.10`)

```text
opkg update
opkg install curl          # Upgrading curl on root from 8.15.0-2 to 8.23.0-1
curl: symbol lookup error: curl: undefined symbol: curl_multi_get_offt
opkg status                # curl 8.23.0-1 + libcurl 8.15.0-2 (misaligned)
opkg install libcurl       # recovery -> both 8.23.0-1, curl works, HTTPS OK
```

## Root cause (proved from the real feed metadata, 2026-11-18)

The official Entware feeds (`bin.entware.net/aarch64-k3.10/` and
`/mipselsf-k3.4/`, `Packages.gz` checked 2026-11-18) declare:

```text
Package: curl
Version: 8.23.0-1
Depends: libc, libssp, librt, libpthread, libcurl     <- NO version bound
```

`libcurl` is an **unversioned dependency**. When an older `libcurl` is
installed, opkg considers the dependency satisfied and
`opkg install curl` upgrades the executable **alone**. There is nothing in
`opkg status` marking the pair inconsistent afterwards. `opkg upgrade`
(mass) would have upgraded both, which is why the field saw the break only on
the selective install path.

Symbol side (verified from the real IPK bytes, both ABIs): `/opt/bin/curl`
8.23.0-1 references `curl_multi_get_offt`; `libcurl.so.4.8.0` 8.23.0-1 exports
it; the 8.15 generation does not. A partially upgraded system therefore has a
curl whose startup (any lazy bind of that symbol, e.g. under `LD_BIND_NOW=1`)
fails with `undefined symbol: curl_multi_get_offt`.

## Detection layers and their limits

1. **Package-database comparison (primary, cheap, no execution)** — compare
   `opkg status curl` vs `opkg status libcurl` versions. `kas-web-install.sh`
   fails closed before any download when they differ, with the repair command
   in the message. Limit: detects version skew only; an ABI-skew with equal
   versions (e.g. mixed feeds) is invisible to it.
2. **`LD_BIND_NOW=1 curl -V`** — forces eager binding, so missing lazy-bound
   symbols fail at startup. This catches the field failure class even when
   plain `curl -V` appears to work, and is the probe of last resort when the
   package database cannot be trusted. **Limits (do not treat as an HTTPS
   guarantee):** it verifies nothing about TLS backends, CA stores, proxies,
   network reachability or symbol *compatibility* that still resolves
   (struct-layout skew); a `curl -V` success means "the ELF loader can start
   curl", nothing more.
3. **Full HTTPS proof** requires an actual `https://` request with the default
   trust store (the field recovery proof was `curl -fIL https://github.com/`
   → `HTTP/2 200`). KAS install scripts enforce HTTPS + SHA256 on every asset
   they download; that is the real end-to-end check and it stays.

## Recovery (field-proven, manual by design)

```sh
opkg update && opkg install libcurl
LD_BIND_NOW=1 curl -V
curl -fIL --max-time 15 https://github.com/
```

KAS never auto-upgrades feeds or package ownership; the repair is an explicit
operator step (see `kas-web-install.sh` fail message).

## Bootstrap-stage limitation (why the installer cannot self-diagnose here)

The first KAS stage is `curl -fSsL https://…/install.sh | sh`: **if curl
itself is broken, the downloaded script cannot run any diagnostic**, so no
check inside KAS scripts can help that stage. The documented operator
fallback is to verify/repair curl **before** the one-liner:

```sh
LD_BIND_NOW=1 curl -V || { opkg update && opkg install libcurl; }
curl -fSsL https://raw.githubusercontent.com/<repo>/<ref>/install.sh | sh
```

KAS deliberately does **not** ship an alternative TLS loader for that stage
(a weak wget/busybox path would bypass the TLS/SHA256 guarantees).

## Laboratory classification (see `router-emulator` issue #108 / PR with the matrix)

- The historical `libcurl 8.15.0-2` is no longer published (404 on
  `bin.entware.net` and `test.entware.net`, both ABIs, verified 2026-11-18),
  so the emulator reproduction of the skew uses a **synthetic ELF model**
  built from the real 8.23.0-1 package bytes with exactly one dynamic-symbol
  name removed and the control version set to 8.15.0-2 — `SYNTHETIC PASS` at
  package level, `REAL` at ELF-loader level (the loader failure and the
  `curl_multi_get_offt` signature are produced by the real loader on real
  Entware files). Rows without a real 8.15.0-2 package are labelled
  accordingly and never presented as `REAL REPRO`.
- Aligned, missing-library, wrong-ABI, corrupted-library, dangling-symlink,
  missing-`ldd`, feed-outage and truncated-IPK rows run against the real
  packages (mipsel) with real `opkg`.
