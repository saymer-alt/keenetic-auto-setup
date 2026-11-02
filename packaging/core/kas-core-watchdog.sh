#!/bin/sh
# Explicit KAS core watchdog activation/status. Never called automatically by IPK.
# jq is an existing KAS dependency. No network or arbitrary command interface.
set -eu
umask 077
BUNDLE=/opt/libexec/kas
META=/opt/share/kas-core
INFO=/opt/lib/opkg/info
STATE=/opt/etc/kas-core
RECEIPT="$STATE/watchdog.json"
CANONICAL=/opt/bin/mihomo_watchdog.sh
fail() { echo "KAS_CORE_WATCHDOG: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail 'use status or apply'
case "$1" in status|apply) action=$1;; *) fail 'unsupported action';; esac
[ "$(id -u)" = 0 ] || fail 'root required'
command -v jq >/dev/null 2>&1 || fail 'jq unavailable'
regular() {
    local file parent physical listing
    file=$1
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    [ "$(wc -c < "$file")" -le "$2" ] || return 1
    parent=${file%/*}
    physical=$(CDPATH= cd -- "$parent" 2>/dev/null && pwd -P) || return 1
    [ "$physical" = "$parent" ] || return 1
    listing=$(LC_ALL=C ls -ldn "$file") || return 1
    set -- $listing
    [ "$3" = 0 ] && [ "$4" = 0 ] || return 1
    case "$1" in -rw-------|-rw-r--r--|-rwxr-xr-x) ;; *) return 1;; esac
}
safe_directory() {
    local directory physical listing
    directory=$1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    physical=$(CDPATH= cd -- "$directory" 2>/dev/null && pwd -P) || return 1
    [ "$physical" = "$directory" ] || return 1
    listing=$(LC_ALL=C ls -ldn "$directory") || return 1
    set -- $listing
    [ "$3" = 0 ] && [ "$4" = 0 ] || return 1
    case "$1" in d????w????|d???????w?) return 1;; esac
}
file_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
load_bundle() {
    local directory file manifest
for directory in "$BUNDLE" "$META" "$INFO" /opt /opt/etc /opt/lib /opt/libexec /opt/share /opt/lib/opkg; do
    safe_directory "$directory" || fail 'unsafe package directory'
done
for file in "$INFO/kas-core.list" "$INFO/kas-core.md5sums" "$META/scripts.json" "$META/SHA256SUMS" "$META/watchdog-history.tsv"; do
    regular "$file" 65536 || fail 'unsafe or missing package metadata'
done
grep -Fxq "$BUNDLE/kas-core-watchdog.sh" "$INFO/kas-core.list" || fail 'tool is not package-owned'
(cd / && md5sum -c "$INFO/kas-core.md5sums" >/dev/null 2>&1 && sha256sum -c "$META/SHA256SUMS" >/dev/null 2>&1) || fail 'package integrity mismatch'
manifest=$(cat "$META/scripts.json")
printf '%s\n' "$manifest" | jq -e '
 .schema == 1 and (.version|type == "string" and test("^[0-9][A-Za-z0-9.+~-]{0,63}$")) and
 (.source_sha|type == "string" and test("^[a-f0-9]{40}$")) and
 (.watchdog_catalogue_sha256|type == "string" and test("^[a-f0-9]{64}$")) and
 ([.scripts[]|select(.name == "mihomo-watchdog.sh")]|length == 1) and
 ([.scripts[]|select(.name == "update-watchdog.sh")]|length == 1)' >/dev/null 2>&1 || fail 'invalid package manifest'
version=$(printf '%s\n' "$manifest" | jq -er '.version')
source_sha=$(printf '%s\n' "$manifest" | jq -er '.source_sha')
candidate_sha=$(printf '%s\n' "$manifest" | jq -er '.scripts[]|select(.name == "mihomo-watchdog.sh")|.sha256|select(test("^[a-f0-9]{64}$"))')
updater_sha=$(printf '%s\n' "$manifest" | jq -er '.scripts[]|select(.name == "update-watchdog.sh")|.sha256|select(test("^[a-f0-9]{64}$"))')
catalogue_sha=$(printf '%s\n' "$manifest" | jq -er '.watchdog_catalogue_sha256')
catalogue=$(cat "$META/watchdog-history.tsv")
[ "$(printf '%s\n' "$catalogue" | sha256sum | awk '{print $1}')" = "$catalogue_sha" ] || fail 'catalogue mismatch'
printf '%s\n' "$catalogue" | awk -F '\t' 'NF != 2 || length($1) != 64 || $1 ~ /[^a-f0-9]/ || length($2) != 40 || $2 ~ /[^a-f0-9]/ || seen[$1]++ {bad=1} END {exit bad || NR == 0}' || fail 'invalid catalogue'
regular "$BUNDLE/mihomo-watchdog.sh" 262144 && regular "$BUNDLE/update-watchdog.sh" 262144 || fail 'unsafe package scripts'
[ "$(file_sha "$BUNDLE/mihomo-watchdog.sh")" = "$candidate_sha" ] &&
    [ "$(file_sha "$BUNDLE/update-watchdog.sh")" = "$updater_sha" ] || fail 'script identity mismatch'
}

read_receipt() {
    record_version=""; record_source=""; record_sha=""; receipt_valid=1
    if [ -e "$STATE" ] || [ -L "$STATE" ]; then
        safe_directory "$STATE" || { receipt_valid=0; return; }
        [ "$(LC_ALL=C ls -ldn "$STATE" | awk '{print $1}')" = drwx------ ] || { receipt_valid=0; return; }
    fi
    if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
        regular "$RECEIPT" 4096 &&
            [ "$(LC_ALL=C ls -ldn "$RECEIPT" | awk '{print $1}')" = -rw------- ] || { receipt_valid=0; return; }
        jq -e '.schema == 1 and .component == "watchdog" and
          (.bundle_version|type == "string" and test("^[0-9][A-Za-z0-9.+~-]{0,63}$")) and
          (.source_sha|type == "string" and test("^[a-f0-9]{40}$")) and
          (.watchdog_sha256|type == "string" and test("^[a-f0-9]{64}$"))' "$RECEIPT" >/dev/null 2>&1 || { receipt_valid=0; return; }
        record_version=$(jq -er '.bundle_version' "$RECEIPT")
        record_source=$(jq -er '.source_sha' "$RECEIPT")
        record_sha=$(jq -er '.watchdog_sha256' "$RECEIPT")
    fi
}
inspect() {
    installed_sha=""
    if regular "$CANONICAL" 262144; then installed_sha=$(file_sha "$CANONICAL"); fi
    recognized=false
    if [ -n "$installed_sha" ] && printf '%s\n' "$catalogue" | awk -F '\t' -v digest="$installed_sha" '$1 == digest {found=1} END {exit !found}'; then recognized=true; fi
    read_receipt
    result_state=unrecorded
    if [ "$receipt_valid" -ne 1 ]; then result_state=invalid_receipt
    elif [ -n "$record_sha" ]; then
        if [ "$record_sha" != "$installed_sha" ]; then result_state=stale
        elif [ "$record_version" != "$version" ] || [ "$record_source" != "$source_sha" ]; then result_state=bundle_changed
        elif [ "$installed_sha" != "$candidate_sha" ]; then result_state=stale
        else result_state=current; fi
    fi
}
emit() {
    jq -nc --arg state "$result_state" --argjson recognized "$recognized" \
        --arg version "$version" --arg source "$source_sha" --arg installed "$installed_sha" \
        --arg candidate "$candidate_sha" --arg recorded "$record_version" \
        '{schema:1,component:"watchdog",state:$state,recognized:$recognized,bundle_version:$version,source_sha:$source,installed_sha256:$installed,candidate_sha256:$candidate,recorded_version:$recorded}'
}
load_bundle
inspect
if [ "$action" = status ]; then emit; exit 0; fi
[ "$receipt_valid" -eq 1 ] || fail 'unsafe or invalid existing receipt; preserved'
[ "$recognized" = true ] || fail 'unrecognized installed watchdog; preserved'
if [ ! -d "$STATE" ]; then mkdir -m 700 "$STATE" || fail 'cannot create private state directory'; fi
safe_directory "$STATE" || fail 'unsafe state directory'
lock="$STATE/.watchdog-activation.lock"
mkdir "$lock" 2>/dev/null || fail 'activation busy; inspect stale lock manually'
work=""
cleanup() {
    trap '' HUP INT TERM
    [ -z "$work" ] || rm -rf "$work"
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'trap "" HUP INT TERM; cleanup; exit 130' INT
trap 'trap "" HUP INT TERM; cleanup; exit 143' TERM
trap 'trap "" HUP INT TERM; cleanup; exit 129' HUP
load_bundle
inspect
[ "$receipt_valid" -eq 1 ] && [ "$recognized" = true ] || fail 'installed file or receipt changed before activation'
if [ "$result_state" = current ]; then emit; exit 0; fi
work=$(mktemp -d "$STATE/.watchdog-activation.XXXXXX") || fail 'cannot stage activation'
# Pin the executable input to the manifest we validated. Package upgrades may
# replace bundle paths, so never invoke a subsequently opened unverified updater.
cp "$BUNDLE/update-watchdog.sh" "$work/updater.sh"
cp "$BUNDLE/mihomo-watchdog.sh" "$work/candidate.sh"
chmod 600 "$work/updater.sh" "$work/candidate.sh"
[ "$(file_sha "$work/updater.sh")" = "$updater_sha" ] &&
    [ "$(file_sha "$work/candidate.sh")" = "$candidate_sha" ] || fail 'package changed while staging'
jq -nc --arg version "$version" --arg source "$source_sha" --arg digest "$candidate_sha" \
    '{schema:1,component:"watchdog",bundle_version:$version,source_sha:$source,watchdog_sha256:$digest}' > "$work/receipt.new"
chmod 600 "$work/receipt.new"
sh "$work/updater.sh" --package-candidate "$work/candidate.sh" "$candidate_sha" "$installed_sha" >&2 || fail 'updater failed; previous receipt retained'
[ "$(file_sha "$CANONICAL")" = "$candidate_sha" ] || fail 'canonical file changed after updater'
read_receipt
[ "$receipt_valid" -eq 1 ] || fail 'receipt changed during activation; preserved'
mv -f "$work/receipt.new" "$RECEIPT" || fail 'receipt commit failed; watchdog may already be applied, inspect status'
load_bundle
inspect
if [ "$result_state" != current ]; then emit; fail 'bundle or canonical file changed during activation; inspect status'; fi
emit
