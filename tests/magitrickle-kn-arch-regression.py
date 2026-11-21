#!/usr/bin/env python3
"""No-network behavioral regressions for the KAS MagiTrickle KN ARCH PREP v1
block (fresh Entware architecture derivation/registration and the skip
policies for generic installs, ARMv7 and unknown platforms).

Every scenario extracts the marked fragments verbatim from install.sh and
runs them under /bin/sh with mocks: nothing is installed, nothing is
downloaded, and the host /opt is never touched (the registration fragment is
redirected with KAS_MT_ARCH_CONF into the scenario's temp dir).
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
SCRIPT = INSTALL.read_text(encoding="utf-8")

PREP_BEGIN = "# BEGIN MAGITRICKLE KN ARCH PREP v1 (issue #505 follow-up: fresh Entware)"
PREP_END = "# END MAGITRICKLE KN ARCH PREP v1"
PROV_BEGIN = "# BEGIN MAGITRICKLE PROVISION v1"
PROV_END = "# END MAGITRICKLE PROVISION v1"
FALLBACK_BEGIN = "# BEGIN MAGITRICKLE KN FALLBACK v1 (issue #505)"
FALLBACK_END = "# END MAGITRICKLE KN FALLBACK v1"

assert SCRIPT.count(PREP_BEGIN) == SCRIPT.count(PREP_END) == 1
assert SCRIPT.count(PROV_BEGIN) == SCRIPT.count(PROV_END) == 1
assert SCRIPT.count(FALLBACK_BEGIN) == SCRIPT.count(FALLBACK_END) == 1
PREP = SCRIPT.split(PREP_BEGIN, 1)[1].split(PREP_END, 1)[0]
PROVISION = SCRIPT.split(PROV_BEGIN, 1)[1].split(PROV_END, 1)[0]
FALLBACK = SCRIPT.split(FALLBACK_BEGIN, 1)[1].split(FALLBACK_END, 1)[0]

# The dispatch must sit AFTER the mt_provision_install definition: sh runs
# top-level commands in order and an earlier call would be "not found".
assert SCRIPT.index(PREP_BEGIN) < SCRIPT.index("mt_provision_install() {")
assert SCRIPT.index("mt_provision_install() {") < SCRIPT.index(
    "if mt_prepare_kn_arch; then")


def run_sh(code, env=None, timeout=15):
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run(["sh", "-s"], input=code, text=True, env=e,
                       capture_output=True, timeout=timeout)
    out = r.stdout + ("\nSTDERR: " + r.stderr if r.returncode else "")
    return r.returncode, out


MOCKS = r"""
set -eu
TMP="$TEST_TMP"
TRACE="$TMP/trace"
: > "$TRACE"
log() { printf 'log:%s\n' "$1" >> "$TRACE"; }
warn() { printf 'warn:%s\n' "$1" >> "$TRACE"; }
err() { printf 'err:%s\n' "$1" >> "$TRACE"; exit 77; }
KAS_MT_ARCH_CONF="$TMP/kas-mt-arch.conf"
export KAS_MT_ARCH_CONF
pkg_is_installed() {
    printf '%s\n' "$TEST_LIST_INSTALLED" | grep -q "^$1 " || return 1
}
kas_ledger_record() {
    if [ "${TEST_LEDGER_FAIL:-0}" = 1 ]; then return 1; fi
    printf 'ledger:%s|%s|%s\n' "$1" "$2" "$3" >> "$TRACE"
}
opkg() {
    case "$1" in
        print-architecture)
            # Simulate the default-mode conf glob: lines registered in the
            # KAS fragment become visible to every later print-architecture
            # call (verified against the official opkg; -f mode hides the
            # glob, but install.sh never uses -f on a device).
            printf '%b' "$TEST_PRINT_ARCH"
            if [ -f "$KAS_MT_ARCH_CONF" ]; then
                cat "$KAS_MT_ARCH_CONF"
            fi ;;
        status) printf '%b' "$TEST_STATUS" ;;
        list-installed) printf '%s\n' "$TEST_LIST_INSTALLED" ;;
        install) printf 'install:%s\n' "$2" >> "$TRACE" ;;
        *) return 1 ;;
    esac
}
"""


def prep_runner(print_arch, status="", list_installed="", ledger_fail="0"):
    code = MOCKS + FALLBACK + PREP
    code += """
