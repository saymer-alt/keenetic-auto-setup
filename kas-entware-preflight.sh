#!/bin/sh
# KAS Entware/BusyBox preflight (issue #356) — READ-ONLY diagnostics.
#
# Field failure (Entware chat, 2026-11-03, not reproduced by KAS): after a
# test-feed mass upgrade of BusyBox 1.37 -> 1.38 on aarch64-3.10, applet
# links disappeared: `Bad interpreter "/opt/bin/sh"`, `chmod: not found`.
# The official mechanism (Entware package/utils/busybox Makefile): prerm
# deletes every /opt/bin,/opt/sbin symlink whose resolved target is the
# canonical busybox; postinst recreates links from
# /opt/share/busybox_applets.lst.dist but ONLY for names that do not
# exist ([ ! -e ] does not cover a dangling symlink). An interruption
# between those phases (or a later repair that blindly wrote links)
# leaves the Entware runtime unusable.
#
# This script diagnoses that state from the SYSTEM shell: its control
# flow never depends on a /opt binary. Every /opt tool is called through
# an absolute path with best-effort guards; nothing is created, renamed,
# chmoded, deleted, installed or upgraded here, and no feed is touched.
# It is a diagnostic, not a repair: the upstream postinst semantics are
# the only sanctioned link-recreation mechanism and manual `ln -sf`
# recovery is explicitly out of scope (owner decision 2026-11-03).
#
# Output: one line per check, prefixed PASS: / WARN: / FAIL: / UNKNOWN:
# (same severity vocabulary as Doctor). Secrets, config contents and
# private URLs are never printed.
# Exit code: 0 = no FAIL and no UNKNOWN; 1 = at least one FAIL;
# 2 = no FAIL but at least one UNKNOWN (operator must look manually).

set -u

BB="/opt/bin/busybox"
SH="/opt/bin/sh"

RESULT=0
RESULT_CODES=0

emit() {
    # emit <severity> <id> <detail>
    printf '%s: %s: %s\n' "$1" "$2" "$3"
    case "$1" in
        FAIL) RESULT_CODES=1 ;;
        UNKNOWN) [ "$RESULT_CODES" -ne 1 ] && RESULT_CODES=2 ;;
    esac
}

# Classify a path with dereferencing builtins only (readlink may itself
# be a missing applet when the runtime is broken). Prints one word:
# missing | dangling | notexec | file | link | special
classify_path() {
    if [ -L "$1" ]; then
        if [ -e "$1" ]; then
            if [ -f "$1" ] && [ -x "$1" ]; then
                printf 'link'
            elif [ -d "$1" ]; then
                printf 'special'
            else
                printf 'notexec'
            fi
        else
            printf 'dangling'
        fi
    elif [ -d "$1" ]; then
        printf 'special'
    elif [ -f "$1" ]; then
        if [ -x "$1" ]; then
            printf 'file'
        else
            printf 'notexec'
        fi
    elif [ -e "$1" ]; then
        printf 'special'
    else
        printf 'missing'
    fi
}

# Try to execute an /opt binary directly; prints ok|execfail.
can_execute() {
    if "$1" --help >/dev/null 2>&1 || "$1" >/dev/null 2>&1; then
        printf 'ok'
    else
        printf 'execfail'
    fi
}

# --- 1. busybox binary -----------------------------------------------------
BB_LIST=""
case "$(classify_path "$BB")" in
    missing)
        emit FAIL "busybox-binary" "$BB is missing: the Entware runtime core is gone; use the rescue guide (Keenetic CLI), do not run KAS tools"
        ;;
    notexec|special)
        emit FAIL "busybox-binary" "$BB exists but is not an executable regular file ($(classify_path "$BB"))"
        ;;
    dangling)
        emit FAIL "busybox-binary" "$BB is a dangling symlink"
        ;;
    file|link)
        case "$(can_execute "$BB")" in
            ok)
                emit PASS "busybox-binary" "$BB present and executes"
                if ! BB_LIST=$("$BB" --list 2>/dev/null) || [ -z "$BB_LIST" ]; then
                    BB_LIST=""
                    emit UNKNOWN "busybox-applets" "$BB --list failed or produced no output; consult the rescue guide before using Entware tools"
                fi
                ;;
            execfail)
                emit FAIL "busybox-binary" "$BB does not execute (broken ELF, wrong ABI or missing dynamic loader); manual rescue required"
                ;;
        esac
        ;;
esac

bb_has_applet() {
    # bb_has_applet <name> -> 0 when the running busybox provides it.
    # No PATH tools: when the runtime is broken, /opt/bin/grep itself may
    # be a missing applet, so the list is scanned with builtins only.
    [ -n "$BB_LIST" ] || return 1
    for _bha in $BB_LIST; do
        [ "$_bha" = "$1" ] && return 0
    done
    return 1
}

