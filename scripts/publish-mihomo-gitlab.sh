#!/bin/sh
# Publish the reviewed Mihomo IPK snapshot (issue #19) to the GitLab Generic
# Package Registry. Owner-run only; never from CI; never unattended.
#
# Fail-closed state model (mirrors/mihomo/GITLAB-PUBLISH.md):
#   HTTP 200 on a pre-publish probe   -> the version already exists, fully or
#                                        partially: ABORT. Never overwrite,
#                                        never delete files to "fix" a partial
#                                        publication — the owner decides.
#   HTTP 404 (confirmed)              -> file not published; proceed only when
#                                        ALL five IPKs AND SHA256SUMS are
#                                        confirmed 404.
#   Anything else (401/403/429/5xx, transport errors) -> STOP: state unknown.
#
# Secret handling: the PAT is read from a 0600 file and handed to curl only
# through a temporary 0600 curl config file (--config). It never appears in a
# command-line argument (process listings and shell history must not see it),
# in logs, or in CI. The temp config is removed on every exit path.
#
# Exit codes: 0 published and anonymously verified; 1 STOP (unknown state);
# 2 ABORT (already published, fully or partially); 3 preflight refusal
# (env, PAT, bundle or lock-manifest mismatch).

set -u

PACKAGE="kas-mihomo-mirror"
# Single reviewed snapshot (mirrors/mihomo/1.19.34-3.lock.json). A new upstream
# build requires a new reviewed manifest and editing this line afterwards.
VER="1.19.34-3"
FILES="mihomo_1.19.34-3_aarch64-3.10.ipk mihomo_1.19.34-3_armv7-3.2.ipk \
mihomo_1.19.34-3_mips-3.4.ipk mihomo_1.19.34-3_mipsel-3.4.ipk \
mihomo_nohf_1.19.34-3_armv7-3.2.ipk SHA256SUMS"

log() { printf '[publish] %s\n' "$1"; }
stop() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
refuse() { printf 'REFUSED: %s\n' "$1" >&2; exit 3; }
abort() { printf 'ABORT: %s\n' "$1" >&2; exit 2; }

GITLAB_HOST="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_HOST="${GITLAB_HOST%/}"
PROJECT_ID="${PROJECT_ID:-}"
BUNDLE_DIR="${BUNDLE_DIR:-}"

# --- preflight: local checks only, no network -------------------------------
case "$PROJECT_ID" in
    '' | *[!0-9]*) refuse "PROJECT_ID must be the numeric GitLab project id" ;;
esac
[ -d "$BUNDLE_DIR" ] || refuse "BUNDLE_DIR does not exist: ${BUNDLE_DIR:-<unset>}"
for f in $FILES; do
    [ -f "$BUNDLE_DIR/$f" ] || refuse "bundle file missing: $BUNDLE_DIR/$f"
done

loopback=0
case "$GITLAB_HOST" in
    https://*) ;;
    http://127.0.0.1:* | http://localhost | http://localhost:* | 'http://[::1]':*)
        loopback=1
        log "WARNING: loopback http host override (test-only): $GITLAB_HOST"
        ;;
    *) refuse "GITLAB_HOST must be https:// (plain http is allowed only for 127.0.0.1/localhost test overrides)" ;;
esac
HTTPS_FLAGS=""
[ "$loopback" = 1 ] || HTTPS_FLAGS="--proto =https --proto-redir =https"

# Test-only hook: a loopback host is the only place a verifier substitute may
# run; real publications always use the reviewed-snapshot verifier.
if [ -n "${KAS_VERIFY_MIRROR_SCRIPT:-}" ] && [ "$loopback" != 1 ]; then
    refuse "KAS_VERIFY_MIRROR_SCRIPT override is allowed only for loopback test hosts"
fi

