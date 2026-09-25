#!/usr/bin/env python3
"""Structural regressions for high-consequence maintenance transactions.

These checks inspect the real production scripts instead of emulating KeeneticOS.
They pin ordering and recovery invariants learned from live failures.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def fail(message: str) -> None:
    print(f"[FAIL] {message}", file=sys.stderr)
    raise SystemExit(1)

def load(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def require(text: str, needle: str, label: str) -> int:
    pos = text.find(needle)
    if pos < 0:
        fail(f"{label}: missing anchor {needle!r}")
    return pos

def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        fail(f"{label}: forbidden pattern returned: {needle!r}")

def ordered(text: str, label: str, *needles: str) -> None:
    cursor = -1
    for needle in needles:
        pos = text.find(needle, cursor + 1)
        if pos < 0:
            fail(f"{label}: missing ordered anchor {needle!r}")
        cursor = pos

def test_updater() -> None:
    text = load("update-mihomo.sh")
    label = "update-mihomo transaction"
    ordered(
        text, label,
        'log "Candidate staged at $STAGE_BIN"',
        'TMP_BACKUP="$TMP_DIR/mihomo.backup.$$"',
        '# 12. Stop the old Mihomo BEFORE the first execution of the new binary.',
        'REPLACEMENT_STARTED=1',
        'if ! mv -f "$STAGE_BIN" "$MIHOMO_PATH"; then',
        '# 16. Verify the replaced binary (version + config) — rollback on any failure',
    )
    require(text, 'cp -f "$TMP_BACKUP" "$MIHOMO_PATH"', label)
    require(text, 'UPDATE FAILED AND RECOVERY FAILED', label)
    require(text, 'update failed, previous version restored', label)
    require(text, 'Mihomo is running again (watchdog restart?) - stopping before the commit', label)
    require(text, 'MAINT_MARKER="/tmp/mihomo.maintenance"', label)
    require(text, 'BINARY_STATE="/opt/etc/keenetic-auto-setup-mihomo.state"', label)
    require(text, 'TMP_STATE_BACKUP="$TMP_DIR/mihomo-binary-state.backup.$"', label)
    require(text, 'restore_binary_state()', label)
    ordered(
        text, label,
        'if ! mv -f "$STAGE_BIN" "$MIHOMO_PATH"; then',
        'STATE_COMMITTED=1',
        'if ! mv -f "$STATE_STAGE" "$BINARY_STATE"; then',
        '# 17. Start service and verify process',
    )
    require(text, 'if ! restore_binary_state; then', label)
    forbid(text, 'rm -f "$MIHOMO_PATH"', label)
    if text.count("rollback_and_exit ") < 4:
        fail(f"{label}: too few post-commit rollback call sites")
    print("[OK] update-mihomo transaction ordering and rollback are pinned")

def test_watchdog_updater() -> None:
    text = load("update-watchdog.sh")
    label = "watchdog updater transaction"
    require(text, 'STAGE_FILE="/opt/bin/.mihomo_watchdog.sh.new.$$"', label)
    ordered(
        text, label,
        'if ! sh -n "$TMP_FILE"; then',
        'if [ -f "$WATCHDOG_BIN" ] && cmp -s "$TMP_FILE" "$WATCHDOG_BIN" 2>/dev/null; then',
        'if ! cp -f "$TMP_FILE" "$STAGE_FILE"; then',
        'if ! sh -n "$STAGE_FILE"; then',
        'if ! mv -f "$STAGE_FILE" "$WATCHDOG_BIN"; then',
    )
    require(text, 'preserved, nothing migrated', label)
    require(text, 'contains unrecognized content - preserved, nothing changed', label)
    require(text, 'if cp -f "$WATCHDOG_CRON" "$CRON_LEGACY_BAK"', label)
    require(text, 'chmod -x "$CRON_LEGACY_BAK"', label)
    forbid(text, 'rm -f "$WATCHDOG_CRON"', label)
    forbid(text, 'mv -f "$TMP_FILE" "$WATCHDOG_BIN"', label)
    print("[OK] update-watchdog no-op/validation/atomic-commit and preservation are pinned")

def test_mips_migrator() -> None:
    text = load("migrate-mihomo-mips.sh")
    label = "MIPS migrator transaction"
    check_pos = require(text, 'if [ "$CHECK_ONLY" -eq 1 ]; then', label)
    apply_pos = require(text, 'echo "=== Mihomo MIPS stack migration ==="', label)
    lock_pos = text.find("acquire_lock", apply_pos)
    if not (check_pos < apply_pos < lock_pos):
        fail(f"{label}: --check must finish before apply-mode locking")
    ordered(
        text, label,
        'if [ ! -f "$BACKUP" ]; then',
        'cp -f "$CONFIG" "$BACKUP"',
        "if ! sed ",
        'log "Testing the migrated config with mihomo -t..."',
        'REPLACEMENT_DONE=1',
        'if ! mv -f "$TMP_NEW" "$CONFIG"; then',
        'log "Starting Mihomo with the migrated config..."',
    )
    require(text, 'Backup already exists, kept: $BACKUP', label)
    require(text, 'cp -f "$BACKUP" "$CONFIG"', label)
    require(text, 'ensure_stopped_before_exec', label)
    require(text, 'executable version/support probes skipped (one-Mihomo invariant)', label)
    require(text, 'MAINT_MARKER="/tmp/mihomo.maintenance"', label)
    print("[OK] MIPS migrator read-only check, backup, validation and rollback are pinned")

def main() -> int:
    test_updater()
    test_watchdog_updater()
    test_mips_migrator()
    print("[OK] High-consequence transaction invariants passed")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