# --- 2. /opt/bin/sh ----------------------------------------------------------
case "$(classify_path "$SH")" in
    missing)
        emit FAIL "opt-sh" "$SH is missing: Entware shell scripts (including KAS tools and opkg configure) cannot run"
        ;;
    dangling)
        emit FAIL "opt-sh" "$SH is a dangling symlink; shell scripts cannot run"
        ;;
    notexec|special)
        emit FAIL "opt-sh" "$SH exists but is not an executable regular file ($(classify_path "$SH"))"
        ;;
    file|link)
        if "$SH" -c 'exit 0' >/dev/null 2>&1; then
            emit PASS "opt-sh" "$SH present and executes"
        else
            emit FAIL "opt-sh" "$SH does not execute; Entware shell scripts cannot run"
        fi
        ;;
esac

# --- 3. Core applet links ----------------------------------------------------
# A missing /opt/bin/<applet> is a FAIL only when the running busybox
# provides the applet (upstream postinst would have created that link):
# that combination is exactly the interrupted-upgrade state. A missing
# link for an applet this busybox does not provide is normal (foreign
# packages like GNU grep own their files).
for _ka in chmod ln rm cp mv ls cat grep sed awk wget; do
    _ka_path="/opt/bin/$_ka"
    case "$(classify_path "$_ka_path")" in
        missing)
            if bb_has_applet "$_ka"; then
                emit FAIL "applet-$_ka" "$_ka_path is missing while the busybox build provides the applet: interrupted busybox prerm/postinst or manual link damage; see the rescue guide, do not recreate links blindly"
            else
                emit WARN "applet-$_ka" "$_ka_path is missing and this busybox build has no $_ka applet (provided by another package or genuinely absent)"
            fi
            ;;
        dangling)
            # The official postinst [ ! -e ] skips a dangling link, so this
            # state does not self-heal across upgrades: report explicitly.
            if bb_has_applet "$_ka"; then
                emit FAIL "applet-$_ka" "$_ka_path is a dangling symlink while the busybox applet exists; upstream postinst [ ! -e ] will not repair this — manual operator decision required"
            else
                emit WARN "applet-$_ka" "$_ka_path is a dangling symlink and this busybox build has no $_ka applet"
            fi
            ;;
        notexec|special)
            emit FAIL "applet-$_ka" "$_ka_path exists but is not an executable regular file ($(classify_path "$_ka_path"))"
            ;;
        file)
            emit PASS "applet-$_ka" "$_ka_path is a real executable file (foreign package owner — busybox postinst will not replace it)"
            ;;
        link)
            emit PASS "applet-$_ka" "$_ka_path resolves to an executable file"
            ;;
    esac
done

# --- 4. wget HTTPS capability (issue #356 secondary failure) ---------------
# A /opt/bin/wget symlink to busybox is the HTTPS-less applet: Entware
# feeds are https:// and the applet fails on them (Entware #887). A real
# wget-ssl file is healthy. This is read-only reporting, not ownership
# proof: `opkg status wget-ssl` below adds the package view when usable.
if [ -f /opt/bin/wget ] && [ -x /opt/bin/wget ]; then
    if [ -L /opt/bin/wget ]; then
        if [ -z "$BB_LIST" ] ||
           ! _wget_target=$("$BB" readlink -f /opt/bin/wget 2>/dev/null) ||
           ! _bb_target=$("$BB" readlink -f "$BB" 2>/dev/null) ||
           [ -z "$_wget_target" ] || [ -z "$_bb_target" ]; then
            emit UNKNOWN "wget-capability" "cannot resolve the wget and BusyBox targets; verify the wget implementation manually"
        elif [ "$_wget_target" = "$_bb_target" ]; then
            emit WARN "wget-capability" "/opt/bin/wget points at busybox: the BusyBox wget applet has no HTTPS support, https feeds will fail with 'wget returned 1' (Entware #887)"
        else
            emit PASS "wget-capability" "/opt/bin/wget does not resolve to the canonical BusyBox binary"
        fi
    else
        emit PASS "wget-capability" "/opt/bin/wget is not a busybox-applet link"
    fi
else
    emit FAIL "wget-capability" "/opt/bin/wget is missing or unusable; consult the rescue guide before attempting downloads"
fi

# --- 5. opkg package view (best effort) ------------------------------------
OPKG_BIN=""
for _op in /opt/bin/opkg /opt/sbin/opkg; do
    if [ -x "$_op" ]; then OPKG_BIN="$_op"; break; fi
done
if [ -z "$OPKG_BIN" ]; then
    emit UNKNOWN "opkg-view" "no executable opkg found at /opt/bin/opkg or /opt/sbin/opkg; package database state cannot be read"
