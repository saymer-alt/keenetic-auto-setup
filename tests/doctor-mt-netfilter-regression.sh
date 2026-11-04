#!/bin/sh
# Offline regression: extract and exercise the real Doctor MagiTrickle group
# semantics and effective-netfilter blocks (issue #327).
# No router, no real firewall, no privileges: iptables/ipset/ip are stubbed
# functions inside a disposable runner; every mutation-free code path is
# checked against sanitized synthetic fixtures.
set -eu
ROOT=${1:-.}
DOCTOR="$ROOT/mihomo-doctor.sh"
TMP="${TMPDIR:-/tmp}/doctor-mt-netfilter.$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
fail_test() { echo "[FAIL] $1" >&2; exit 1; }

awk '/# BEGIN DOCTOR MT GROUP ANALYSIS v1/ { on=1 } on { print } /# END DOCTOR MT GROUP ANALYSIS v1/ { exit }' "$DOCTOR" > "$TMP/groups.sh"
awk '/# BEGIN DOCTOR MT NETFILTER EFFECTIVE v1/ { on=1 } on { print } /# END DOCTOR MT NETFILTER EFFECTIVE v1/ { exit }' "$DOCTOR" > "$TMP/effective.sh"
grep -q '^ *MT_GROUP_ANALYSIS=' "$TMP/groups.sh" || fail_test 'missing group analysis parser'
grep -q '^ *MT_EFF_READY=' "$TMP/effective.sh" || fail_test 'missing effective netfilter block'
sh -n "$TMP/groups.sh"; sh -n "$TMP/effective.sh"

cat > "$TMP/runner.sh" <<'SH'
#!/bin/sh
set -eu
# args: fixture.yaml loaded_procs disableRemap53 mode
MT_CFG=$1
MT_PROCS=$2
MT_REMAP=$3
MTTEST_MODE=$4
MT_LINK=""
MT_CHAIN="MT_"
MT_IPSET_PREFIX="mt_"
MT_DNS_PORT=3553
info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
case "$MTTEST_MODE" in
clean)
    iptables() {
        case "$2" in
            mangle) printf -- '-P PREROUTING ACCEPT\n-N MT_DNSOR\n-N MT_SET0\n-A MT_SET0 -m set --match-set mt_test dst -j MARK --set-mark 0x4d61676f\n' ;;
            nat)    printf -- '-P PREROUTING ACCEPT\n-A PREROUTING -d 192.168.1.1/32 -p udp -m udp --dport 53 -j DNAT --to-destination 192.168.1.1:3553\n' ;;
        esac
        return 0
    }
    ipset() { printf 'mt_test\nmt_other\nfoo0\n'; }
    ip() {
        # invoked as: ip rule show / ip route show table all
        case "$1" in
            rule)  printf '0: from all lookup local\n32765: from all fwmark 0x4d61676f lookup 100\n' ;;
            route) printf 'default dev mitun0 table 100\n' ;;
        esac
    }
    ;;
busy)
    iptables() { return 1; }
    ;;
absent)
    # POSIX-legal shadow of the command builtin: every command -v probe in
    # the extracted block reports the tool as unavailable.
    command() { return 1; }
    ;;
esac
. "$TMP_DIR/groups.sh"
. "$TMP_DIR/effective.sh"
SH

run_mode() {
  _fixture=$1; _procs=$2; _remap=$3; _mode=$4
  TMP_DIR="$TMP" sh "$TMP/runner.sh" "$_fixture" "$_procs" "$_remap" "$_mode"
}

# --- A: SE-like fixture (LF): effective telegram rule, no broad catch-all ---
cat > "$TMP/se.yaml" <<'YAML'
configVersion: 7
groups:
- id: 1
  interface: mitun0
  enable: true
  rules:
  - id: 11
    type: namespace
    rule: 2ip.io
    enable: true
  - id: 12
    type: subnet
    rule: 149.154.167.0/24
    enable: true
- id: 2
  interface: mitun0
  enable: true
  rules:
  - id: 21
    type: domain
    rule: api.telegram.org
    enable: true
- id: 3
  interface: mitun0
  enable: false
  rules:
  - id: 31
    type: regex
    rule: .*\.com
    enable: true
