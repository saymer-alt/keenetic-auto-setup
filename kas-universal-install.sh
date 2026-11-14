#!/bin/sh
# Universal KAS installer: Core v1.8.9 + Web v0.1.0-beta.9
# Entware ABIs: aarch64-3.10, armv7-3.2, mipsel-3.4, mips-3.4
# Usage: sh kas-universal-install.sh check|all|core|web|doctor
set -eu
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
umask 077

CORE_REF=v1.8.9
# Tag v1.8.9 is a lightweight tag resolving to this commit; a tag can be
# retargeted, a commit cannot. The digests below are SHA256 of the exact
# bootstrap.sh / mihomo-doctor.sh bytes served for that commit. Those bytes
# are unchanged since v1.8.8, where they were verified through two
# independent channels (GitHub Contents API base64 and
# raw.githubusercontent.com, byte-identical); re-hashed from the v1.8.9
# git blobs on 2026-11-14.
CORE_COMMIT=44c6b901709343a30e2503949037c7e66dd6e831
CORE_BOOTSTRAP_SHA256=853e4badf57ee3a2065953a87caed300093adc68c971294a973d93f531dc697c
CORE_DOCTOR_SHA256=10cb06803ed712cb50cc1be44a8d3fa75ce5a58dbbcf65ed99a60f671f5e0fb1
# Ceiling for launcher-fetched scripts; the pinned Doctor is ~170 KiB.
SCRIPT_MAX_BYTES=1048576
WEB_TAG=v0.1.0-beta.9
WEB_PKG_VER=0.1.0.beta.9-1
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

# Match the canonical installer selector, including Entware *_kn suffix.
ABI=$(opkg print-architecture | awk '
  $1 == "arch" && $2 !~ /^(all|noarch)$/ {
    a=$2; sub(/_kn$/, "", a)
    if (a !~ /^(aarch64-3[.]10|armv7-3[.]2|mipsel-3[.]4|mips-3[.]4)$/) { bad=1; next }
    if (!seen[a]++) { selected=a; count++ }
  }
  END { if (!bad && count == 1) print selected; else exit 1 }
') || fail 'Entware architecture is unsupported or ambiguous; stopped.'

# SHA256 of the official $WEB_TAG release IPK assets, verified 2026-11-14
# through three independent channels (published SHA256SUMS, a fresh download
# re-hashed locally, and the GitHub asset digest field).
case "$ABI" in
  aarch64-3.10) HASH=4cc2576787962a010ba924985ce9015e641fbe06148ffb495ae59f9f6721bcca ;;
  armv7-3.2)   HASH=ff8c6e1d2e9bc78e6d58b598cc1589a89427d49251aece07376b7cfd66d34b7c ;;
  mipsel-3.4)  HASH=3a3fb6aa415a74028b4ada2d62ca47dc00b0733c359f25d2267e361b379781b5 ;;
  mips-3.4)    HASH=9c32ea160ff612682a64bb0a63cfbcbfc13b513f4ed5682aa863c9f81a2b2592 ;;
esac

msg "Entware ABI: $ABI"
msg "Core tag: $CORE_REF; pinned commit: $CORE_COMMIT; Web tag: $WEB_TAG"
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
# check and doctor are read-only diagnostics: neither may run opkg
# update/install. Only installing modes may bootstrap a missing curl
# through Entware; doctor instead requires a working curl for its single
# diagnostic download and refuses with instructions when it is absent.
if [ "$MODE" = doctor ]; then
  command -v curl >/dev/null 2>&1 || \
    fail 'Doctor mode is read-only: it does not install packages. Install curl first, e.g. "opkg update && opkg install curl", then rerun doctor.'
