#!/bin/sh
# BEGIN MIHOMO LIFECYCLE LOCK v1
# Kept identical in standalone consumers (curl | sh needs no library).
# A short mkdir guard serializes ALL metadata changes, including stale recovery.
# Never steal this guard: a crash inside its tiny critical section fails closed.
# An operator may remove an abandoned guard only with maintenance stopped.
MIHOMO_LIFECYCLE_LOCK="/tmp/mihomo-lifecycle.lock.d"
MAINT_MARKER="/tmp/mihomo.maintenance"
ML_ID=""
ML_GATE=""
ML_MARKER=""
ML_LIFECYCLE_HELD=0

ml_starttime() {
    local data tail
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    data=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    # comm (field 2) may contain spaces and ')'; strip through its LAST ') '.
    tail=${data##*) }
    [ "$tail" != "$data" ] || return 1
    printf '%s\n' "$tail" | awk 'NF >= 20 && $20 ~ /^[0-9]+$/ { print $20; ok=1 } END { if (!ok) exit 1 }'
}

ml_identity() {
    local start
    [ -n "$ML_ID" ] && return 0
    start=$(ml_starttime "$$") || return 1
    ML_ID="$$ $start"
}

# 0 = live identity, 1 = proven stale, 2 = unknown (never steal).
ml_owner_state() {
    local pid start extra current
    IFS=' ' read -r pid start extra < "$1" || return 2
    case "$pid" in ''|0*|*[!0-9]*) return 2 ;; esac
    case "$start" in ''|*[!0-9]*) return 2 ;; esac
    [ -z "$extra" ] || return 2
    if current=$(ml_starttime "$pid"); then
        [ "$current" = "$start" ] && return 0
        return 1
    fi
    [ ! -d "/proc/$pid" ] && return 1
    return 2
}

ml_gate_enter() {
    [ -z "$ML_GATE" ] || return 1
    (umask 077; mkdir "$1.guard") 2>/dev/null || return 1
    ML_GATE="$1.guard"
}

ml_gate_leave() {
    [ -n "$ML_GATE" ] || return 0
    rmdir "$ML_GATE" 2>/dev/null || return 1
    ML_GATE=""
}

ml_lock_acquire() {
    local path state
    path=$1
    ml_identity || return 1
    ml_gate_enter "$path" || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ ! -d "$path" ] || [ -L "$path" ] || [ ! -f "$path/owner" ] || [ -L "$path/owner" ]; then
            ml_gate_leave
            return 1
        fi
        if ml_owner_state "$path/owner"; then state=0; else state=$?; fi
        if [ "$state" -ne 1 ]; then
            ml_gate_leave
            return 1
        fi
        # Under the guard no new owner can appear between inspect/remove/mkdir.
        if ! rm -f "$path/owner" || ! rmdir "$path"; then
            ml_gate_leave
            return 1
        fi
    fi
    if ! (umask 077; mkdir "$path"); then
        ml_gate_leave
        return 1
    fi
    if ! printf '%s\n' "$ML_ID" > "$path/owner"; then
        rm -f "$path/owner"
        rmdir "$path" 2>/dev/null || true
        ml_gate_leave
        return 1
    fi
    ml_gate_leave
}

ml_lock_release() {
    local path
    path=$1
    [ -n "$ML_ID" ] || return 0
    # A signal during metadata work may already own this short guard.
    if [ "$ML_GATE" != "$path.guard" ]; then
        ml_gate_enter "$path" || return 1
    fi
    if [ -d "$path" ] && [ ! -L "$path" ] && [ -f "$path/owner" ] &&
       [ ! -L "$path/owner" ] && [ "$(cat "$path/owner" 2>/dev/null)" = "$ML_ID" ]; then
        if [ "$path" = "$MIHOMO_LIFECYCLE_LOCK" ] && [ -n "$ML_MARKER" ] &&
           [ ! -L "$MAINT_MARKER" ] && [ -f "$MAINT_MARKER" ] &&
           [ "$(cat "$MAINT_MARKER" 2>/dev/null)" = "$ML_MARKER" ]; then
            rm -f "$MAINT_MARKER" || { ml_gate_leave; return 1; }
        fi
        rm -f "$path/owner" || { ml_gate_leave; return 1; }
        rmdir "$path" 2>/dev/null || { ml_gate_leave; return 1; }
    fi
    ml_gate_leave
}

