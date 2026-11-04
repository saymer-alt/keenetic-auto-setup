#!/bin/sh
# Offline regression: extract and exercise the real Doctor MagiTrickle parsers.
set -eu
ROOT=${1:-.}
DOCTOR="$ROOT/mihomo-doctor.sh"
TMP="${TMPDIR:-/tmp}/doctor-mt-scope.$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
fail_test() { echo "[FAIL] $1" >&2; exit 1; }
awk '/# BEGIN DOCTOR MT LINK PARSE v1/ { on=1 } on { print } /# END DOCTOR MT LINK PARSE v1/ { exit }' "$DOCTOR" > "$TMP/link.sh"
awk '/# BEGIN DOCTOR MT ROUTING SCOPE v1/ { on=1 } on { print } /# END DOCTOR MT ROUTING SCOPE v1/ { exit }' "$DOCTOR" > "$TMP/scope.sh"
grep -q '^ *MT_LINK=' "$TMP/link.sh" || fail_test 'missing link parser'
grep -q '^ *MT_RULE_SUMMARY=' "$TMP/scope.sh" || fail_test 'missing group parser'
sh -n "$TMP/link.sh"; sh -n "$TMP/scope.sh"
cat > "$TMP/fixture.yaml" <<'YAML'
configVersion: 0.8.2
app:
  netfilter:
    disableIPv4: false
    disableIPv6: true
  link:
  - br0
  showAllInterfaces: false
groups:
- id: one
  name: test
  interface: mitun0
  enable: true
  rules:
  - id: a
    type: namespace
    rule: 2ip.io
    enable: true
  - id: b
    type: namespace
    rule: speedtest.net
    enable: true
- id: two
  name: disabled
  interface: mitun0
  enable: false
  rules:
  - id: c
    type: namespace
    rule: example.org
    enable: true
subscriptions: []
YAML
cat > "$TMP/runner.sh" <<'SH'
#!/bin/sh
set -eu
MT_CFG=$1
MT_LINK=""
info() { printf '[INFO] %s\n' "$1"; }
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
. "$2"
. "$3"
SH
check() {
  _out=$(sh "$TMP/runner.sh" "$1" "$TMP/link.sh" "$TMP/scope.sh")
  printf '%s\n' "$_out" | grep -Fq 'br0=yes, br1=no' || fail_test 'br0 not parsed'
  printf '%s\n' "$_out" | grep -Fq 'disableIPv4=false, disableIPv6=true' || fail_test 'flags wrong'
  printf '%s\n' "$_out" | grep -Fq '1 enabled / 2 total; enabled rules in enabled groups: 2' || fail_test 'counts wrong'
  printf '%s\n' "$_out" | grep -Fq '2ip.io=mitun0, speedtest.net=mitun0' || fail_test 'test site rules missing'
}
check "$TMP/fixture.yaml"
sed 's/$/\r/' "$TMP/fixture.yaml" > "$TMP/crlf.yaml"
check "$TMP/crlf.yaml"
sed 's/^  - br0$/  - br1/' "$TMP/fixture.yaml" > "$TMP/br1.yaml"
out=$(sh "$TMP/runner.sh" "$TMP/br1.yaml" "$TMP/link.sh" "$TMP/scope.sh")
printf '%s\n' "$out" | grep -Fq 'br0=no, br1=yes' || fail_test 'br1 not parsed'
sed 's/rule: speedtest.net/rule: not-speedtest.example/' "$TMP/fixture.yaml" > "$TMP/no-speedtest.yaml"
out=$(sh "$TMP/runner.sh" "$TMP/no-speedtest.yaml" "$TMP/link.sh" "$TMP/scope.sh")
printf '%s\n' "$out" | grep -Fq 'speedtest.net=not detected' || fail_test 'false positive test site'
echo '[OK] Doctor MT link/rule inventory regression passed'