elif [ "$MODE" = all ] || [ "$MODE" = core ] || [ "$MODE" = web ]; then
  if ! command -v curl >/dev/null 2>&1; then
    msg 'Installing missing curl through Entware...'
    opkg update || fail 'opkg update failed.'
    opkg install curl || fail 'Could not install curl.'
  fi
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

  # Initial bootstrap bytes are pinned by SHA256, and the complete downstream
  # script chain uses the SAME immutable commit (never the mutable release
  # tag). setup.sh and install.sh fetches are still protected by the GitHub
  # commit identity plus TLS, not per-file SHA256; do not misrepresent that
  # narrower trust guarantee as independently hashed transitive assets.
  msg 'Downloading pinned KAS Core bootstrap...'
  GOT=0
  for TRY in 1 2 3; do
    rm -f "$WORK/bootstrap.sh"
    if curl -fSsL --connect-timeout 7 --max-time 45 --max-filesize "$SCRIPT_MAX_BYTES" \
      "$RAW/$CORE_COMMIT/bootstrap.sh" -o "$WORK/bootstrap.sh"; then
      GOT=1
      break
    fi
    msg "Bootstrap attempt $TRY/3 failed."
    [ "$TRY" -eq 3 ] || sleep 2
  done
  [ "$GOT" -eq 1 ] || fail 'Core bootstrap download failed after three attempts.'
  [ -s "$WORK/bootstrap.sh" ] || fail 'Empty bootstrap.'
  BYTES=$(wc -c < "$WORK/bootstrap.sh" | tr -d ' ')
  [ "$BYTES" -gt 0 ] && [ "$BYTES" -le "$SCRIPT_MAX_BYTES" ] \
    || fail 'Bootstrap is empty or over the size limit; refused.'
  if grep -Eqi '<html|<!doctype|404: not found' "$WORK/bootstrap.sh"; then
    fail 'Bootstrap payload is an HTML/404 error page, not the pinned script.'
  fi
  grep -Fq 'KAS_FIRSTFETCH_V1' "$WORK/bootstrap.sh" || fail 'Unexpected bootstrap payload.'
  printf '%s  %s\n' "$CORE_BOOTSTRAP_SHA256" "$WORK/bootstrap.sh" | sha256sum -c - \
    || fail 'Bootstrap SHA-256 mismatch with pinned v1.8.9 content; execution refused.'
  sh -n "$WORK/bootstrap.sh" || fail 'Bootstrap syntax invalid.'
  msg 'Running pinned Core installer. If importer offers YAML input, type s and Enter to skip.'
  KAS_BOOTSTRAP_REF="$CORE_COMMIT" KEENETIC_AUTO_SETUP_REF="$CORE_COMMIT" \
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
  # Same pre-execution pinning as the Core bootstrap: immutable commit URL
  # plus SHA256 before any bytes run. Read-only behavior is unchanged.
  msg 'Downloading pinned read-only Doctor...'
  curl -fSsL --connect-timeout 7 --max-time 45 --max-filesize "$SCRIPT_MAX_BYTES" \
    "$RAW/$CORE_COMMIT/mihomo-doctor.sh" -o "$WORK/doctor.sh" \
    || fail 'Doctor download failed.'
  [ -s "$WORK/doctor.sh" ] || fail 'Empty Doctor script.'
  BYTES=$(wc -c < "$WORK/doctor.sh" | tr -d ' ')
  [ "$BYTES" -gt 0 ] && [ "$BYTES" -le "$SCRIPT_MAX_BYTES" ] \
    || fail 'Doctor script is empty or over the size limit; refused.'
  if grep -Eqi '<html|<!doctype|404: not found' "$WORK/doctor.sh"; then
    fail 'Doctor payload is an HTML/404 error page, not the pinned script.'
  fi
  printf '%s  %s\n' "$CORE_DOCTOR_SHA256" "$WORK/doctor.sh" | sha256sum -c - \
    || fail 'Doctor SHA-256 mismatch with pinned v1.8.9 content; execution refused.'
  sh -n "$WORK/doctor.sh" || fail 'Doctor syntax invalid.'
  sh "$WORK/doctor.sh"
fi

msg 'Done. Use "doctor" mode for the read-only Core diagnostic.'