# Old tools do not participate in this protocol. Never remove their lock files;
# require a quiescent handover. A PID-only live marker is conservatively busy.
ml_legacy_busy() {
    local path
    for path in /tmp/mihomo-update.lock /tmp/mihomo-update.lock.d \
        /tmp/mihomo-config-import.lock.d /tmp/mihomo-migrate.lock \
        /tmp/mihomo-migrate.lock.d /tmp/mihomo-tun-migrate.lock.d; do
        if [ -e "$path" ] || [ -L "$path" ]; then return 0; fi
    done
    return 1
}

ml_marker_busy() {
    local pid stamp start extra current
    [ -e "$MAINT_MARKER" ] || [ -L "$MAINT_MARKER" ] || return 1
    [ -f "$MAINT_MARKER" ] && [ ! -L "$MAINT_MARKER" ] || return 0
    IFS=' ' read -r pid stamp start extra < "$MAINT_MARKER" || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    if current=$(ml_starttime "$pid"); then
        case "$start" in ''|*[!0-9]*) return 0 ;; esac
        [ "$start" != "$current" ] && [ -z "$extra" ] && return 1
        return 0
    fi
    [ ! -d "/proc/$pid" ] && return 1
    return 0
}

ml_lifecycle_acquire() {
    ml_lock_acquire "$MIHOMO_LIFECYCLE_LOCK" || return 1
    ML_LIFECYCLE_HELD=1
    if ml_legacy_busy || ml_marker_busy; then
        ml_lifecycle_release
        return 1
    fi
    # First two fields remain compatible with older watchdogs.
    ML_MARKER="$$ $(date +%s) ${ML_ID#* }"
    if ! (umask 077; printf '%s\n' "$ML_MARKER" > "$MAINT_MARKER"); then
        ml_lifecycle_release
        return 1
    fi
    return 0
}

ml_lifecycle_release() {
    [ "$ML_LIFECYCLE_HELD" -eq 1 ] || return 0
    ml_lock_release "$MIHOMO_LIFECYCLE_LOCK" || return 1
    ML_LIFECYCLE_HELD=0
    ML_MARKER=""
}
# END MIHOMO LIFECYCLE LOCK v1

# Private implementation of uninstall.sh --remove. No rollback engine.
# Only creation-ledger claims with current exclusive-use evidence are actionable.

