#!/bin/sh
# Universal KAS installer: Core v1.8.8 + Web v0.1.0-beta.8
# Entware ABIs: aarch64-3.10, armv7-3.2, mipsel-3.4, mips-3.4
# Usage: sh kas-universal-install.sh check|all|core|web|doctor
set -eu
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
umask 077

CORE_REF=v1.8.8
WEB_TAG=v0.1.0-beta.8
WEB_PKG_VER=0.1.0.beta.8-1
GITHUB=https://github.com/saymer-alt/keenetic-auto-setup
RAW=https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup
MODE=${1:-check}

msg() { printf '[KAS] %s\n' "$*"; }
fail() { printf '[KAS][ERROR] %s\n' "$*" >&2; exit 1; }

case "$MODE" in check|all|core|web|doctor) ;; *) fail 'Usage: sh kas-universal-install.sh check|all|core|web|doctor' ;; esac
[ "$(id -u)" = 0 ] || fail 'Run as root in Entware SSH shell.'
command -v opkg >/dev/null 2>&1 || fail 'Entware opkg is missing. Install Entware before KAS.'
command -v awk >/dev/null 2>&1 || fail 'awk is required.'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required for verified Web install.'

# Match the canonical v1.8.8 selector, including Entware *_kn suffix.
ABI=$(opkg print-architecture | awk '
  $1 == "arch" && $2 !~ /^(all|noarch)$/ {
    a=$2; sub(/_kn$/, "", a)
    if (a !~ /^(aarch64-3[.]10|armv7-3[.]2|mipsel-3[.]4|mips-3[.]4)$/) { bad=1; next }
    if (!seen[a]++) { selected=a; count++ }
  }
  END { if (!bad && count == 1) print selected; else exit 1 }
') || fail 'Entware architecture is unsupported or ambiguous; stopped.'

case "$ABI" in
  aarch64-3.10) HASH=9653423bcb4baaa352108bc51a2cba99aa6516beb3143ea03e279b64b5ae3a06 ;;
  armv7-3.2)   HASH=421c528971aa30ff60808548b5eeddb70da66d42de297bea64f94c2b4204da85 ;;
  mipsel-3.4)  HASH=7184b8a2c945bc71122377225878e6c2f9cf6fbf316d4ebc65e013c6a1fa7fc8 ;;
  mips-3.4)    HASH=5d0e8c97d14b421ed4b05f8d7cb9f38f55011285665a3a3c0e6f1f748953f275 ;;
esac

msg "Entware ABI: $ABI"
msg "Core tag: $CORE_REF; Web tag: $WEB_TAG"
msg "Storage status (no changes):"
df -h /opt /tmp || true
msg "Existing packages:"
opkg status mihomo magitrickle kas-control-center 2>/dev/null |
  grep -E '^Package:|^Version:|^Status:' || true

if [ "$MODE" = check ]; then
  msg 'CHECK ONLY: no downloads, package installation or configuration changes.'
  msg 'For installation: sh kas-universal-install.sh all (or core / web separately).'
  exit 0
fi

# The canonical installer itself checks RAM/swap, mount type, KeeneticOS
# dependencies, one-Mihomo invariant, and installation ownership.
if ! command -v curl >/dev/null 2>&1; then
  msg 'Installing missing curl through Entware...'
  opkg update || fail 'opkg update failed.'
  opkg install curl || fail 'Could not install curl.'
