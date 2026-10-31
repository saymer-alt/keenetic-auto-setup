# KAS Control Center — standalone lifecycle (experimental)

**Not a production release**. This is a strictly opt-in, loopback-only add-on. Existing KAS installer/bootstrap and the router are unchanged.

## Scope
- Standalone POSIX helper: web/control-center/kas-web-manage.sh.
- Install from a locally provided, SHA256-verified binary for the device architecture. No remote downloads, automatic upgrades, or package installation.
- Explicit install, start, stop, status and remove operations for the panel itself.
- Managed paths only: /opt/bin/kas-control-center, /opt/etc/init.d/S98kas-control-center, /opt/etc/kas-control-center.web.sha256, /opt/var/run/kas-control-center.pid.
- Refuses foreign files, modified owned binary, unverified process PID and untracked process. No automatic overwrite.
- Stage 4 experimental launcher chooses the single private IPv4 of Home br0 and serves plain HTTP on TCP/18081, without app password by default. It never binds WAN, Guest, wildcard, or IPv6; routed peers are allowed unless Home-only is enabled (see LAN.md). This supersedes the old Stage 3 localhost-only launcher behavior on this branch.
- SIGTERM causes the Go process to reject new requests and wait for any running canonical importer before exit. No SIGKILL fallback from the service helper.
- remove does NOT alter Mihomo, MagiTrickle, KAS core, Watchdog, configs, backups, policies, Entware shared packages or foreign services.

## Laboratory reproduction only

Build the Go executable from the *same pinned, reviewed source revision* (go generate first):

    cd web/control-center
    go generate ./...
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o kas-web-arm64 .
    sha256sum kas-web-arm64

Transfer the binary and this source-checked script to a disposable Entware device using trusted lab provisioning, then:

    sh /path/to/kas-web-manage.sh install /path/to/kas-web-arm64 EXACT_64_HEX_SHA256
    sh /opt/etc/init.d/S98kas-control-center start
    sh /opt/etc/init.d/S98kas-control-center status
    sh /opt/etc/init.d/S98kas-control-center stop
    sh /opt/etc/init.d/S98kas-control-center remove

Installation does not immediately start the GUI. S*-named init can be auto-started at boot by Entware; native guest reboot behavior has NOT been accepted yet.

## Tests and unresolved gates
- CI: sh/dash syntax, mocked isolated /opt install/start/stop/remove, wrong digest, foreign collision, unknown PID, modified binary and immutable KAS-core sentinel; Go race/shutdown tests, ARM64 compilation.
- Stage 3 localhost-mode native guest lifecycle PASS; Stage 4 Home bridge access, reboot, resource usage and power loss require their own acceptance.
- No WAN publication or automatic KeenDNS configuration. The optional LAN password file, exact reverse-proxy origin and bridge guard are documented in LAN.md.
- Crash/SIGKILL during import can lose in-memory operation state. A safe offline recovery policy requires separate evidence.
- Stage 2 Web import native E2E (emulator PR #39) must PASS separately. Host code tests alone are insufficient.

Keep Draft until emulator and independent test hardware results plus owner GO.
## KN-1010 MIPSel hardware test

The prototype workflow also builds a static `linux/mipsle` binary with
`GOMIPS=softfloat` and uploads a SHA256-checked optional test bundle pinned to
the PR head source revision. See [KN1010_TEST.md](KN1010_TEST.md) for preparation,
manual installation and test boundaries. Compilation is not hardware acceptance.
