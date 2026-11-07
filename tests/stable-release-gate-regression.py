"""Release-gate workflow contract (issue #53 review of PR #319).

Pins the caller-to-reusable mapping of .github/workflows/
stable-release-gate.yml so the release gate can never silently dispatch the
wrong scenario: the legacy-bridge positive case must set legacy_ip_global
(the emulator default false is the deliberately failing negative A/B
control), the emulator commit stays pinned, secrets are never inherited and
the job is least-privilege. Infrastructure contract only; no production KAS
code is involved.
"""
import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).parent.parent / '.github/workflows/stable-release-gate.yml'
PINNED_EMULATOR = 'c095a7f31378a2f0ceefed983633a07707ad2847'

# The only GH-expression forms the gate may use for scenario-dependent
# inputs: scenario comparisons combined with quoted literals through
# && / || (the JS-style ternary the reusable workflow input needs).
EXPR = re.compile(
    r"^\$\{\{ inputs\.scenario == '(uninstall-packages|kas-baseline|kas-legacy-bridge)'"
    r"(?:\s*(?:&&|\|\|)\s*'[a-z-]+'|\s*(?:&&|\|\|)\s*inputs\.scenario == "
    r"'(uninstall-packages|kas-baseline|kas-legacy-bridge)')*\s*\}\}$")


def _operand(part, scenario):
    part = part.strip()
    if part.startswith("'"):
        return part.strip("'")
    if part.startswith('inputs.scenario'):
        _, _, rhs = part.partition(' == ')
        return scenario == rhs.strip("'")
    raise ValueError('unallowed expression operand: ' + part)


def evaluate(expression, scenario):
    """Evaluate an allowlisted scenario expression without eval()."""
    body = expression[3:-2].strip()  # strip '${{' and '}}'
    out = False
    for or_group in re.split(r'\s*\|\|\s*', body):
        ok, last = True, True
        for part in re.split(r'\s*&&\s*', or_group):
            value = _operand(part, scenario)
            ok = ok and bool(value)
            last = value
        if ok and last:
            return last
    return out


def with_value(source, key):
    m = re.search(r'^\s+' + key + r': (.+)$', source, re.M)
    return m.group(1).strip() if m else None


class StableReleaseGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text(encoding='utf-8')

    def test_reusable_workflow_is_pinned(self):
        self.assertIn('ported-entware-kas.yml@' + PINNED_EMULATOR, self.source)

    def test_no_secrets_inheritance_anywhere(self):
        self.assertNotIn('secrets:', self.source)

    def test_least_privilege_read_only(self):
        self.assertRegex(self.source, r'(?m)^permissions:\r?\n  contents: read\r?\n')
        self.assertRegex(self.source,
                         r'(?m)^  native-gate:\r?\n    needs: core-sync-evidence\r?\n'
                         r'    permissions:\r?\n      contents: read\r?\n')

    def test_emulator_ref_is_pinned_literal_without_override_input(self):
        self.assertEqual(with_value(self.source, 'emulator_ref'), PINNED_EMULATOR)
        self.assertNotIn('emulator_ref:', self.source.split('inputs:')[1].split('permissions:')[0])

    def test_legacy_positive_scenario_sets_ip_global_true(self):
        expr = with_value(self.source, 'legacy_ip_global')
        self.assertIsNotNone(expr, 'legacy_ip_global must be passed to the reusable workflow')
        self.assertRegex(expr, EXPR)
        self.assertTrue(evaluate(expr, 'kas-legacy-bridge'))
        self.assertFalse(evaluate(expr, 'uninstall-packages'))
        self.assertFalse(evaluate(expr, 'kas-baseline'))

    def test_stage_and_profile_mapping_table(self):
        stage_expr = with_value(self.source, 'stage')
        profile_expr = with_value(self.source, 'profile')
        expected = {
            'uninstall-packages': ('uninstall-packages', 'baseline'),
            'kas-baseline': ('kas', 'baseline'),
            'kas-legacy-bridge': ('kas', 'legacy-bridge'),
        }
        for scenario, (stage, profile) in expected.items():
            self.assertEqual(evaluate(stage_expr, scenario), stage, 'stage for ' + scenario)
            self.assertEqual(evaluate(profile_expr, scenario), profile, 'profile for ' + scenario)

    def test_release_reconciliation_precedes_native_gate(self):
        self.assertIn('core-sync-evidence:', self.source)
        self.assertIn('needs: core-sync-evidence', self.source)
        self.assertIn('scripts/core-sync-check.py', self.source)
        self.assertIn('tests/core-sync-guard-regression.py', self.source)
        self.assertIn('report.json', self.source)
        self.assertIn('identity.json', self.source)
        self.assertIn('S00ubifs', self.source)
        self.assertIn('actions/upload-artifact@v4', self.source)

    def test_sequential_dispatch_documented(self):
        self.assertIn('SEQUENTIAL DISPATCH REQUIRED', self.source)


if __name__ == '__main__':
    unittest.main()
