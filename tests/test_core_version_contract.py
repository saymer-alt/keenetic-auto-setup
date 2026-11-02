#!/usr/bin/env python3
"""Phase-A version contract for the lab-only kas-core package (issue #295).

Two independent layers:

1. Host-only (no opkg): the builder refuses any version outside the
   lab qualification scheme and refuses non-SHA sources, so an accidental
   release-shaped version cannot enter the qualification pipeline.
2. Real Entware opkg (KAS_TEST_OPKG-gated, disposable roots): the
   0.0.0~proofN-N scheme is strictly monotonic under `opkg
   compare-versions`, so guarded activation ordering (older bundle can
   never outrank a newer one) holds in the package manager itself, and a
   future numbered release outranks every lab proof build.

No live-root installation is attempted or permitted; see
packaging/core/README.md and docs/kas-core-ipk-plan-20261030.md.
"""
import os
import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BUILDER = REPO / 'packaging/core/build-ipk.py'
SOURCE_SHA = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()

# Mirrors build-ipk.py: the ONLY accepted lab version shape.
PROOF_SCHEME = re.compile(r'0\.0\.0~proof[0-9]+-[0-9]+')


def run_builder(*extra):
    return subprocess.run(['python3', str(BUILDER), *extra],
                          capture_output=True, text=True, cwd=REPO)


def opkg_binary():
    return os.environ.get('KAS_TEST_OPKG')


class CoreVersionContractHostTests(unittest.TestCase):
    """Builder-side refusals that must hold on any host, without opkg."""

    def test_builder_rejects_release_shaped_versions(self):
        for bad in ('1.0.0-1', '0.0.1-1', '1.8.5', '0.0.0~proof-1', '0.0.0~proofX-1',
                    '0.0.0~proof1', '0.0.0~proof01-1~hotfix', '0.0.0~PROOF1-1'):
            result = run_builder('--version', bad, '--source-sha', SOURCE_SHA,
                                 '--output', '.')
            self.assertNotEqual(result.returncode, 0, 'builder accepted %r' % bad)
            self.assertIn('0.0.0~proof', result.stderr, bad)

    def test_builder_rejects_short_or_dirty_source_sha(self):
        for bad in ('', 'HEAD', 'd411494', 'd411494ec751d4c8933851dc4b3163a7ac4d49a',
                    'ZZZZ494ec751d4c8933851dc4b3163a7ac4d49a3'):
            result = run_builder('--version', '0.0.0~proof1-1', '--source-sha', bad,
                                 '--output', '.')
            self.assertNotEqual(result.returncode, 0, 'builder accepted sha %r' % bad)

    def test_scheme_regex_matches_only_growing_lab_versions(self):
        self.assertIsNone(PROOF_SCHEME.fullmatch('0.0.0~proof1'))
        self.assertIsNotNone(PROOF_SCHEME.fullmatch('0.0.0~proof1-1'))
        self.assertIsNotNone(PROOF_SCHEME.fullmatch('0.0.0~proof12-34'))


@unittest.skipUnless(opkg_binary(), 'set KAS_TEST_OPKG to the pinned official Entware opkg')
class CoreVersionContractOpkgTests(unittest.TestCase):
    """Real opkg compare-versions ordering inside the qualification scheme."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(__import__('tempfile').mkdtemp(prefix='kas-core-ver-'))
        cls.config = cls.tmp / 'opkg.conf'
        cls.config.write_text('dest root /\narch all 100\n')

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def compare(self, left, op, right, expected=0):
        result = subprocess.run([opkg_binary(), '-f', str(self.config),
                                 'compare-versions', left, op, right],
                                capture_output=True, text=True)
        self.assertEqual(
            result.returncode, expected,
            'opkg compare-versions %r %s %r -> rc %s (expected %s)\n%s%s'
            % (left, op, right, result.returncode, expected, result.stdout, result.stderr))
        return result

    def test_proof_scheme_is_strictly_monotonic(self):
        self.compare('0.0.0~proof1-1', '<<', '0.0.0~proof2-1')
        self.compare('0.0.0~proof2-1', '<<', '0.0.0~proof10-1', )  # numeric, not lexicographic
        self.compare('0.0.0~proof1-1', '<<', '0.0.0~proof1-2')
        self.compare('0.0.0~proof9-9', '<<', '0.0.0~proof10-1')
        self.compare('0.0.0~proof10-1', '<<', '0.0.0~proof10-2')

    def test_proof_versions_never_outrank_a_numbered_release(self):
        # When a real numbered release exists (phase B+), every lab proof
        # build must sort strictly below it so migration ordering is stable.
        self.compare('0.0.0~proof99-99', '<<', '1.8.5')
        self.compare('0.0.0~proof1-1', '<<', '0.0.1-1')

    def test_proof_equality_is_exact(self):
        self.compare('0.0.0~proof2-1', '=', '0.0.0~proof2-1')
        self.assertNotEqual(
            subprocess.run([opkg_binary(), '-f', str(self.config), 'compare-versions',
                            '0.0.0~proof2-1', '=', '0.0.0~proof2-2'],
                           capture_output=True, text=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