# Independent trust gate: the bundle must match the reviewed lock manifest,
# not merely its own SHA256SUMS (which could be regenerated together with
# tampered IPKs). scripts/verify_mihomo_mirror.py enforces the reviewed
# snapshot allowlist byte-for-byte — sizes, SHA256, control fields and the
# packaged S28 init identity — and refuses a manifest that drifted from the
# reviewed snapshot, so a substituted manifest is caught too. This runs before
# any network activity and before the PAT is even read.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || \
    refuse "cannot resolve the repository scripts directory"
LOCK_MANIFEST="${KAS_LOCK_MANIFEST:-$script_dir/../mirrors/mihomo/1.19.34-3.lock.json}"
[ -f "$LOCK_MANIFEST" ] || refuse "lock manifest missing: $LOCK_MANIFEST"
if [ -n "${KAS_VERIFY_MIRROR_SCRIPT:-}" ]; then
    [ -f "$KAS_VERIFY_MIRROR_SCRIPT" ] || \
        refuse "KAS_VERIFY_MIRROR_SCRIPT points to a missing file: $KAS_VERIFY_MIRROR_SCRIPT"
    sh "$KAS_VERIFY_MIRROR_SCRIPT" --manifest "$LOCK_MANIFEST" \
        --output "$BUNDLE_DIR" --offline >/dev/null || \
        refuse "bundle does not match the reviewed lock manifest ($LOCK_MANIFEST) — refusing to publish (possible IPK+SHA256SUMS tampering or unreviewed artifacts)"
else
    PY3=$(command -v python3 || command -v python) || \
        refuse "python3 is required to verify the bundle against the reviewed lock manifest"
    [ -f "$script_dir/verify_mihomo_mirror.py" ] || \
        refuse "reviewed-snapshot verifier missing: $script_dir/verify_mihomo_mirror.py"
    "$PY3" "$script_dir/verify_mihomo_mirror.py" --manifest "$LOCK_MANIFEST" \
        --output "$BUNDLE_DIR" --offline >/dev/null || \
        refuse "bundle does not match the reviewed lock manifest ($LOCK_MANIFEST) — refusing to publish (possible IPK+SHA256SUMS tampering or unreviewed artifacts)"
fi
log "bundle matches the reviewed lock manifest $LOCK_MANIFEST"

