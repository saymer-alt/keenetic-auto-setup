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
    # Some native opkg builds return no record for 'status busybox' even
    # when their list-installed database reports a single installed busybox.
    # Only fall back when status output is entirely empty. An explicit status
    # record lacking 'install ok installed' may indicate a half-configured
    # package and MUST remain UNKNOWN, even if list-installed has an entry.
    _opkg_status_ok=1
    _opkg_status=$("$OPKG_BIN" status busybox 2>/dev/null) || _opkg_status_ok=0
    if [ "$_opkg_status_ok" -ne 1 ]; then
        emit UNKNOWN "opkg-view" "opkg status command failed; do not accept list-installed as proof of package database health"
    else
        case "$_opkg_status" in
        *"Status: install ok installed"*)
            emit PASS "opkg-view" "opkg status confirms busybox installed"
            ;;
        "")
            _opkg_list_ok=1
            _opkg_list=$("$OPKG_BIN" list-installed 2>/dev/null) || _opkg_list_ok=0
            _opkg_busybox_rows=0
            if [ "$_opkg_list_ok" -eq 1 ]; then
                # Read with shell builtins only: the missing-applet case must
                # not depend on /opt/bin/grep, awk, sed, cut, or wc.
                while IFS= read -r _opkg_line; do
                    case "$_opkg_line" in
                        "busybox - "?*)
                            _opkg_busybox_rows=$((_opkg_busybox_rows + 1))
                            ;;
                        "busybox - ")
                            # Invalid empty version cannot establish installed state.
                            _opkg_busybox_rows=2
                            ;;
                    esac
                done <<OPKG_BUSYBOX_INVENTORY
$_opkg_list
OPKG_BUSYBOX_INVENTORY
            fi
            if [ "$_opkg_list_ok" -eq 1 ] && [ "$_opkg_busybox_rows" -eq 1 ]; then
                emit PASS "opkg-view" "opkg status returned no record; list-installed confirms one busybox entry (limited package-view evidence)"
            else
                emit UNKNOWN "opkg-view" "opkg status returned no record and list-installed did not confirm exactly one installed busybox entry; inspect package database manually"
            fi
            ;;
        *)
            emit UNKNOWN "opkg-view" "opkg status returned an ambiguous/non-installed record for busybox; package database may be damaged or mid-transaction, do not override using list-installed"
            ;;
        esac
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