YAML
out=$(run_mode "$TMP/se.yaml" 1 false clean)
printf '%s\n' "$out" | grep -Fq 'enabled rules 3 (subnet 1) in enabled groups 2/3' || fail_test 'SE counts wrong'
printf '%s\n' "$out" | grep -Fq 'telegram group enabled=yes, effective telegram rules=1 (subnet 0)' || fail_test 'SE telegram facts wrong'
printf '%s\n' "$out" | grep -Fq 'broad catch-all regex rule present' && fail_test 'disabled-group regex must not warn'
printf '%s\n' "$out" | grep -Fq 'chains=2' || fail_test 'effective chains count wrong'
printf '%s\n' "$out" | grep -Fq 'ipset-match rules=1' || fail_test 'effective set rules wrong'
printf '%s\n' "$out" | grep -Fq 'nat dport53-DNAT:3553=1' || fail_test 'effective dnat wrong'
printf '%s\n' "$out" | grep -Fq 'ipsets=2' || fail_test 'effective ipsets wrong'
printf '%s\n' "$out" | grep -Fq 'fwmark rules=1' || fail_test 'effective fwmark wrong'
printf '%s\n' "$out" | grep -Fq 'mitun0 routes=1' || fail_test 'effective routes wrong'
printf '%s\n' "$out" | grep -Eq '^\[WARN\]' && fail_test 'clean healthy state must not warn'


# --- A2: a named Telegram group owns its enabled subnet routes ---
# The subnet CIDR strings never contain "telegram"; classification must use
# the containing group, while unrelated/disabled subnets are excluded.
cat > "$TMP/telegram-group.yaml" <<'YAML'
configVersion: 7
groups:
- id: 1
  name: Telegram
  interface: mitun0
  enable: true
  rules:
  - id: 11
    type: subnet
    rule: 149.154.160.0/20
    enable: true
  - id: 12
    type: subnet
    rule: 91.108.4.0/22
    enable: true
  - id: 13
    type: subnet
    rule: 10.10.0.0/16
    enable: false
  - id: 14
    type: domain
    rule: web.telegram.org
    enable: true
- id: 2
  name: Unrelated
  interface: mitun0
  enable: true
  rules:
  - id: 21
    type: subnet
    rule: 192.0.2.0/24
    enable: true
YAML
out=$(run_mode "$TMP/telegram-group.yaml" 1 false clean)
printf '%s\n' "$out" | grep -Fq 'telegram group enabled=yes, effective telegram rules=3 (subnet 2)' || fail_test 'Telegram group subnet ownership miscounted'
printf '%s\n' "$out" | grep -Fq 'enabled rules 4 (subnet 3) in enabled groups 2/2' || fail_test 'Telegram aggregate rule counters changed'

# --- B: 279-like fixture (CRLF): broad catch-all active, telegram off ---
sed 's/$/\r/' "$TMP/se.yaml" > "$TMP/crlf.yaml"
cat > "$TMP/t279.yaml" <<'YAML'
configVersion: 7
groups:
- id: 1
  interface: mitun0
  enable: true
  rules:
  - id: 11
    type: regex
    rule: .*\.com
    enable: true
  - id: 12
    type: subnet
    rule: 10.0.0.0/8
    enable: true
- id: 2
  interface: mitun0
  enable: true
  rules:
  - id: 21
    type: domain
    rule: web.telegram.org
    enable: false
YAML
sed 's/$/\r/' "$TMP/t279.yaml" > "$TMP/t279crlf.yaml"
out=$(run_mode "$TMP/t279crlf.yaml" 1 false clean)
printf '%s\n' "$out" | grep -Fq 'broad catch-all regex rule present' || fail_test '279 broad catch-all not warned'
printf '%s\n' "$out" | grep -Fq 'telegram group enabled=yes, effective telegram rules=0 (subnet 0)' || fail_test '279 telegram semantics wrong'
printf '%s\n' "$out" | grep -Fq 'enabled rules 2 (subnet 1) in enabled groups 2/2' || fail_test '279 counts wrong'
# pattern itself must never leak into the report
printf '%s\n' "$out" | grep -Fq 'pattern withheld' || fail_test 'withholding note missing'
printf '%s\n' "$out" | grep -F '.com' && fail_test 'raw regex leaked into report'


