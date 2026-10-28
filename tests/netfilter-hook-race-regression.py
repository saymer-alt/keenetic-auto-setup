#!/usr/bin/env python3
"""Deterministic, router-free proof that a Netfilter rewrite cannot be silently ignored."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "020-bypass-wa.sh"

# A disposable mock xtables backend. A native KeeneticOS rewrite removes
# the custom chain between its creation and the next -C/-A operation.
MOCK_IPTABLES = """#!/bin/sh
set -eu
state=$NETFILTER_TEST_STATE
[ "$1" = -w ] && [ "$2" = -t ] && [ "$3" = mangle ] || exit 70
shift 3
case "$1" in
 -N)
    [ -e "$state/chain" ] && exit 1
    : > "$state/chain"; exit 0 ;;
 -F)
    [ -e "$state/chain" ] || exit 1
    : > "$state/rules"; exit 0 ;;
 -C)
    if [ "$2" = PREROUTING ] && [ "$NETFILTER_TEST_RESET" = 1 ] && [ ! -e "$state/reset-done" ]; then
        : > "$state/reset-done"
        rm -f "$state/chain" "$state/rules" "$state/links"
    fi
    exit 1 ;;
 -A)
    if [ "$2" = PREROUTING ]; then
        if [ ! -e "$state/chain" ]; then
            printf '%s\n' 'iptables: No chain/target/match by that name.' >&2
            exit 1
        fi
        printf '%s\n' 'PREROUTING LINK' >> "$state/links"
        exit 0
    fi
    if [ ! -e "$state/chain" ]; then
        printf '%s\n' 'iptables: No chain/target/match by that name.' >&2
        exit 1
    fi
    printf '%s\n' "$*" >> "$state/rules"
    exit 0 ;;
 *) exit 71 ;;
esac
"""


class HookRaceTests(unittest.TestCase):
    def run_hook(self, inject_reset=False, existing=False):
        with tempfile.TemporaryDirectory(prefix="kas-netfilter-race-") as temporary:
            work = Path(temporary)
            tools = work / "bin"
            state = work / "state"
            tools.mkdir()
            state.mkdir()
            for name, contents in {
                "iptables": MOCK_IPTABLES,
                "curl": "#!/bin/sh\nprintf '%s\\n' '[{\"description\":\"bypass_wa\",\"mark\":\"ffffaab\"}]'\n",
                "jq": "#!/bin/sh\nprintf '%s\\n' ffffaab\n",
                "lsmod": "#!/bin/sh\nprintf '%s\\n' 'xt_multiport 1024 0'\n",
            }.items():
                path = tools / name
                path.write_text(contents)
                path.chmod(0o700)
            if existing:
                (state / "chain").touch()
                (state / "rules").write_text("old rule\n")

            # Run the exact production hook with fake executables prepended.
            # No real router, kernel firewall, or iptables invocation.
            source = HOOK.read_text()
            shadow = re.sub(
                r"(?m)^PATH=.*$", 'PATH="$NETFILTER_TEST_BIN:/usr/bin:/bin"', source
            )
            self.assertNotEqual(shadow, source, "hook PATH substitution unavailable")
            candidate = work / "hook.sh"
            candidate.write_text(shadow)
            env = dict(
                os.environ,
                NETFILTER_TEST_BIN=str(tools),
                NETFILTER_TEST_STATE=str(state),
                NETFILTER_TEST_RESET="1" if inject_reset else "0",
                type="iptables",
                table="mangle",
            )
            result = subprocess.run(
                ["/bin/sh", str(candidate)], env=env,
                capture_output=True, text=True, timeout=12,
            )
            count = (
                len((state / "rules").read_text().splitlines())
                if (state / "rules").exists() else 0
            )
            linked = (
                len((state / "links").read_text().splitlines())
                if (state / "links").exists() else 0
            )
            return result.returncode, count, linked, result.stderr

    def test_clean_first_apply_creates_all_rules(self):
        code, count, linked, stderr = self.run_hook()
        self.assertEqual((code, count, linked), (0, 3, 1), stderr)

    def test_existing_chain_can_be_refreshed(self):
        code, count, linked, stderr = self.run_hook(existing=True)
        self.assertEqual((code, count, linked), (0, 3, 1), stderr)

    def test_chain_reset_between_commands_must_fail_not_report_success(self):
        code, count, linked, stderr = self.run_hook(inject_reset=True)
        self.assertNotEqual(code, 0, "lost chain must not produce a false success")
        self.assertEqual((count, linked), (0, 0), "fixture must erase the chain")
        self.assertIn("iptables", stderr)


if __name__ == "__main__":
    unittest.main()