else
    _opkg_status=$("$OPKG_BIN" status busybox 2>/dev/null) || _opkg_status=""
    case "$_opkg_status" in
        *"Status: install ok installed"*)
            emit PASS "opkg-view" "opkg readable; busybox is recorded as installed"
            ;;
        *)
            emit UNKNOWN "opkg-view" "opkg did not report busybox as 'install ok installed'; the package database may be damaged or mid-transaction"
            ;;
    esac
fi

# Parse exactly one installed OPKG record with shell builtins only.
# Do not rely on /opt-provided sed/head/grep while diagnosing broken BusyBox
# applets: ambiguous or missing metadata becomes UNKNOWN, never false PASS.
opkg_installed_version() {
    _oiv_name=$1
    _oiv_data=$2
    _oiv_package=''
    _oiv_version=''
    _oiv_state=''
    _oiv_package_count=0
    _oiv_version_count=0
    _oiv_state_count=0
    while IFS= read -r _oiv_line; do
        case "$_oiv_line" in
            'Package: '*)
                _oiv_package=${_oiv_line#'Package: '}
                _oiv_package_count=$((_oiv_package_count + 1)) ;;
            'Version: '*)
                _oiv_version=${_oiv_line#'Version: '}
                _oiv_version_count=$((_oiv_version_count + 1)) ;;
            'Status: '*)
                _oiv_state=${_oiv_line#'Status: '}
                _oiv_state_count=$((_oiv_state_count + 1)) ;;
        esac
    done <<EOF
$_oiv_data
EOF
    [ "$_oiv_package_count" -eq 1 ] || return 1
    [ "$_oiv_version_count" -eq 1 ] || return 1
    [ "$_oiv_state_count" -eq 1 ] || return 1
    [ "$_oiv_package" = "$_oiv_name" ] || return 1
    [ "$_oiv_state" = 'install ok installed' ] || return 1
    case "$_oiv_version" in
        ''|*[!A-Za-z0-9.~+-]*) return 1 ;;
    esac
    printf '%s\n' "$_oiv_version"
}

# --- 5b. curl/libcurl version skew (field bug #254) --------------------------
# The real Entware feed declares 'Depends: ..., libcurl' WITHOUT a version
# bound, so a selective 'opkg install curl' can upgrade the binary alone and
# leave an ABI-incompatible library (field 2026-11-17: curl 8.23.0-1 +
# libcurl 8.15.0-2 -> 'undefined symbol: curl_multi_get_offt').  Read-only
# comparison of the installed versions; repair stays a manual operator step.
if [ -z "$OPKG_BIN" ]; then
    emit UNKNOWN "curl-libcurl-skew" "opkg unavailable; curl/libcurl version skew cannot be checked"
else
    # Missing/incomplete opkg status is UNKNOWN, never an implicit PASS.
    # Keep the preflight read-only and independent of executing /opt/bin/curl.
    _curl_status=$("$OPKG_BIN" status curl 2>/dev/null) || _curl_status=""
    _libcurl_status=$("$OPKG_BIN" status libcurl 2>/dev/null) || _libcurl_status=""
    _curl_ver=$(opkg_installed_version curl "$_curl_status") || _curl_ver=''
    _libcurl_ver=$(opkg_installed_version libcurl "$_libcurl_status") || _libcurl_ver=''
    if [ -z "$_curl_ver" ] || [ -z "$_libcurl_ver" ]; then
        emit UNKNOWN "curl-libcurl-skew" "curl/libcurl installed-version metadata missing or incomplete; cannot establish version alignment"
    elif [ "$_curl_ver" != "$_libcurl_ver" ]; then
        emit FAIL "curl-libcurl-skew" "curl $_curl_ver vs libcurl $_libcurl_ver: unversioned feed dependency allowed a partial upgrade; downloads with this curl are unreliable — realign the libcurl package from the feed manually (see docs/32-entware-curl-libcurl-skew.md) before using KAS installers"
    else
        emit PASS "curl-libcurl-skew" "installed curl/libcurl package versions agree ($_curl_ver); this does not prove runtime ABI or HTTPS"
    fi
fi

# --- 6. poorbox fallback (informational, optional) --------------------------
if [ -x /opt/usr/bin/poorbox ] || { [ -L /opt/usr/bin/poorbox ] && [ -e /opt/usr/bin/poorbox ]; }; then
    emit PASS "poorbox-fallback" "/opt/usr/bin/poorbox present (limited historical fallback; not a full shell)"
fi

case "$RESULT_CODES" in
    0) exit 0 ;;
    1) exit 1 ;;
    *) exit 2 ;;
esac