if mt_prepare_kn_arch; then
    printf 'PROCEED:%s\\n' "$MT_KN_ARCH" >> "$TRACE"
else
    printf 'SKIP\\n' >> "$TRACE"
fi
"""
    env = dict(TEST_TMP=None, TEST_PRINT_ARCH=print_arch, TEST_STATUS=status,
               TEST_LIST_INSTALLED=list_installed, TEST_LEDGER_FAIL=ledger_fail)
    with tempfile.TemporaryDirectory() as d:
        env["TEST_TMP"] = d
        rc, out = run_sh(code, env)
        trace = (Path(d) / "trace").read_text()
        conf = Path(d) / "kas-mt-arch.conf"
        conf_text = conf.read_text() if conf.exists() else None
        return rc, out, trace, conf_text


class FreshDeviceRegistration(unittest.TestCase):

    def test_fresh_plain_arch_derives_and_registers_with_plus_one_priority(self):
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4 50\n')
        self.assertEqual(rc, 0, out)
        self.assertIn('PROCEED:mipsel-3.4_kn', trace)
        self.assertIn('log:Registered Keenetic Entware architecture: '
                      'arch mipsel-3.4_kn 51', trace)
        self.assertEqual(conf, 'arch mipsel-3.4_kn 51\n', repr(conf))
        self.assertIn('ledger:owned|repository|kas-mt-arch.conf', trace)

    def test_fresh_entware_like_priorities(self):
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4 250\n')
        self.assertEqual(rc, 0, out)
        self.assertEqual(conf, 'arch mipsel-3.4_kn 251\n', repr(conf))

    def test_fresh_aarch64_and_mips_variants(self):
        for plain, kn in (('aarch64-3.10', 'aarch64-3.10_kn'),
                          ('mips-3.4', 'mips-3.4_kn')):
            rc, out, trace, conf = prep_runner(
                'arch all 100\narch %s 250\n' % plain)
            self.assertEqual(rc, 0, out)
            self.assertIn('PROCEED:%s' % kn, trace)
            self.assertEqual(conf, 'arch %s 251\n' % kn, repr(conf))

    def test_print_architecture_without_priorities_falls_back_to_500(self):
        rc, out, trace, conf = prep_runner('arch all\narch mipsel-3.4\n')
        self.assertEqual(rc, 0, out)
        self.assertEqual(conf, 'arch mipsel-3.4_kn 500\n', repr(conf))

    def test_registration_is_idempotent_across_reruns(self):
        # First run registers; a rerun must not duplicate the line and must
        # not journal a second ownership record.
        with tempfile.TemporaryDirectory() as d:
            code = MOCKS + FALLBACK + PREP
            code += """
