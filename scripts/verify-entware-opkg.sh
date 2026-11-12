#!/bin/sh
# Fail-closed verifier for the official Entware opkg bootstrap artifact.
#
# Single source of truth for the pinned download URL and SHA256 used by the
# CI qualification ladder. Workflows must verify this artifact through this
# script instead of inlining their own curl + sha256sum copies, so a re-pin
# (when it is ever authorized) is a one-place change with one audit trail.
#
# Provenance policy (Issue #488, BLOCKED_UPSTREAM_PROVENANCE): Entware
# publishes no signatures for installer artifacts. If the pinned digest stops
# matching, this gate stays RED and prints the observed bytes for diagnosis.
# Never silently re-pin, never execute or chmod unverified bytes, never
# downgrade to HTTP or a weaker check, and never substitute a mirror without
# a documented owner provenance decision.
#
# Offline tests override --url/--sha256/--source and stub curl via PATH; no
# real network is touched by the negative regressions.
set -eu

ENTWARE_OPKG_URL='https://bin.entware.net/x64-k3.2/installer/opkg'
# Re-pin 2026-11-09: documented owner trust decision (Issue #488, Option A,
# owner GO comment 6747639647), not a cryptographic attestation. Entware does
# not sign installer artifacts; the pinned binary is opkg 2025.11.05~80503d94-1
# and is byte-identical to ./opt/bin/opkg of the versioned feed package
# opkg_2025.11.05~80503d94-1_x64-3.2.ipk (feed SHA256sum e2b254f5...74e89).
ENTWARE_OPKG_SHA256='49f3d1e047483dc068fcc8985d64dcd28d0041044434de2cb3ccd616f2fc0b10'

usage() {
    echo "usage: $0 --output PATH [--url URL] [--sha256 HEX] [--source FILE] [--no-elf-check]" >&2
    exit 2
}

url=$ENTWARE_OPKG_URL
expected=$ENTWARE_OPKG_SHA256
output=
source=
elf_check=1
while [ $# -gt 0 ]; do
    case $1 in
        --output) [ $# -ge 2 ] || usage; output=$2; shift 2 ;;
        --source) [ $# -ge 2 ] || usage; source=$2; shift 2 ;;
        --url) [ $# -ge 2 ] || usage; url=$2; shift 2 ;;
        --sha256) [ $# -ge 2 ] || usage; expected=$2; shift 2 ;;
        --no-elf-check) elf_check=0; shift ;;
        *) usage ;;
    esac
done

case $expected in
    *[!0-9a-f]*) echo "VERIFY: FAIL: expected digest must be 64 lowercase hex digits" >&2; exit 2 ;;
esac
[ "${#expected}" -eq 64 ] || { echo "VERIFY: FAIL: expected digest must be 64 hex digits" >&2; exit 2; }
[ -n "$output" ] || [ -n "$source" ] || { echo "VERIFY: FAIL: --output or --source required" >&2; exit 2; }
[ -z "$output" ] || [ -z "$source" ] || { echo "VERIFY: FAIL: --output and --source are mutually exclusive" >&2; exit 2; }

# Print server metadata for the artifact (Content-Length, ETag,
# Last-Modified) when the server answers; empty metadata never fails the
# verification itself, it only enriches the audit trail.
artifact_metadata() {
    curl -sI --connect-timeout 10 --max-time 20 "$url" 2>/dev/null \
        | grep -iE '^(content-length|etag|last-modified):' \
        | tr -d '\r' || true
}

verify_payload() {
    # $1: payload path, $2: short label for messages. Sets OBSERVED and SIZE.
    verify_payload_file=$1
    verify_payload_label=$2
    SIZE=$(wc -c < "$verify_payload_file" | tr -d ' \t')
    # The digest is computed before every early-return: report_mismatch runs
    # under set -u and must always see OBSERVED, otherwise the empty and
    # non-ELF payload paths used to die on "OBSERVED: parameter not set"
    # (exit 2, no observed-digest diagnostics) instead of a full rc=1 report
    # (independent review, issue #156; same fix as the local 5f7253d there).
    # GNU coreutils prints a leading "\" marker for filenames needing
    # escapes (Windows-style paths); the digest value itself follows it.
    OBSERVED=$(sha256sum "$verify_payload_file" | awk '{print $1}' | sed 's/^\\//')
    if [ -z "$SIZE" ] || [ "$SIZE" -eq 0 ]; then
        echo "VERIFY: FAIL ($verify_payload_label): payload is empty" >&2
        return 1
    fi
    if [ "$elf_check" = 1 ]; then
        magic=$(dd if="$verify_payload_file" bs=4 count=1 2>/dev/null || true)
        if [ "$magic" != "$(printf '\177ELF')" ]; then
            echo "VERIFY: FAIL ($verify_payload_label): payload is not a verified ELF bootstrap (wrong magic bytes)" >&2
            return 1
        fi
    fi
    if [ "$OBSERVED" != "$expected" ]; then
        return 1
    fi
    return 0
}

report_mismatch() {
    # $1: label. Uses OBSERVED/SIZE set by verify_payload. Server metadata is
    # appended by the network-mode caller; offline --source failures must
    # stay deterministic without touching the network.
    {
        echo "VERIFY: FAIL ($1): pinned Entware artifact digest mismatch (Issue #488)"
        echo "  expected: $expected"
        echo "  observed: $OBSERVED"
        echo "  bytes:    $SIZE"
        echo "  Upstream bytes changed or the source is compromised. This gate"
        echo "  stays RED: do NOT re-pin, execute, or weaken the check without a"
        echo "  documented owner provenance decision (BLOCKED_UPSTREAM_PROVENANCE)."
    } >&2
}

if [ -n "$source" ]; then
    [ -f "$source" ] || { echo "VERIFY: FAIL: source payload missing: $source" >&2; exit 1; }
    if verify_payload "$source" "supplied payload"; then
        echo "VERIFY: OK $expected ($source)"
        exit 0
    fi
    report_mismatch "supplied payload"
    exit 1
fi

part="$output.part"
mkdir -p "$(dirname "$output")"
metadata=$(artifact_metadata)
# Same bounded retry budget as the previous inline ladder: a slow Entware
# mirror is an infra condition, not a version-ladder failure.
if ! curl --fail --location --connect-timeout 15 --max-time 120 \
        --retry 2 --retry-delay 5 --retry-all-errors \
        "$url" -o "$part"; then
    rm -f "$part"
    echo "VERIFY: FAIL: download transport error for $url" >&2
    exit 1
fi
if verify_payload "$part" "downloaded payload"; then
    mv "$part" "$output"
    echo "VERIFY: OK $expected ($url)"
    [ -z "$metadata" ] || printf '%s\n' "$metadata" | sed 's/^/  server:   /'
    exit 0
fi
rm -f "$part"
report_mismatch "downloaded payload"
artifact_metadata | sed 's/^/  server:   /' >&2
exit 1