sr_safe() {
    local p
    p="$ROOT$1"
    while [ "$p" != / ] && [ -n "$p" ]; do
        [ ! -L "$p" ] || return 1
        p=${p%/*}
    done
}
sr_claim() { grep -Fqx "owned|$1|$2" "$ROOT/opt/etc/keenetic-auto-setup/ownership.v1"; }
sr_note() { SR_PLAN="$SR_PLAN
$1|$2|$3"; }
sr_file() {
    local kind name path hash actual
    kind=$1; name=$2; path=$3; hash=$4
    [ -e "$ROOT$path" ] || [ -L "$ROOT$path" ] || return 0
    if sr_claim "$kind" "$name" && sr_safe "$path" && [ -f "$ROOT$path" ]; then
        actual=$(sha256sum "$ROOT$path") || return 1
        [ "${actual%% *}" != "$hash" ] || { sr_note REMOVE "$path" verified; return 0; }
    fi
    sr_note LEFT "$path" 'unclaimed, modified or linked file'
}
# Names, exe and argv are ONLY negative evidence here: never authority to kill.
# Any unreadable userspace process prevents daemon/package/routing destruction.
sr_processes() {
    local p exe data tail flags cmd name
    SR_BUSY=0; SR_BUSY_REASON=none
    [ -r /proc/self/stat ] && [ -r /proc/mounts ] || { SR_BUSY=1; return; }
    if grep -Eq 'hidepid=([1-9]|invisible|noaccess)' /proc/mounts; then SR_BUSY=1; return; fi
    for p in /proc/[0-9]*; do
        [ -d "$p" ] || continue
        exe=$(readlink "$p/exe" 2>/dev/null) || exe=''
        data=$(cat "$p/stat" 2>/dev/null) || { [ ! -d "$p" ] || SR_BUSY=1; continue; }
        tail=${data##*) }
        case "$tail" in 'Z '*|'X '*) continue;; esac
        flags=$(printf '%s\n' "$tail" | awk '{print $7}')
        case "$flags" in ''|*[!0-9]*) SR_BUSY=1; continue;; esac
        [ $((flags & 2097152)) -eq 0 ] || continue
        [ -n "$exe" ] || { [ ! -d "$p" ] || { SR_BUSY=1; SR_BUSY_REASON=unreadable_executable; }; continue; }
        name=$(cat "$p/comm" 2>/dev/null) || { [ ! -d "$p" ] || { SR_BUSY=1; SR_BUSY_REASON=unreadable_name; }; continue; }
        case "$name|$exe" in *mihomo*|*magitrickle*) SR_BUSY=1; SR_BUSY_REASON=daemon_candidate;; esac
        for name in /opt/bin/mihomo /opt/sbin/mihomo /opt/bin/magitrickled /opt/sbin/magitrickled; do
            [ ! "$p/exe" -ef "$ROOT$name" ] || { SR_BUSY=1; SR_BUSY_REASON=executable_candidate; }
        done
        cmd=$(tr '\000' '\n' < "$p/cmdline" 2>/dev/null) || { [ ! -d "$p" ] || { SR_BUSY=1; SR_BUSY_REASON=unreadable_arguments; }; continue; }
        # init startup_loop is also a possible future launcher; never signal it.
        case "$cmd" in *S99mihomo*|*S99magitrickle*) SR_BUSY=1; SR_BUSY_REASON=init_candidate;; esac
    done
}
# A reference in another scheduled/init job means shared use. Never execute it.
sr_shared_job() {
    local file rc text
    for file in "$ROOT"/opt/etc/init.d/* "$ROOT"/opt/etc/cron.*/* "$ROOT"/opt/etc/crontab; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        sr_safe "${file#"$ROOT"}" && [ -f "$file" ] && [ -r "$file" ] || return 0
        case "$file" in
            */S99mihomo|*/S99magitrickle) continue;;
            */cron.5mins/mihomo_watchdog) [ "$SR_WATCH" -eq 1 ] && continue;;
        esac
        text=$(awk '!/^[[:space:]]*#/ {
            n=$0;gsub(/^[ \t]+|[ \t]+$/,"",n);gsub(/[ \t]+/," ",n)
            if(n!="*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog") print
        }' "$file") || return 0
        printf '%s\n' "$text" | grep -Eq 'mihomo|magitrickle' && return 0
    done
    return 1
}
# Existing Entware ENABLED=no disables only a byte-verified package init.
# These are the existing generic Mihomo/MagiTrickle and KN MagiTrickle scripts;
# version-modified scripts are retained, never executed or guessed by filename.
sr_init_known() {
    local digest
    sr_safe "$1" && [ -f "$ROOT$1" ] || return 1
    digest=$(sed 's/^ENABLED=no$/ENABLED=yes/' "$ROOT$1" | sha256sum) || return 1
    case "$1:${digest%% *}" in
        /opt/etc/init.d/S99mihomo:06ba8f6abe78a3b109d2037c902d826085d5a4814cf4b4aca0d135b22a7b86d9) return 0;;
        /opt/etc/init.d/S99magitrickle:31adca9a192f0ec8e5ef31d30ebe38dfd9364ebaec438cdd1ef64f15a9b891bf) return 0;;
        /opt/etc/init.d/S99magitrickle:ea80558c3818302c64b62e7cbdacfe818237af54e7d390ef2ab84d3cea49a81e) return 0;;
    esac
    return 1
}
sr_depends() {
    printf '%s\n' "$SR_STATUS" | awk -v pkg="$1" '
        BEGIN {RS=""; FS="\n"}
        {n="";deps=""; for(i=1;i<=NF;i++) {if($i~/^Package: /) n=substr($i,10); if($i~/^(Depends|Pre-Depends): /) deps=deps" "$i}
         if(n!=pkg && deps ~ ("(^|[ ,:|])"pkg"([ (,|]|$)")) shared=1}
        END {exit !shared}'
}
sr_collect() {
    SR_PLAN=''; SR_PROXY=''; SR_ROUTE=1; SR_NF=1; SR_WATCH=1; SR_PKG_OK=1; SR_SHARED=0
    SR_RC=$(ndmc -c 'show running-config' 2>/dev/null) || return 1
    SR_RC=$(printf '%s\n' "$SR_RC" | tr -d '\r')
    printf '%s\n' "$SR_RC" | grep -q '^interface ' || return 1
    SR_NAT=$(iptables -t mangle -S 2>/dev/null) || return 1
    SR_PKGS=$(opkg list-installed 2>/dev/null) || return 1
    SR_STATUS=$(opkg status 2>/dev/null) || return 1
    # OPKG must account for every installed package before dependency checks.
    for SR_PKG in $(printf '%s\n' "$SR_PKGS" | awk '{print $1}'); do
        case "$SR_PKG" in ''|*[!A-Za-z0-9+_.-]*) return 1;; esac
        printf '%s\n' "$SR_STATUS" | grep -Fqx "Package: $SR_PKG" || return 1
    done
    sr_processes
    [ "$SR_BUSY" -eq 0 ] || { SR_ROUTE=0; sr_note LEFT daemons 'running or uncertain process/launcher; no signals'; }
    # A different consumer of local 7890 shares the daemon and routing group.
    SR_PROXY=$(awk -F'|' '$2=="proxy" {print $3}' "$ROOT/opt/etc/keenetic-auto-setup/ownership.v1")
    case "$SR_PROXY" in ''|Proxy[0-9]) :;; *) SR_ROUTE=0; SR_SHARED=1;; esac
    if printf '%s\n' "$SR_RC" | awk -v px="$SR_PROXY" '
        /^interface / { i=$2 }
        /proxy upstream 127[.]0[.]0[.]1 7890/ && i!=px {found=1}
        END {exit !found}'; then SR_ROUTE=0; SR_SHARED=1; fi
    # Only canonical cron lines belong to the wrapper claim. Foreign consumers
    # keep the whole watchdog group; generic run-parts schedules stay unchanged.
    SR_CRON=''
    if [ -e "$ROOT/opt/etc/crontab" ] || [ -L "$ROOT/opt/etc/crontab" ]; then
        if sr_safe /opt/etc/crontab && [ -f "$ROOT/opt/etc/crontab" ]; then
            SR_CRON=$(cat "$ROOT/opt/etc/crontab") || return 1
            if printf '%s\n' "$SR_CRON" | awk '
                /^[[:space:]]*#/ {next}
                /mihomo_watchdog/ { n=$0; gsub(/^[ \t]+|[ \t]+$/,"",n); gsub(/[ \t]+/," ",n)
                  if(n!="*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog") bad=1 }
                END {exit !bad}'; then SR_WATCH=0; fi
        else SR_WATCH=0; fi
    fi
    if [ "$SR_WATCH" -eq 1 ]; then
        sr_file watchdog binary /opt/bin/mihomo_watchdog.sh 14611cd83b49a2e6848f0e11991cdcbced8e14748d138cf09eaeff6904360542 || return 1
        sr_file watchdog wrapper /opt/etc/cron.5mins/mihomo_watchdog c9822265cbf35db1c0a354f1384446c3b9cce4b2b53c9404ad9df8e1553306e0 || return 1
        if printf '%s\n' "$SR_PLAN" | grep -q '^LEFT|/opt/.*mihomo_watchdog'; then SR_WATCH=0; fi
    fi
    if [ "$SR_WATCH" -eq 0 ]; then
        SR_ROUTE=0; SR_SHARED=1
        SR_PLAN=$(printf '%s\n' "$SR_PLAN" | grep -v '^REMOVE|/opt/.*mihomo_watchdog' || :)
        sr_note LEFT watchdog 'modified/unclaimed files or foreign schedule; group retained'
    elif printf '%s\n' "$SR_CRON" | grep -q mihomo_watchdog; then
        if sr_claim watchdog wrapper; then sr_note REMOVE cron verified
        else SR_WATCH=0; SR_ROUTE=0; SR_SHARED=1; SR_PLAN=$(printf '%s\n' "$SR_PLAN" | grep -v '^REMOVE|/opt/.*mihomo_watchdog' || :); sr_note LEFT cron 'no wrapper ownership claim'; fi
    fi
    # Chain rules/references must ALL match the original hook, not just its name.
    if printf '%s\n' "$SR_NAT" | grep -q _CUST_BYPASS_WA_; then
        if ! sr_claim hook 020-bypass_wa.sh || ! printf '%s\n' "$SR_NAT" | awk '
            !/_CUST_BYPASS_WA_/ {next}
            $0=="-N _CUST_BYPASS_WA_" {next}
            $0=="-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_" {next}
            /^-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0x[0-9a-f]+\/0xffffffff$/ {next}
            /^-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j CONNMARK --save-mark( --nfmask 0xffffffff --ctmask 0xffffffff)?$/ {next}
            $0=="-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j RETURN" {next}
            {bad=1} END {exit bad}'; then SR_NF=0; SR_ROUTE=0; SR_SHARED=1
            sr_note LEFT netfilter 'unclaimed or foreign rules/references'
        else sr_note REMOVE netfilter verified; fi
    fi
    if [ "$SR_NF" -eq 1 ]; then
        sr_file hook 020-bypass_wa.sh /opt/etc/ndm/netfilter.d/020-bypass_wa.sh b36ae2308edd3f4a62a3c91cd698342a4bec9d8d9262aaba935b6b5232226a8c || return 1
        if printf '%s\n' "$SR_PLAN" | grep -q '^LEFT|/opt/etc/ndm'; then
            SR_NF=0; SR_ROUTE=0; SR_SHARED=1
            SR_PLAN=$(printf '%s\n' "$SR_PLAN" | grep -v '^REMOVE|netfilter|' || :)
        fi
    fi
    if printf '%s\n' "$SR_RC" | grep -q '^ip policy bypass_wa$'; then
        if sr_claim policy bypass_wa &&
           printf '%s\n' "$SR_RC" | awk -v px="$SR_PROXY" '
            /^ip policy bypass_wa$/ {c++; inpol=1; next}
            inpol && /^!$/ {inpol=0;next}
            inpol {
                if($0=="    description bypass_wa") d++
                else if($0=="    permit global "px) p++
                else if($0 ~ /^    no permit global [A-Za-z0-9_.-]+$/) {deny++; wan=$4}
                else bad=1
                next
            }
            /^interface / {ifaces[$2]=1}
            $1=="rename" {aliases[$2]++}
            /bypass_wa/ {bad=1}
            END {exit !(c==1 && d==1 && p==1 && deny<=1 && (!deny || ifaces[wan] || aliases[wan]==1) && !bad)}'; then sr_note REMOVE policy verified
        else SR_ROUTE=0; SR_SHARED=1; sr_note LEFT policy 'shared, modified, unclaimed or active consumer'; fi
    fi
    if [ -n "$SR_PROXY" ] && printf '%s\n' "$SR_RC" | grep -qx "interface $SR_PROXY"; then
        if printf '%s\n' "$SR_RC" | awk -v px="$SR_PROXY" '
            /^ip policy bypass_wa$/ {ownpol=1;next}
            ownpol && /^!$/ {ownpol=0;next}
            ownpol {if($0=="    permit global "px) next}
            $0=="interface "px {c++; inside=1;next}
            inside && /^!$/ {inside=0;next}
            inside {
                if($0=="    description \"mihomo t2s"substr(px,6)"\"") d++
                else if($0=="    proxy protocol socks5") s++
                else if($0=="    proxy upstream 127.0.0.1 7890") a++
                else if($0=="    proxy socks5-udp") u++
                else if($0=="    up" || $0=="    down") up++
                else if($0 ~ /^    ip global [1-9][0-9]*$/) g++
                else if($0!="    security-level public") bad=1
                next
            }
            index($0,px) {bad=1}
            END {exit !(c==1 && d==1 && s==1 && a==1 && u==1 && up==1 && g==1 && !bad)}'; then sr_note REMOVE "$SR_PROXY" verified
        else SR_ROUTE=0; SR_SHARED=1; sr_note LEFT "$SR_PROXY" 'shared, modified or active consumer'; fi
    fi
    for SR_PKG in mihomo magitrickle; do
        SR_INIT="/opt/etc/init.d/S99$SR_PKG"
        [ -e "$ROOT$SR_INIT" ] || [ -L "$ROOT$SR_INIT" ] || continue
        if [ "$SR_SHARED" -eq 0 ] && sr_claim package "$SR_PKG" && sr_init_known "$SR_INIT" && ! sr_shared_job && ! sr_depends "$SR_PKG"; then
            if grep -qx ENABLED=yes "$ROOT$SR_INIT"; then sr_note REMOVE "$SR_INIT" 'disable autostart only; no signals'
            else sr_note PRESERVED "$SR_INIT" 'autostart already disabled'; fi
        else SR_PKG_OK=0; SR_ROUTE=0; SR_SHARED=1; sr_note LEFT "$SR_INIT" 'unclaimed, modified or shared init'; fi
    done
    # If the proxy is shared, retain its policy too (dependency order).
    if [ "$SR_ROUTE" -eq 0 ]; then
        SR_PLAN=$(printf '%s\n' "$SR_PLAN" | awk -F'|' 'BEGIN {OFS="|"} $1=="REMOVE" && ($2=="policy" || $2~/^Proxy[0-9]+$/) {$1="LEFT";$3="active, shared or uncertain routing consumer"} {print}')
    fi
    for SR_PKG in magitrickle mihomo; do
        printf '%s\n' "$SR_PKGS" | grep -q "^$SR_PKG " || continue
        if sr_claim package "$SR_PKG" && [ "$SR_BUSY" -eq 0 ] && [ "$SR_ROUTE" -eq 1 ] && [ "$SR_PKG_OK" -eq 1 ] &&
           ! sr_depends "$SR_PKG" &&
           ! sr_shared_job; then
            sr_note REMOVE "opkg/$SR_PKG" 'owned; no known active/shared consumer'
        else sr_note LEFT "opkg/$SR_PKG" 'unclaimed, running, shared or uncertain consumer'; fi
    done
    for SR_PATH in /opt/etc/opkg/magitrickle.conf /opt/etc/init.d/S00ubifs /opt/etc/keenetic-auto-setup-mihomo.state; do
        [ ! -e "$ROOT$SR_PATH" ] && [ ! -L "$ROOT$SR_PATH" ] || sr_note LEFT "$SR_PATH" 'shared protection, feed or provenance metadata; preserved'
    done
    return 0
}
sr_has() { printf '%s\n' "$SR_PLAN" | grep -Fqx "REMOVE|$1|$2"; }
sr_summary() {
    printf '%s\n' "$SR_PLAN" | while IFS='|' read -r action item why; do
        case "$why" in 'disable autostart only;'*) action=DISABLE;; esac
        [ -n "$action" ] && printf '[%s] %s — %s\n' "$action" "$item" "$why"
    done
    printf '[PRESERVED] user YAML, DNS interception, unrelated resources and creation ledger\n'
}
sr_cleanup() {
    local p
    if [ -n "$SR_YAML" ]; then
        for p in etc/mihomo/config.yaml var/lib/magitrickle/config.yaml; do
            [ -f "$SR_YAML/$p" ] || continue
            if sr_safe "/opt/$p" && [ ! -e "$ROOT/opt/$p" ] && [ ! -L "$ROOT/opt/$p" ]; then
                mkdir -p "$ROOT/opt/${p%/*}" && cp -p "$SR_YAML/$p" "$ROOT/opt/$p" || SR_RESTORE=1
            fi
            if cmp -s "$SR_YAML/$p" "$ROOT/opt/$p"; then rm -f "$SR_YAML/$p"; else SR_RESTORE=1; fi
        done
        if [ "$SR_RESTORE" -eq 0 ]; then
            rmdir "$SR_YAML/etc/mihomo" "$SR_YAML/etc" "$SR_YAML/var/lib/magitrickle" "$SR_YAML/var/lib" "$SR_YAML/var" "$SR_YAML" 2>/dev/null || :
            SR_YAML=''
        else printf '[LEFT] YAML safety copy: %s (restore failed or concurrent edit)\n' "$SR_YAML" >&2; fi
    fi
    ml_lifecycle_release || SR_CLEAN=1
    [ "$SR_WD_HELD" -eq 0 ] || { ml_lock_release "$SR_WD" || SR_CLEAN=1; SR_WD_HELD=0; }
}
sr_error() {
    printf '[ERROR] %s; subsequent steps left untouched.\n' "$1" >&2
    # Emit the unattempted plan as LEFT; no implicit resume or retry.
    SR_PLAN=$(printf '%s\n' "$SR_PLAN" | sed 's/^REMOVE|/LEFT|/')
    sr_cleanup
    sr_summary
    if [ "$SR_CHANGED" -eq 0 ]; then printf '[BLOCKED] No removal completed.\n'; exit 3; fi
    printf '[PARTIAL] Removal interrupted; inspect remaining components above.\n'; exit 1
}
sr_done() {
    SR_CHANGED=1
    SR_PLAN=$(printf '%s\n' "$SR_PLAN" | awk -F'|' -v key="$1" -v status="${2:-REMOVED}" 'BEGIN {OFS="|"} $1=="REMOVE" && $2==key {$1=status;$3="completed"} {print}' )
}
simple_remove_main() {
    SR_CHANGED=0; SR_YAML=''; SR_RESTORE=0; SR_CLEAN=0; SR_WD_HELD=0
    if [ -n "$ROOT" ]; then
        case "$ROOT" in /tmp/kas-simple-remove-*/root) :;; *) printf '[BLOCKED] --remove: fixture is read-only.\n' >&2; return 3;; esac
        [ "$(cd "$ROOT" 2>/dev/null && pwd -P)" = "$ROOT" ] && sr_safe /.kas-uninstall-fixture &&
        [ "$(cat "$ROOT/.kas-uninstall-fixture" 2>/dev/null)" = KAS_SIMPLE_REMOVE_TEST_V1 ] ||
            { printf '[BLOCKED] --remove: invalid fixture authorization.\n' >&2; return 3; }
    elif [ "$(id -u)" != 0 ]; then
        printf '[BLOCKED] --remove requires root.\n' >&2; return 3
    fi
    [ "$LEDGER_VALID" -eq 1 ] && sr_safe /opt/etc/keenetic-auto-setup/ownership.v1 ||
        { printf '[BLOCKED] No valid safe ownership ledger; all components left untouched.\n' >&2; return 3; }
    SR_WD="$ROOT/tmp/mihomo_watchdog.lock.d"
    MIHOMO_LIFECYCLE_LOCK="$ROOT/tmp/mihomo-lifecycle.lock.d"
    MAINT_MARKER="$ROOT/tmp/mihomo.maintenance"
    sr_safe /tmp/mihomo_watchdog.lock.d && sr_safe /tmp/mihomo-lifecycle.lock.d && sr_safe /tmp/mihomo.maintenance ||
        { printf '[BLOCKED] Unsafe lock path.\n' >&2; return 3; }
    sr_collect || { printf '[BLOCKED] Inventory incomplete; no changes.\n' >&2; return 3; }
    printf 'KAS --remove: irreversible removal of verified own resources below. Network access may change.\nNo system rollback; user YAML and shared/unknown components stay.\n'
    sr_summary
    if ! printf '%s\n' "$SR_PLAN" | grep -q '^REMOVE|'; then
        if printf '%s\n' "$SR_PLAN" | grep -q '^LEFT|'; then printf '[PARTIAL] Nothing safely removable.\n'; return 1; fi
        printf '[SUCCESS] No remaining actionable KAS components.\n'; return 0
    fi
    printf 'Type REMOVE to confirm: '
    IFS= read -r SR_ANSWER || SR_ANSWER=''
    [ "$SR_ANSWER" = REMOVE ] || { printf '[BLOCKED] Cancelled; no changes.\n'; return 3; }
    SR_BEFORE="$SR_PLAN"; SR_RC_BEFORE="$SR_RC"; SR_NAT_BEFORE="$SR_NAT"; SR_CRON_BEFORE="$SR_CRON"
    SR_LEDGER_BEFORE=$(cat "$ROOT/opt/etc/keenetic-auto-setup/ownership.v1") || return 3
    trap 'sr_cleanup' 0
    trap 'sr_error "signal received"' HUP INT TERM
    ml_lock_acquire "$SR_WD" || { printf '[BLOCKED] Watchdog busy; nothing removed.\n' >&2; return 3; }
    SR_WD_HELD=1
    ml_lifecycle_acquire || { printf '[BLOCKED] Lifecycle busy; nothing removed.\n' >&2; sr_cleanup; return 3; }
    sr_collect || sr_error 'locked inventory failed'
    [ "$SR_PLAN" = "$SR_BEFORE" ] && [ "$SR_RC" = "$SR_RC_BEFORE" ] && [ "$SR_NAT" = "$SR_NAT_BEFORE" ] &&
    [ "$SR_CRON" = "$SR_CRON_BEFORE" ] && [ "$(cat "$ROOT/opt/etc/keenetic-auto-setup/ownership.v1")" = "$SR_LEDGER_BEFORE" ] || sr_error 'inventory changed since confirmation'
    for SR_PKG in mihomo magitrickle; do
        SR_INIT="/opt/etc/init.d/S99$SR_PKG"
        if sr_has "$SR_INIT" 'disable autostart only; no signals'; then
            sr_init_known "$SR_INIT" || sr_error 'init changed; autostart untouched'
            SR_TMP=$(mktemp "$ROOT/opt/etc/init.d/.kas-init.XXXXXX") || sr_error 'cannot stage init'
            SR_CHANGED=1
            cp -p "$ROOT$SR_INIT" "$SR_TMP" && sed 's/^ENABLED=yes$/ENABLED=no/' "$ROOT$SR_INIT" > "$SR_TMP" &&
            mv "$SR_TMP" "$ROOT$SR_INIT" || { rm -f "$SR_TMP"; sr_error 'cannot disable owned init'; }
            sr_done "$SR_INIT" DISABLED
        fi
    done
    # Disable the owned restart sources before removing routes/packages.
    if sr_has cron verified; then
        SR_TMP=$(mktemp "$ROOT/opt/etc/.kas-cron.XXXXXX") || sr_error 'cannot stage crontab'
        SR_CHANGED=1
        cp -p "$ROOT/opt/etc/crontab" "$SR_TMP" &&
        awk '{n=$0;gsub(/^[ \t]+|[ \t]+$/,"",n);gsub(/[ \t]+/," ",n); if(n!="*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog") print}' "$ROOT/opt/etc/crontab" > "$SR_TMP" &&
        mv "$SR_TMP" "$ROOT/opt/etc/crontab" || { rm -f "$SR_TMP"; sr_error 'cannot update crontab'; }
        sr_done cron
    fi
    for SR_PATH in /opt/etc/cron.5mins/mihomo_watchdog /opt/bin/mihomo_watchdog.sh /opt/etc/ndm/netfilter.d/020-bypass_wa.sh; do
        if sr_has "$SR_PATH" verified; then
            SR_CHANGED=1
            sr_safe "$SR_PATH" && rm -f "$ROOT$SR_PATH" || sr_error 'cannot remove verified file'
            sr_done "$SR_PATH"
        fi
    done
    if sr_has netfilter verified; then
        SR_CHANGED=1
        set -f
        while IFS= read -r SR_RULE; do
            case "$SR_RULE" in '-A '*_CUST_BYPASS_WA_*)
                # Every token was allowlisted by sr_collect; never eval.
                iptables -t mangle $(printf '%s\n' "$SR_RULE" | sed 's/^-A /-D /') >/dev/null 2>&1 || sr_error 'netfilter deletion failed';;
            esac
        done <<_SR_RULES