mt_prepare_kn_arch || true
mt_prepare_kn_arch || true
"""
            env = dict(TEST_TMP=d, TEST_PRINT_ARCH='arch all 100\narch mipsel-3.4 50\n',
                       TEST_STATUS="", TEST_LIST_INSTALLED="", TEST_LEDGER_FAIL="0")
            rc, out = run_sh(code, env)
            self.assertEqual(rc, 0, out)
            trace = (Path(d) / "trace").read_text()
            conf = (Path(d) / "kas-mt-arch.conf").read_text()
            self.assertEqual(conf, 'arch mipsel-3.4_kn 51\n', repr(conf))
            self.assertEqual(trace.count('ledger:owned|repository|kas-mt-arch.conf'), 1)

    def test_pre_registered_kn_arch_skips_registration(self):
        # e.g. a rerun on a device where a previous KAS run registered the
        # arch, or a device provisioned by hand: mt_select_kn_arch already
        # succeeds and nothing is written.
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4 50\narch mipsel-3.4_kn 51\n')
        self.assertEqual(rc, 0, out)
        self.assertIn('PROCEED:mipsel-3.4_kn', trace)
        self.assertIsNone(conf)
        self.assertNotIn('ledger:owned|repository|kas-mt-arch.conf', trace)


class FreshDeviceSkip(unittest.TestCase):

    def test_fresh_armv7_skips_without_writes(self):
        rc, out, trace, conf = prep_runner('arch all 100\narch armv7-3.2 50\n')
        self.assertEqual(rc, 0, out)
        self.assertIn('SKIP', trace)
        self.assertIn('warn:', trace)
        self.assertIsNone(conf)
        self.assertNotIn('ledger:', trace)

    def test_fresh_unknown_platform_skips(self):
        rc, out, trace, conf = prep_runner('arch all 100\narch x64-3.2 50\n')
        self.assertEqual(rc, 0, out)
        self.assertIn('SKIP', trace)
        self.assertIsNone(conf)

    def test_fresh_ambiguous_plain_archs_skip(self):
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mips-3.4 50\narch mipsel-3.4 60\n')
        self.assertEqual(rc, 0, out)
        self.assertIn('SKIP', trace)
        self.assertIsNone(conf)

    def test_registration_write_failure_skips_instead_of_aborting(self):
        # Point the fragment at an unwritable location: the scenario must end
        # in a clean skip (rc 0 overall), never in an installer abort.
        code = MOCKS + FALLBACK + PREP
        code += """