# Bundle integrity gate: SHA256SUMS is generated from the verified bundle if
# absent, then always re-checked before anything leaves the machine.
if [ ! -s "$BUNDLE_DIR/SHA256SUMS" ]; then
    (cd "$BUNDLE_DIR" && sha256sum ./*.ipk > SHA256SUMS) || \
        refuse "cannot generate SHA256SUMS in bundle"
    log "generated SHA256SUMS from local bundle bytes"
fi
(cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS >/dev/null) || \
    refuse "bundle SHA256SUMS verification failed — corrupted or tampered bundle; regenerate via scripts/verify_mihomo_mirror.py"

# --- secret handling ---------------------------------------------------------
PAT_FILE="${KAS_GITLAB_PAT_FILE:-}"
[ -n "$PAT_FILE" ] || refuse "set KAS_GITLAB_PAT_FILE to a 0600 file containing the GitLab PAT (never pass it on the command line)"
[ -f "$PAT_FILE" ] || refuse "PAT file missing: $PAT_FILE"
pat_perms=$(stat -c '%a' "$PAT_FILE" 2>/dev/null) || refuse "cannot stat PAT file: $PAT_FILE"
[ "$pat_perms" = "600" ] || refuse "PAT file must have mode 0600 (got $pat_perms)"
PAT=$(cat "$PAT_FILE") || refuse "cannot read PAT file: $PAT_FILE"
case "$PAT" in
    '' | *[!A-Za-z0-9_-]*) refuse "PAT file is empty or contains unexpected characters" ;;
esac

umask 077
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/kas-mihomo-publish.XXXXXXXX") || \
    refuse "mktemp failed (refusing to handle the PAT without a private temp dir)"
CFG="$TMPD/curl.cfg"
# Built via heredoc so the PAT never enters the argv of any external process.
cat > "$CFG" <<EOF
user = "saymer-alt:$PAT"
EOF
chmod 600 "$CFG"
unset PAT
trap 'rm -rf "$TMPD"' EXIT INT TERM HUP

base_url="$GITLAB_HOST/api/v4/projects/$PROJECT_ID/packages/generic/$PACKAGE/$VER"

# --- project availability and permission check (authorized, fail-closed) -----
rc=0
proj_code=$(curl $HTTPS_FLAGS --config "$CFG" -sS -o "$TMPD/project.json" \
    -w '%{http_code}' --connect-timeout 10 --max-time 60 \
    "$GITLAB_HOST/api/v4/projects/$PROJECT_ID") || rc=$?
[ "$rc" = 0 ] || stop "project probe transport error (curl rc=$rc): GitLab state unknown — do not publish"
[ "$proj_code" = 200 ] || stop "project probe returned HTTP $proj_code (expected 200; 401/403/404 = invalid PAT or no access): state unknown — do not publish"
grep -q '"visibility"[ ]*:[ ]*"public"' "$TMPD/project.json" || \
    stop "project visibility is not confirmed public — anonymous router downloads would fail; fix the project first"

# --- anti-overwrite probe: every file must be CONFIRMED 404 ------------------
published=""
for f in $FILES; do
    rc=0
    code=$(curl $HTTPS_FLAGS --config "$CFG" -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 60 "$base_url/$f") || rc=$?
    if [ "$rc" -ne 0 ]; then
        stop "probe transport error for $f (curl rc=$rc): state unknown — do not publish"
    fi
    case "$code" in
        404) ;;
        200) published="$published $f" ;;
        *) stop "probe for $f returned unexpected HTTP $code — state unknown — do not publish" ;;
    esac
done
if [ -n "$published" ]; then
    abort "version $VER already (partially) published, found:$published — NEVER overwrite and NEVER delete files to repair a partial publication; the owner decides"
fi
log "all 6 files confirmed absent (404) for $VER — safe to publish"

# --- upload: five IPKs, then SHA256SUMS as the commit marker -----------------
for f in $FILES; do
    rc=0
    code=$(curl $HTTPS_FLAGS --config "$CFG" -sS -o /dev/null -w '%{http_code}' \
        --request PUT --upload-file "$BUNDLE_DIR/$f" \
        --connect-timeout 10 --max-time 600 "$base_url/$f") || rc=$?
    if [ "$rc" -ne 0 ]; then
        stop "upload transport error for $f (curl rc=$rc) — publication INCOMPLETE; do not retry blindly, do not delete files; the owner decides"
    fi
    if [ "$code" != "201" ]; then
        stop "upload for $f returned HTTP $code (expected 201) — publication INCOMPLETE; do not retry blindly, do not delete files; the owner decides"
    fi
    log "PUBLISHED $f (201)"
done

# --- mandatory anonymous post-verification (as the router sees the mirror) ---
vdir="$TMPD/anon"
mkdir -p "$vdir"
for f in $FILES; do
    rc=0
    anon_code=$(curl $HTTPS_FLAGS -sS -L --connect-timeout 10 --max-time 120 \
        -o "$vdir/$f" -w '%{http_code}' "$base_url/$f") || rc=$?
    [ "$rc" = 0 ] || stop "anonymous verification transport error for $f (curl rc=$rc) — mirror state unknown"
    [ "$anon_code" = 200 ] || stop "anonymous verification for $f returned HTTP $anon_code (expected 200) — mirror is NOT usable by routers"
    cmp -s "$vdir/$f" "$BUNDLE_DIR/$f" || \
        stop "anonymous download of $f differs from the published bundle bytes — mirror is NOT trustworthy"
    log "ANON-OK $f"
done

log "PUBLISHED AND ANONYMOUSLY VERIFIED: $VER at $base_url/"
log "next: run scripts/verify_mihomo_mirror.py --offline against the anonymously downloaded files (GITLAB-PUBLISH.md step 2b), then the BusyBox wget check"
exit 0
