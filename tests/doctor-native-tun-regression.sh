#!/bin/sh
# Offline regression: extract and exercise the real Doctor native OpkgTunN
# observation block (Task #2 / issue #242 native-first research).
# The /sys/class/net root is injectable via KAS_SYS_NET (default unchanged);
# no router, ndmc, real sysfs or config mutation is involved.
set -eu
ROOT=${1:-.}
DOCTOR="$ROOT/mihomo-doctor.sh"
TMP="${TMPDIR:-/tmp}/doctor-native-tun.$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
fail_test() { echo "[FAIL] $1" >&2; exit 1; }

awk '/# BEGIN DOCTOR NATIVE OPKG TUN v1/ { on=1 } on { print } /# END DOCTOR NATIVE OPKG TUN v1/ { exit }' "$DOCTOR" > "$TMP/block.sh"
grep -q 'KAS_SYS_NET' "$TMP/block.sh" || fail_test 'missing sys net root'
sh -n "$TMP/block.sh"

cat > "$TMP/runner.sh" <<'SH'
#!/bin/sh
set -eu
CONFIG=$1
info() { printf '[INFO] %s\n' "$1"; }
. "$TMP_DIR/block.sh"
SH

run_case() {
  _cfg=$1; _sys=$2
  TMP_DIR="$TMP" KAS_SYS_NET="$_sys" sh "$TMP/runner.sh" "$_cfg"
}

# fixture sysfs roots
mkdir -p "$TMP/sys-native/opkgtun0" "$TMP/sys-mitun0/mitun0" "$TMP/sys-empty"

# A: native config + device present -> native INFO, no false standard claim
cat > "$TMP/native.yaml" <<'YAML'
listeners:
- name: kas-tun0
  type: tun
  device: opkgtun0
  mtu: 1280
YAML
out=$(run_case "$TMP/native.yaml" "$TMP/sys-native")
printf '%s\n' "$out" | grep -Fq 'references an opkg-native TUN device and it is present (opkgtun0)' || fail_test 'native present not reported'
printf '%s\n' "$out" | grep -Fq 'field-reported inconsistent (UNVERIFIED)' || fail_test 'honest caveat missing'

# B: native config, device absent -> boot-order INFO
out=$(run_case "$TMP/native.yaml" "$TMP/sys-empty")
printf '%s\n' "$out" | grep -Fq 'no opkgtunN Linux device is present at check time' || fail_test 'native absent not reported'
printf '%s\n' "$out" | grep -Fq 'does not attach to an existing device - field observation, UNVERIFIED' || fail_test 'boot-order caveat missing'

# C: standard mitun0 config + foreign opkgtun0 -> foreign INFO
cat > "$TMP/standard.yaml" <<'YAML'
tun:
  enable: true
  stack: mips
  device: mitun0
YAML
out=$(run_case "$TMP/standard.yaml" "$TMP/sys-native")
printf '%s\n' "$out" | grep -Fq 'foreign or unrelated opkg tun' || fail_test 'foreign device not reported'
printf '%s\n' "$out" | grep -Fq 'the KAS standard device remains mitun0' || fail_test 'standard reminder missing'

# D: standard config, no opkgtun devices -> silence (no noise)
out=$(run_case "$TMP/standard.yaml" "$TMP/sys-mitun0")
printf '%s\n' "$out" | grep -Fq 'opkg-native' && fail_test 'noise on standard setup'

# E: no sysfs at all -> silence (honest degradation)
out=$(run_case "$TMP/standard.yaml" "$TMP/definitely-missing-sys")
printf '%s\n' "$out" | grep -Fq 'opkg-native' && fail_test 'noise on missing sysfs'

# F: listener flow-style device with quotes still detected
cat > "$TMP/quoted.yaml" <<'YAML'
tun:
  enable: true
  device: "opkgtun0"
YAML
out=$(run_case "$TMP/quoted.yaml" "$TMP/sys-native")
printf '%s\n' "$out" | grep -Fq 'references an opkg-native TUN device' || fail_test 'quoted device not detected'

# G: mitun0 device must NOT be classified native
sed 's/opkgtun0/mitun0/' "$TMP/native.yaml" > "$TMP/notnative.yaml"
out=$(run_case "$TMP/notnative.yaml" "$TMP/sys-native")
printf '%s\n' "$out" | grep -Fq 'references an opkg-native TUN device' && fail_test 'mitun0 misclassified as native'
printf '%s\n' "$out" | grep -Fq 'foreign or unrelated opkg tun' || fail_test 'foreign path lost for mitun0 config'


# H: exact configured device must match sysfs; a foreign native name is NOT
# proof of an attached native topology.
mkdir -p "$TMP/sys-other/opkgtun1"
out=$(run_case "$TMP/native.yaml" "$TMP/sys-other")
printf '%s\n' "$out" | grep -Fq 'configured device(s) absent (opkgtun0)' || fail_test 'wrong native device accepted as matching config'
printf '%s\n' "$out" | grep -Fq 'other observed opkgtunN (opkgtun1) may be unrelated' || fail_test 'foreign native device not distinguished'
printf '%s\n' "$out" | grep -Fq 'native topology observed' && fail_test 'false native topology claim on mismatched device'

# I: native TUN observation is outside the optional MT-installed branch.
# The preceding nonblank line must be the close of the MT branch.
awk '
    /# BEGIN DOCTOR NATIVE OPKG TUN v1/ {if (previous != "fi") exit 1; found=1}
    NF {previous=$0}
    END {if (!found) exit 1}
' "$DOCTOR" || fail_test 'native TUN observation depends on optional MagiTrickle'

echo '[OK] Doctor native OpkgTunN observation regression passed'
