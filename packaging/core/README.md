# KAS core IPK: packaging qualification, not a router release

This directory implements the first evidence gate of the approved package plan.
It is **not a deployable KAS core**. Live-root installation is explicitly refused
by all hooks; only disposable `--offline-root` transactions are permitted.
Existing KAS runtime scripts and the current panel package remain unchanged.

## Proven problem and decision

Existing KAS watchdog replacement acquires the shared lifecycle lock, validates
and stages the script on the target filesystem, then atomically renames it.
Putting that operational path directly in an IPK does not transfer those
contracts to opkg.

On 2026-10-28 the pinned official Entware opkg was run against synthetic packages
in temporary offline roots. Installing revision 1, then revision 2 with a failing
postinst, produced a nonzero result **but left revision 2 in the operational path**.
Removing the package then removed that file. A synthetic KAS lock directory did
not cause raw opkg to defer extraction. This is an opkg characterization, not an
opkg bug or a test of the real KAS lifecycle owner protocol.

| Check | Result |
| --- | --- |
| Failed postinst automatically restores the previous payload | No |
| Package removal retains its operational watchdog file | No |
| Raw extraction participates in the KAS lifecycle lock automatically | No |
| Lab archive install/upgrade/remove leaves operational sentinels identical | Yes |
| Modified, added, foreign or symlinked bundle files block upgrade | Yes |
| Modified bundle blocks ordinary removal | Yes |
| Prototype can be installed on a live root | No: deliberately blocked |

**Decision:** do not put active cron/init/netfilter/watchdog paths in this
prototype's data archive. Package a verified bundle first; qualify activation of
canonical operational paths through existing transactions separately. Only the
canonical deployed watchdog may be scheduled. The archive copy is an installation
input, not another scheduled or independently updated watchdog.

This proves that a tar archive alone is insufficient. It does **not** prove a
production adoption/rollback/uninstall policy. Those remain the next gate before
binding the UI to `kas-core` or shipping any package.

## Contents and build

The 17 tracked top-level scripts (including `S00ubifs`) are copied
byte-for-byte to `/opt/libexec/kas/`. Nothing is executed on package installation.
The list includes installers and uninstallers as archive content, not Web actions.
`/opt/share/kas-core/` contains `BUILD_INFO`, `scripts.json`, `SHA256SUMS` and the project `LICENSE`.
The source SHA is checked against the actual committed script bytes; assigning a
SHA from a different script revision is refused.

```sh
python3 packaging/core/build-ipk.py \
  --version '0.0.0~proof1-1' \
  --source-sha "$(git rev-parse HEAD)" \
  --output /tmp/kas-core-lab
```

Architecture is `all` because this package contains shell scripts only. This says
nothing about router/platform compatibility of each archived script. The builder
accepts only `0.0.0~proofN-N` versions to prevent an accidental ordinary release.
It reuses the existing Entware gzip-tar IPK archive writer.

The hooks check package ownership, exact content, expected root ownership and
modes, and refuse symlinks or unexpected members before bundle extraction.
They reject aliases of the live root and noncanonical roots with symlink ancestors.

**Boundary:** opkg initializes its own database before invoking preinst. An
existing symlink in its database path can therefore redirect database writes even
when the package subsequently refuses extraction. A real-opkg characterization
test pins this behavior. Maintainer hooks alone cannot protect all opkg writes;
these tests use exclusively owned disposable roots. Do not invoke this lab package
against a router, an untrusted offline root, or existing administrative paths.
A production transaction launcher will need a root/database preflight before
starting opkg, in addition to the package's own payload checks. opkg's recorded MD5 baseline
helps detect local edits to the manifest itself; it is **not** an authenticity
signature. Payload provenance uses SHA256 and the explicit source commit. Root
administrators who deliberately rewrite both payload and opkg database are outside
this local modification detector. Forced opkg operations bypassing hooks are not
supported.

## Reproduce

Download official Entware opkg to a scratch path and verify:

```text
https://bin.entware.net/x64-k3.2/installer/opkg
SHA256: 08c8feb2ef3153f025ba687f8df02adf915e4252a3605cc6798f8d105162cb38
```