$SR_NAT
_SR_RULES
        set +f
        iptables -t mangle -X _CUST_BYPASS_WA_ >/dev/null 2>&1 || sr_error 'netfilter chain removal failed'
        sr_done netfilter
    fi
    for SR_ITEM in policy "$SR_PROXY"; do
        [ -n "$SR_ITEM" ] || continue
        if sr_has "$SR_ITEM" verified; then
            sr_processes; [ "$SR_BUSY" -eq 0 ] || sr_error 'process appeared; routing/package steps retained'
            if [ "$SR_ITEM" = policy ]; then SR_CMD='no ip policy bypass_wa'; else SR_CMD="no interface $SR_ITEM"; fi
            # A command failure may still have changed state: PARTIAL, never retry.
            SR_CHANGED=1
            ndmc -c "$SR_CMD" >/dev/null 2>&1 || sr_error 'routing deletion failed'
            SR_NOW=$(ndmc -c 'show running-config' 2>/dev/null) || sr_error 'routing verification unreadable'
            printf '%s\n' "$SR_NOW" | grep -q '^interface ' || sr_error 'routing verification invalid'
            if [ "$SR_ITEM" = policy ]; then SR_PATTERN='^ip policy bypass_wa$'; else SR_PATTERN="^interface $SR_ITEM$"; fi
            printf '%s\n' "$SR_NOW" | tr -d '\r' | grep -q "$SR_PATTERN" && sr_error 'routing resource still present'
            ndmc -c 'system configuration save' >/dev/null 2>&1 || sr_error 'configuration save failed'
            sr_done "$SR_ITEM"
        fi
    done
    for SR_PKG in magitrickle mihomo; do
        if sr_has "opkg/$SR_PKG" 'owned; no known active/shared consumer'; then
            sr_processes; [ "$SR_BUSY" -eq 0 ] || sr_error "process appeared ($SR_BUSY_REASON); packages retained"
            if [ -z "$SR_YAML" ]; then
                SR_YAML=$(mktemp -d "$ROOT/tmp/kas-yaml.XXXXXX") || sr_error 'cannot protect YAML'
                for SR_REL in etc/mihomo/config.yaml var/lib/magitrickle/config.yaml; do
                    sr_safe "/opt/$SR_REL" || sr_error 'unsafe YAML path; packages retained'
                    mkdir -p "$SR_YAML/${SR_REL%/*}" || sr_error 'cannot protect YAML directory'
                    if [ -e "$ROOT/opt/$SR_REL" ]; then
                        [ -f "$ROOT/opt/$SR_REL" ] && cp -p "$ROOT/opt/$SR_REL" "$SR_YAML/$SR_REL" && cmp -s "$ROOT/opt/$SR_REL" "$SR_YAML/$SR_REL" || sr_error 'cannot protect YAML contents'
                    fi
                done
            fi
            SR_CHANGED=1
            opkg remove "$SR_PKG" >/dev/null 2>&1 || sr_error 'package manager refused removal'
            SR_NOW=$(opkg list-installed 2>/dev/null) || sr_error 'package verification failed'
            printf '%s\n' "$SR_NOW" | grep -q "^$SR_PKG " && sr_error 'package still installed'
            sr_done "opkg/$SR_PKG"
        fi
    done
    sr_cleanup
    [ "$SR_RESTORE" -eq 0 ] && [ "$SR_CLEAN" -eq 0 ] || sr_error 'YAML or lock cleanup incomplete'
    sr_summary
    if printf '%s\n' "$SR_PLAN" | grep -q '^LEFT|'; then printf '[PARTIAL] Safe subset removed; retained components listed above.\n'; return 1; fi
    printf '[SUCCESS] Available exclusively owned KAS components removed.\n'; return 0
}