fi
command -v mktemp >/dev/null 2>&1 || fail 'mktemp is required.'
WORK=$(mktemp -d /tmp/kas-universal.XXXXXXXX) || fail 'Cannot create private /tmp workdir.'
cleanup() {
  rm -f "$WORK/bootstrap.sh" "$WORK/web.ipk" "$WORK/doctor.sh"
  rmdir "$WORK" 2>/dev/null || true
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$MODE" = all ] || [ "$MODE" = core ]; then
  # Keep a persistent copy of an existing user YAML before running setup.
  if [ -f /opt/etc/mihomo/config.yaml ]; then
    [ ! -L /opt/etc/mihomo/config.yaml ] || fail 'Mihomo config.yaml is a symlink: make a manual backup first.'
    BACKUP="/opt/etc/mihomo/config.yaml.pre-kas-$(date +%Y%m%d-%H%M%S)"
    [ ! -e "$BACKUP" ] || fail "Backup already exists: $BACKUP"
    cp -p /opt/etc/mihomo/config.yaml "$BACKUP" || fail 'Cannot back up existing YAML.'
    msg "Saved existing Mihomo YAML: $BACKUP"
  fi

  msg 'Downloading tagged KAS Core bootstrap...'
  GOT=0
  for TRY in 1 2 3; do
    rm -f "$WORK/bootstrap.sh"
    if curl -fSsL --connect-timeout 7 --max-time 45 \
      "$RAW/$CORE_REF/bootstrap.sh" -o "$WORK/bootstrap.sh"; then
      GOT=1
      break
    fi
    msg "Bootstrap attempt $TRY/3 failed."
    [ "$TRY" -eq 3 ] || sleep 2
  done
  [ "$GOT" -eq 1 ] || fail 'Core bootstrap download failed after three attempts.'
  [ -s "$WORK/bootstrap.sh" ] || fail 'Empty bootstrap.'
  grep -Fq 'KAS_FIRSTFETCH_V1' "$WORK/bootstrap.sh" || fail 'Unexpected bootstrap payload.'
  sh -n "$WORK/bootstrap.sh" || fail 'Bootstrap syntax invalid.'
  msg 'Running pinned Core installer. If importer offers YAML input, type s and Enter to skip.'
  KAS_BOOTSTRAP_REF="$CORE_REF" KEENETIC_AUTO_SETUP_REF="$CORE_REF" \
    sh "$WORK/bootstrap.sh" || fail 'Core installation failed; Web step not attempted.'
  msg 'Core installer finished.'
fi

if [ "$MODE" = all ] || [ "$MODE" = web ]; then
  CURRENT=$(opkg status kas-control-center 2>/dev/null | awk '$1 == "Version:" {print $2; exit}')
  if [ "$CURRENT" = "$WEB_PKG_VER" ]; then
    msg "KAS Web $CURRENT already installed; not reinstalling."
  else
    if [ -n "$CURRENT" ] && opkg compare-versions "$CURRENT" '>' "$WEB_PKG_VER"; then
      fail "Installed Web $CURRENT is newer than requested $WEB_PKG_VER; downgrade refused."
    fi
    ASSET="kas-control-center_${WEB_PKG_VER}_${ABI}.ipk"
    URL="$GITHUB/releases/download/$WEB_TAG/$ASSET"
    msg "Downloading verified IPK: $ASSET"
    GOT=0
    for TRY in 1 2 3; do
      rm -f "$WORK/web.ipk"
      if curl -fSsL --connect-timeout 10 --max-time 120 \
        --max-filesize 20971520 "$URL" -o "$WORK/web.ipk"; then
        GOT=1
        break
      fi
      msg "Download attempt $TRY/3 failed."
      [ "$TRY" -eq 3 ] || sleep 2
    done
    [ "$GOT" -eq 1 ] || fail 'No verified Web IPK obtained; no uncompressed binary fallback.'
    BYTES=$(wc -c < "$WORK/web.ipk" | tr -d ' ')
    [ "$BYTES" -gt 0 ] && [ "$BYTES" -le 20971520 ] || fail 'IPK is empty or over 20 MiB.'
    printf '%s  %s\n' "$HASH" "$WORK/web.ipk" | sha256sum -c - \
      || fail 'IPK SHA-256 mismatch; installation refused.'
    msg "Verified $BYTES bytes. Installing package through opkg..."
    opkg install "$WORK/web.ipk" || fail 'KAS Web opkg install failed.'
  fi
  if [ -f /opt/etc/init.d/S98kas-control-center ]; then
    sh /opt/etc/init.d/S98kas-control-center start || \
      msg 'Web start returned error; inspect status.'
    sh /opt/etc/init.d/S98kas-control-center status || \
      msg 'Web status could not confirm RUNNING.'
  else
    msg 'Web service init script missing! Check package installation.'
  fi
fi

if [ "$MODE" = doctor ]; then
  msg 'Downloading tagged read-only Doctor...'
  curl -fSsL --connect-timeout 7 --max-time 45 \
    "$RAW/$CORE_REF/mihomo-doctor.sh" -o "$WORK/doctor.sh" \
    || fail 'Doctor download failed.'
  [ -s "$WORK/doctor.sh" ] || fail 'Empty Doctor script.'
  sh -n "$WORK/doctor.sh" || fail 'Doctor syntax invalid.'
  sh "$WORK/doctor.sh"
fi

msg 'Done. Use "doctor" mode for the read-only Core diagnostic.'