mkdir -p "$TEST_TMP/ro"
KAS_MT_ARCH_CONF="$TEST_TMP/ro/conf/sub/kas-mt-arch.conf"
export KAS_MT_ARCH_CONF
if mt_prepare_kn_arch; then printf 'PROCEED\\n' >> "$TRACE"; else printf 'SKIP\\n' >> "$TRACE"; fi
"""
        env = dict(TEST_TMP=None, TEST_PRINT_ARCH='arch all 100\narch mipsel-3.4 50\n',
                   TEST_STATUS="", TEST_LIST_INSTALLED="", TEST_LEDGER_FAIL="0")
        with tempfile.TemporaryDirectory() as d:
            env["TEST_TMP"] = d
            # Read-only parent for the configured fragment location.
            ro = Path(d, 'ro')
            ro.mkdir()
            ro.chmod(0o500)
            try:
                rc, out = run_sh(code, env)
            finally:
                ro.chmod(0o700)
            self.assertEqual(rc, 0, out)
            trace = (Path(d) / "trace").read_text()
            self.assertIn('SKIP', trace)
            self.assertNotIn('err:', trace)

    def test_ledger_failure_aborts_via_err(self):
        # The fragment was written but the ownership ledger refuses: the
        # mutation must never stay unowned, so the scenario must die through
        # err (exit 77), matching the magitrickle.conf convention.
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4 50\n', ledger_fail="1")
        self.assertEqual(rc, 77, out)
        self.assertIn('err:Cannot journal the KAS MagiTrickle architecture registration', trace)
        self.assertIsNotNone(conf)


class AlreadyInstalledPolicy(unittest.TestCase):

    def test_existing_generic_install_is_left_alone(self):
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4 50\n',
            status='Package: magitrickle\nVersion: 0.8.2-1\n'
                   'Status: install ok installed\nArchitecture: mipsel-3.4\n',
            list_installed='magitrickle 0.8.2-1')
        self.assertEqual(rc, 0, out)
        self.assertIn('SKIP', trace)
        self.assertIn('warn:MagiTrickle is installed with non-Keenetic architecture', trace)
        self.assertIsNone(conf)
        self.assertNotIn('install:', trace)
        self.assertNotIn('ledger:', trace)

    def test_existing_kn_install_proceeds_without_registration(self):
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4 50\narch mipsel-3.4_kn 51\n',
            status='Package: magitrickle\nVersion: 0.8.2-2\n'
                   'Status: install user installed\nArchitecture: mipsel-3.4_kn\n',
            list_installed='magitrickle 0.8.2-2')
        self.assertEqual(rc, 0, out)
        self.assertIn('PROCEED:mipsel-3.4_kn', trace)
        self.assertIsNone(conf)
        self.assertNotIn('install:', trace)

    def test_existing_ambiguous_status_refuses_to_guess(self):
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4_kn 51\n',
            status='Package: magitrickle\nStatus: install ok installed\n'
                   'Architecture: mipsel-3.4_kn\n'
                   'Architecture: mipsel-3.4\n',
            list_installed='magitrickle 0.8.2-2')
        self.assertEqual(rc, 0, out)
        self.assertIn('SKIP', trace)
        self.assertIn('ambiguous', trace)

    def test_existing_unparseable_status_skips(self):
        rc, out, trace, conf = prep_runner(
            'arch all 100\narch mipsel-3.4_kn 51\n',
            status='Package: magitrickle\nStatus: install ok installed\n',
            list_installed='magitrickle 0.8.2-2')
        self.assertEqual(rc, 0, out)
        self.assertIn('SKIP', trace)
        self.assertIn('not readable', trace)


class FragmentStructure(unittest.TestCase):

    def test_provision_function_is_defined_between_markers(self):
        self.assertIn('mt_provision_install() {', PROVISION)
        self.assertIn('mt_confirm_after_start || true', PROVISION)

    def test_prep_provision_dispatch_assemble_parses(self):
        # The whole new region must parse as one unit under the target shell:
        # the wrapped provisioning body is executed nowhere else in the
        # no-network suites, so a syntax slip inside the reindented block
        # would only surface on a device.
        code = 'set -eu\n' + PREP + '\n' + PROVISION + '\n' + \
            'if mt_prepare_kn_arch; then\n    mt_provision_install\nelse\n' \
            '    : \nfi\n'
        r = subprocess.run(["sh", "-n"], input=code, text=True,
                           capture_output=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_prep_does_not_download_or_install(self):
        # The prep block must stay free of transport and package mutations:
        # downloads/installs belong to the provisioning body and fallback.
        # Strip comments first — the design comment may name the helper.
        code_only = '\n'.join(l for l in PREP.splitlines()
                              if not l.lstrip().startswith('#'))
        for forbidden in ('curl ', 'wget ', 'opkg install', 'add_repo.sh',
                          'download_small_file_bounded'):
            self.assertNotIn(forbidden, code_only)

    def test_registration_fragment_uses_kas_owned_conf_only(self):
        self.assertIn('/opt/etc/opkg/kas-mt-arch.conf', PREP)
        # Entware's main conf and the helper-managed feed conf are never
        # referenced as write targets (the comment may mention them only).
        self.assertNotIn('/opt/etc/opkg.conf', PREP)
        self.assertNotIn('/opt/etc/opkg/magitrickle.conf', PREP)

    def test_fallback_pins_unchanged(self):
        # The pinned SHA/size inventory must survive the fix untouched.
        self.assertIn('ad2732a4ab3d25abbf38a65ab8306d22138a959173234f6b2deb5326923fcd93', FALLBACK)
        self.assertIn('5a10083cc063731536d8c7820c008348e99a16cf821534f51f1a415f50421c0e', FALLBACK)
        self.assertIn('0.8.2-2_entware_$MT_KN_ARCH.ipk', FALLBACK)
        self.assertIn('0.8.2-1_entware_$MT_KN_ARCH.ipk', FALLBACK)
        self.assertIn('pkg_is_installed magitrickle && return 1', FALLBACK)


if __name__ == "__main__":
    unittest.main()
