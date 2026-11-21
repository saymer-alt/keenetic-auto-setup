#!/bin/sh
# KAS Web channel installer; BusyBox ash / Entware. Never installs Core.
set -eu
umask 077
REPO='saymer-alt/keenetic-auto-setup'
PAGES='https://saymer-alt.github.io/keenetic-auto-setup/updates'
RELEASE_API="https://api.github.com/repos/$REPO/releases/tags"
CHANNEL=experimental
MODE=install
WORK=''
msg() { printf '[KAS Web] %s\n' "$*"; }
fail() { printf '[KAS Web] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: sh kas-web-install.sh [beta|stable] [--check]
  beta: latest published Web beta (default; experimental channel)
  stable: stable Web channel, only when published
  --check: read-only check; do not install or upgrade
Requires Entware, curl, jq and sha256sum. Only installs kas-control-center.
HELP
}
channel_set=0
for arg in "$@"; do
  case "$arg" in
    beta|experimental) [ "$channel_set" -eq 0 ] || fail 'Multiple channels'; CHANNEL=experimental; channel_set=1 ;;
    stable) [ "$channel_set" -eq 0 ] || fail 'Multiple channels'; CHANNEL=stable; channel_set=1 ;;
    --check) [ "$MODE" = install ] || fail 'Duplicate --check'; MODE=check ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unsupported argument: $arg" ;;
  esac
done
command -v curl >/dev/null 2>&1 || fail 'curl required: opkg update && opkg install curl'
command -v jq >/dev/null 2>&1 || fail 'jq required: opkg update && opkg install jq'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum required'
command -v opkg >/dev/null 2>&1 || fail 'Entware opkg required'
# Root cause of field bug #254: the real Entware feed declares
# 'Depends: ..., libcurl' WITHOUT a version bound, so 'opkg install curl'
# upgrades the binary alone and leaves an ABI-incompatible libcurl installed
# (field: curl 8.23.0-1 + libcurl 8.15.0-2 -> undefined curl_multi_get_offt).
# A direct package-database comparison catches that skew before any download,
# independently of what 'curl -V' manages to start. Read-only: never upgrade
# feeds or touch package ownership; the repair stays an explicit operator step.
# Share the preflight's read-only, strict installed-record parser (POSIX sh).
# An absent, duplicated, malformed or uninstalled OPKG record is NOT a
# guarantee that curl and libcurl have matching versions.
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
_curl_status=$(opkg status curl 2>/dev/null) || _curl_status=''
_libcurl_status=$(opkg status libcurl 2>/dev/null) || _libcurl_status=''
_curl_ver=$(opkg_installed_version curl "$_curl_status") || _curl_ver=''
_libcurl_ver=$(opkg_installed_version libcurl "$_libcurl_status") || _libcurl_ver=''
if [ -z "$_curl_ver" ] || [ -z "$_libcurl_ver" ]; then
  fail 'curl/libcurl installed-package records missing, malformed or unconfirmed: inspect opkg status curl and opkg status libcurl, repair Entware package state manually before retrying'
fi
if [ "$_curl_ver" != "$_libcurl_ver" ]; then
  fail "curl/libcurl version skew detected ($_curl_ver vs $_libcurl_ver): run 'opkg update && opkg install libcurl' to realign, then retry (field bug: undefined curl_multi_get_offt)"
fi
# An executable curl path is not enough: a partial Entware package upgrade
# can leave curl and libcurl ABI-incompatible (field: aarch64-3.10, 2026-11-17).
# LD_BIND_NOW catches lazily resolved undefined symbols that plain curl -V can
# miss. Read-only probe: never auto-upgrade feeds or mutate package ownership.
if ! LD_BIND_NOW=1 curl -V >/dev/null 2>&1; then
  fail 'curl cannot start (possible curl/libcurl ABI mismatch); check: opkg list-installed | grep -E "^(curl|libcurl)"; verify feeds and repair libcurl manually before retrying'