# --- B2: retained real-world arbitrary-label .com regex must WARN ---
cat > "$TMP/retained-broad.yaml" <<'YAML'
configVersion: 7
groups:
- id: 1
  name: mixed routing
  interface: mitun0
  enable: true
  rules:
  - id: 11
    type: regex
    rule: ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)*\.com$
    enable: true
YAML
out=$(run_mode "$TMP/retained-broad.yaml" 1 false clean)
printf '%s\n' "$out" | grep -Fq 'broad catch-all regex rule present' || fail_test 'retained broad .com rule not detected'

# --- B3: narrow concrete domain regex must NOT be a catch-all ---
sed 's@^[[]a-zA-Z0-9-[]]+(\\.[[]a-zA-Z0-9-[]]+)*\\.com\$@^api\\.example\\.com$@' "$TMP/retained-broad.yaml" > "$TMP/narrow-regex.yaml"
out=$(run_mode "$TMP/narrow-regex.yaml" 1 false clean)
printf '%s\n' "$out" | grep -Fq 'broad catch-all regex rule present' && fail_test 'concrete domain regex incorrectly broad'

# --- C: residual chains while daemon stopped ---
out=$(run_mode "$TMP/se.yaml" 0 false clean)
printf '%s\n' "$out" | grep -Fq 'residual MT_* mangle chains while magitrickled is not running' || fail_test 'residual rules not detected'

# --- D: daemon running but zero effective chains ---
cat > "$TMP/runner-empty.sh" <<'SH'
#!/bin/sh
set -eu
MT_CFG=$1
MT_PROCS=$2
MT_REMAP=false
MT_CHAIN="MT_"
MT_IPSET_PREFIX="mt_"
MT_DNS_PORT=3553
info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
iptables() { printf -- '-P PREROUTING ACCEPT\n'; }
ipset() { printf ''; }
ip() { printf ''; }
. "$TMP_DIR/groups.sh"
. "$TMP_DIR/effective.sh"
SH
out=$(TMP_DIR="$TMP" sh "$TMP/runner-empty.sh" "$TMP/se.yaml" 1)
printf '%s\n' "$out" | grep -Fq 'no effective MT_* mangle chains exist' || fail_test 'running-but-empty not detected'

# --- E: configured disableRemap53=true with effective DNAT ---
out=$(run_mode "$TMP/se.yaml" 1 true clean)
printf '%s\n' "$out" | grep -Fq 'CONFIGURED/EFFECTIVE mismatch for DNS interception' || fail_test 'remap53 mismatch not detected'

# --- F: interception configured but no DNAT while running ---
cat > "$TMP/runner-nodnat.sh" <<'SH'
#!/bin/sh
set -eu
MT_CFG=$1
MT_PROCS=$2
MT_REMAP=false
MT_CHAIN="MT_"
MT_IPSET_PREFIX="mt_"
MT_DNS_PORT=3553
info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
iptables() { printf -- '-N MT_DNSOR\n'; }
ipset() { printf ''; }
ip() { printf ''; }
. "$TMP_DIR/groups.sh"
. "$TMP_DIR/effective.sh"
SH
out=$(TMP_DIR="$TMP" sh "$TMP/runner-nodnat.sh" "$TMP/se.yaml" 1)
printf '%s\n' "$out" | grep -Fq 'clients may be bypassing MagiTrickle DNS' || fail_test 'bypassing-DNS condition not detected'

# --- G: busy xtables lock stays UNKNOWN, no false warns ---
out=$(run_mode "$TMP/se.yaml" 1 false busy)
printf '%s\n' "$out" | grep -Fq 'chains=unknown' || fail_test 'busy must stay unknown'
printf '%s\n' "$out" | grep -Fq 'iptables busy or unreadable' || fail_test 'busy note missing'
printf '%s\n' "$out" | grep -Eq '^\[WARN\]' && fail_test 'busy must not warn'

# --- H: tools absent stays UNKNOWN, no false warns ---
out=$(run_mode "$TMP/se.yaml" 1 false absent)
printf '%s\n' "$out" | grep -Fq 'chains=unknown' || fail_test 'absent tools must stay unknown'
printf '%s\n' "$out" | grep -Fq 'iptables not available' || fail_test 'absent note missing'
printf '%s\n' "$out" | grep -Eq '^\[WARN\]' && fail_test 'absent tools must not warn'

echo '[OK] Doctor MT group semantics and effective netfilter regression passed'