```sh
KAS_TEST_OPKG=/path/to/verified/entware-opkg python3 tests/test_core_ipk.py -v
KAS_TEST_OPKG=/path/to/verified/entware-opkg python3 tests/test_ipk.py -v
```

Tests build real tar-IPKs, execute real opkg hooks and inspect on-disk results.
Without `KAS_TEST_OPKG`, real-opkg tests explicitly skip. They never install in the
host root or launch any bundled installer/service. CI pins the same binary hash.

## Limits and next gates

- No automatic canonical-file adoption or package-hook watchdog activation yet.
- No UI dependency or runtime switch from embedded scripts yet.
- No component update buttons or release-manifest protocol yet.
- No inference that an unrecognized SHA is older or safe to overwrite.
- No router/guest boot evidence from these host offline-root tests.
- No claim that current native Web stages boot the new panel IPK; they do not.

Next: integrate the guarded activation primitive with a recognized-release
baseline catalogue and package activation state/recovery policy. Then install the
actual IPK in disposable guest firmware, reboot and verify auth/port persistence.
The panel/core/full package integration follows only after those gates.

## Next proof: pre-opkg launch and guarded watchdog activation

`lab-opkg.sh ROOT VERIFIED_OPKG install ABSOLUTE_IPK` (or `remove kas-core`)
checks the canonical offline root, database, temporary paths, root ownership and
write permissions **before** starting opkg. It rejects root aliases, symlinks,
unexpected arguments and a binary differing from the pinned official host opkg.
A private per-root lock prevents overlapping cooperative lab launches; stale locks
require inspection. Inherited package-hook root variables are removed. Arguments
cannot select a different destination or force overwrites.

This launcher accepts **trusted project-built lab packages only**. It is not an OS
sandbox: package maintainer hooks run as root and must be reviewed. It is host
qualification tooling, not an Entware router entry point. Raw-opkg tests remain
separate to demonstrate why hooks alone cannot prevent database redirection.

The canonical `update-watchdog.sh` now has an opt-in local input:

```text
sh update-watchdog.sh --package-candidate FILE CANDIDATE_SHA INSTALLED_SHA
```

This does not download or execute the candidate. Under the existing lifecycle
lock it validates a root-owned local source, pinned candidate digest, caller-known
installed digest, executable canonical watchdog, exact cron wrapper and a single
canonical direct schedule. Unknown/run-parts/legacy/duplicate cron layouts are
refused without migration; use the explicit existing migration/update path first.
Ordinary updater network sources and fallback behavior remain available unchanged.

A SHA is not an age or authenticity assertion. The caller must recognize the old
file and trust the candidate through an approved package/release manifest. This
proof adds the guarded activation primitive; it does not yet implement that
release-baseline catalogue, general adoption, or automatic postinst activation.

The local mode creates exclusive private input/target stages and a verified
same-filesystem recovery copy. It never copies through preexisting stage symlinks.
The installed digest is rechecked immediately before atomic rename. During the
pending commit, controlled failures or handled INT/TERM/HUP restore and verify the
old canonical watchdog. Repeated handled signals are ignored during recovery.
On recovery failure, a private backup is retained and recovery is **not** reported
as successful. Stale recovery copies block subsequent package activation until
inspected. Uncooperative external writers are not covered by the shared lock; an
unrecognized output is preserved rather than blindly overwritten on recovery.

SIGKILL, power loss and persistence after storage failure are not solved by shell
traps. Reboot/recovery policy, package-version activation records and full firmware
acceptance remain separate gates. No new cron entry, watchdog execution, Mihomo
restart, or router-setting change is performed by this local activation mode.

Tests run the full updater with `/opt` and `/tmp` redirected to temporary fixtures.
Faults cover checksum mismatch, stale baseline, foreign/duplicate cron, concurrent
maintenance, staging failure, failure after rename, handled signals, stage/input/
backup aliases and restoration failure. Where the local executor's PID namespace
does not match mounted `/proc`, fixtures explicitly seed the updater's existing
identity cache with the actual host process identity. This is disclosed fixture
adaptation, not native identity evidence. CI requires native PID/proc identity and
runs the suite on sh, dash and BusyBox ash without this adaptation.