fi
ARCH=$(opkg print-architecture | awk '
  $1=="arch" {
    a=$2; sub(/_kn$/,"",a)
    if (a=="aarch64-3.10" || a=="armv7-3.2" || a=="mipsel-3.4" || a=="mips-3.4") {
      if (found!="" && found!=a) bad=1
      found=a
    }
  }
  END { if(bad || found=="") exit 1; print found }
') || fail 'Unsupported or ambiguous Entware architecture'
STAGE_PARENT="${TMPDIR:-/opt/tmp}"
[ -d "$STAGE_PARENT" ] || fail 'Staging directory missing: mount Entware first'
WORK=$(mktemp -d "$STAGE_PARENT/kas-web-install.XXXXXXXX") || fail 'Cannot stage IPK privately'
cleanup() { [ -z "$WORK" ] || rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Download only from fixed HTTPS hosts, enforce limits and HTTPS-only redirects.
get() {
  url="$1"; dst="$2"; cap="$3"; budget="$4"
  rm -f "$dst"
  curl -q -fLsS --proto '=https' --proto-redir '=https' \
    --connect-timeout 8 --max-time "$budget" --max-filesize "$cap" "$url" -o "$dst" ||
    fail "Unable to download: $url"
  [ -s "$dst" ] || fail "Empty download: $url"
  len=$(wc -c < "$dst" | tr -d '[:space:]')
  [ "$len" -le "$cap" ] || fail "Oversized response: $url"
}
msg "Channel: $CHANNEL; Entware architecture: $ARCH"
get "$PAGES/channels.json" "$WORK/channels.json" 65536 25
if ! jq -e --arg ch "$CHANNEL" '
  .schema == 1 and (.channels | type == "object") and
  (.channels[$ch] | type == "object") and
  (.channels[$ch].published | type == "boolean")
' "$WORK/channels.json" >/dev/null 2>&1; then
  fail 'Invalid channel registry; refusing to guess Web version'
fi
published=$(jq -r --arg ch "$CHANNEL" '.channels[$ch].published' "$WORK/channels.json")
[ "$published" = true ] || fail "Web $CHANNEL channel not published"
registry_tag=$(jq -r --arg ch "$CHANNEL" '.channels[$ch].tag // empty' "$WORK/channels.json")
get "$PAGES/$CHANNEL/panel-update.json" "$WORK/index.json" 1048576 35

row=$(jq -er --arg ch "$CHANNEL" --arg arch "$ARCH" --arg registry_tag "$registry_tag" '
  select(.schema == 1 and .channel == $ch and .tag == $registry_tag)
  | select((.tag | type) == "string")
  | select((.packages | type) == "array" and (.packages | length) > 0 and (.packages | length) <= 4)
  | [.packages[] | select(.architecture == $arch)] as $matches
  | select($matches | length == 1) | $matches[0] as $pkg
  | select(($pkg.version | type) == "string" and ($pkg.name | type) == "string" and
           ($pkg.sha256 | type) == "string")
  | select(($pkg.size | type) == "number" and $pkg.size > 0 and
           $pkg.size <= 20971520 and $pkg.size == ($pkg.size | floor))
  | [.tag, $pkg.version, $pkg.name, ($pkg.size | tostring), $pkg.sha256] | @tsv
' "$WORK/index.json") || fail 'Invalid index or unsupported Web IPK'
set -f
set -- $row
set +f
[ "$#" -eq 5 ] || fail 'Ambiguous index fields'
TAG="$1"; VERSION="$2"; NAME="$3"; SIZE="$4"; DIGEST="$5"
# Entware jq may be built without ONIGURUMA: validate ASCII formats using
# POSIX awk instead of jq regex. Keep the same anchored tag/version/SHA256
# checks and never accept data-driven GitHub asset URLs.
printf '%s\n%s\n%s\n' "$TAG" "$VERSION" "$DIGEST" | LC_ALL=C awk -v ch="$CHANNEL" '
  NR == 1 {
    if (ch == "experimental") {
      if ($0 !~ /^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$/) exit 1
    } else if (ch == "stable") {
      if ($0 !~ /^kas-web-v[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    } else exit 1
  }
  NR == 2 { if ($0 !~ /^[0-9A-Za-z.~+-]+$/) exit 1 }
  NR == 3 { if (length($0) != 64 || $0 !~ /^[a-f0-9]+$/) exit 1 }
  END { if (NR != 3) exit 1 }
' || fail 'Invalid index tag, package version or SHA256'
NORMALIZED_VERSION=$(printf '%s' "$VERSION" | tr '~' '.')
[ "$NAME" = "kas-control-center_${NORMALIZED_VERSION}_${ARCH}.ipk" ] ||
  fail 'Index package filename does not match verified version and architecture'
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/$NAME"
get "$RELEASE_API/$TAG" "$WORK/release.json" 1048576 35
jq -e --arg tag "$TAG" --arg name "$NAME" --arg size "$SIZE" \
  --arg digest "sha256:$DIGEST" --arg url "$ASSET_URL" --arg ch "$CHANNEL" '
  .tag_name == $tag and .draft == false and .prerelease == ($ch == "experimental") and
  (.assets | type) == "array" and
  ([.assets[] | select(.name == $name)] | length) == 1 and
  ([.assets[] | select(.name == $name and .size == ($size | tonumber) and
    .digest == $digest and .state == "uploaded" and .browser_download_url == $url)] | length) == 1
' "$WORK/release.json" >/dev/null || fail 'GitHub Release does not match index SHA256/size/asset'
CURRENT=$(opkg status kas-control-center 2>/dev/null | awk '$1=="Version:" {print $2; exit}')
msg "Published Web: $VERSION ($TAG)"
msg "Installed Web: ${CURRENT:-not installed}"
if [ -n "$CURRENT" ]; then
  if opkg compare-versions "$CURRENT" '=' "$VERSION"; then
    msg 'Already up to date; no changes'
    exit 0
  fi
  if ! opkg compare-versions "$CURRENT" '<' "$VERSION"; then
    fail "Refusing downgrade/incomparable version: $CURRENT vs $VERSION"
  fi
fi
[ "$MODE" = check ] && { msg 'Check only: metadata verified, no install'; exit 0; }

msg "Downloading Web IPK ($SIZE bytes)..."
get "$ASSET_URL" "$WORK/$NAME" 20971520 1800
BYTES=$(wc -c < "$WORK/$NAME" | tr -d '[:space:]')
[ "$BYTES" = "$SIZE" ] || fail 'Downloaded IPK byte count mismatch'
printf '%s  %s\n' "$DIGEST" "$WORK/$NAME" | sha256sum -c - >/dev/null ||
  fail 'Downloaded IPK SHA256 mismatch: refusing installation'
msg 'IPK SHA256 and size verified'
opkg install "$WORK/$NAME" || fail 'OPKG installation failed; inspect before retry'
NOW=$(opkg status kas-control-center 2>/dev/null | awk '$1=="Version:" {print $2; exit}')
[ "$NOW" = "$VERSION" ] || fail "OPKG version mismatch after install: ${NOW:-missing}"
INIT=/opt/etc/init.d/S98kas-control-center
[ -x "$INIT" ] || fail 'Web init script missing'
if [ -n "$CURRENT" ]; then
  sh "$INIT" restart || fail 'Web restart failed'
else
  sh "$INIT" start || fail 'Web start failed'
fi
sh "$INIT" status || fail 'Web service did not report RUNNING'
msg "Web $VERSION running; check local port 18080–18090 or saved port."
msg 'Panel defaults to HTTP without TLS/password; use a trusted LAN only.'
