#!/usr/bin/env python3
"""Offline regression tests for tests/docs-links.py.

Each case builds a throwaway repository in a temporary directory (the validator
resolves its root from its own location), writes synthetic Markdown and runs the
real script with the current interpreter. No network, no dependencies.
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
VALIDATOR = REPO / "tests" / "docs-links.py"

# The pinned-preview guard also fails when an evergreen guide is absent, so every
# fixture must ship the full expected set.
EVERGREEN = (
    "README.md",
    "docs/EN/README.md",
    "docs/26-kas-web-beta-install.md",
    "docs/EN/WEB_BETA_INSTALL.md",
    "web/control-center/packaging/README.md",
)


class DocsLinksTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        (self.root / "tests").mkdir(parents=True)
        shutil.copy2(VALIDATOR, self.root / "tests" / "docs-links.py")
        self.write("AGENTS.md", "# AGENTS\n")
        self.write("README.md", "# KAS\n\nSee [AGENTS](AGENTS.md).\n")
        for relative in EVERGREEN[1:]:
            self.write(relative, "# guide\n")

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_validator(self):
        result = subprocess.run(
            [sys.executable, str(self.root / "tests" / "docs-links.py")],
            text=True, capture_output=True,
        )
        return result.returncode, result.stdout + result.stderr

    def assert_pass(self):
        code, output = self.run_validator()
        self.assertEqual(code, 0, output)
        return output

    def assert_fail(self, needle):
        code, output = self.run_validator()
        self.assertEqual(code, 1, output)
        self.assertIn(needle, output)
        return output

    # --- existing contract: real broken links must still fail -----------------

    def test_missing_local_link_fails(self):
        self.write("docs/page.md", "[gone](missing.md)\n")
        self.assert_fail("missing.md")

    def test_escape_repository_root_fails(self):
        self.write("README.md", "# KAS\n\n[up](../../outside.md)\n")
        self.assert_fail("escapes repository root")

    def test_clean_tree_passes(self):
        output = self.assert_pass()
        self.assertIn("[OK] Local Markdown links", output)

    # --- defect 1: link-like text inside code is not a link -------------------

    def test_fenced_block_link_is_ignored(self):
        self.write(
            "docs/page.md",
            "# Example\n\n```markdown\n[example](does-not-exist.md)\n```\n\n"
            "Real [link](../AGENTS.md).\n",
        )
        self.assert_pass()

    def test_tilde_fence_link_is_ignored(self):
        self.write("docs/page.md", "~~~\n[example](nope.md)\n~~~\n")
        self.assert_pass()

    def test_inline_code_span_link_is_ignored(self):
        self.write("docs/page.md", "Write `[x](nope.md)` in the note.\n")
        self.assert_pass()

    def test_link_after_closed_fence_is_checked(self):
        self.write(
            "docs/page.md",
            "```\n[inside](nope.md)\n```\n\n[outside](also-nope.md)\n",
        )
        self.assert_fail("also-nope.md")

    # --- defect 4: HTML comments take priority over fenced code ----------------

    def test_backticks_inside_html_comment_do_not_open_fence(self):
        # A triple backtick inside an HTML comment must not start a fenced block;
        # the real broken link after the comment is still checked.
        self.write(
            "docs/page.md",
            "<!--\n```\n-->\n[broken](missing.md)\n",
        )
        self.assert_fail("missing.md")

    def test_multiple_comments_on_one_line_are_all_masked(self):
        self.write(
            "docs/page.md",
            "<!-- first --> <!-- [fake](missing.md) -->\n"
            "Real [link](../AGENTS.md).\n",
        )
        self.assert_pass()

    def test_link_inside_html_comment_is_ignored(self):
        # Content of an HTML comment is never a link.
        self.write(
            "docs/page.md",
            "<!-- [fake](does-not-exist.md) -->\n\nReal [link](../AGENTS.md).\n",
        )
        self.assert_pass()

    def test_markdown_resumes_after_multiline_comment(self):
        # Normal Markdown is restored after the comment closes.
        self.write(
            "docs/page.md",
            "<!--\ncomment [fake](nope.md)\n-->\n[ok](../AGENTS.md)\n[bad](also-nope.md)\n",
        )
        self.assert_fail("also-nope.md")

    def test_fence_inside_comment_then_code_after_is_guarded(self):
        # Backticks inside a comment are ignored, and a genuine fenced block after
        # the comment is still masked.
        self.write(
            "docs/page.md",
            "<!-- ``` -->\n```\n[fake](nope.md)\n```\nReal [link](../AGENTS.md).\n",
        )
        self.assert_pass()

    def test_bad_closing_fence_is_not_accepted(self):
        # A shorter closing marker (``) must not close a ``` fence, so everything
        # up to the genuine ``` closer stays masked (no false broken link).
        self.write(
            "docs/page.md",
            "```\n[fake](nope.md)\n``\n[still-inside](also-nope.md)\n```\n"
            "Real [link](../AGENTS.md).\n",
        )
        self.assert_pass()

    # --- defect 2: balanced parentheses in destinations -----------------------

    def test_unterminated_link_does_not_count_as_destination(self):
        self.write(
            "docs/page.md",
            "[incomplete](missing.md\nReal [link](../AGENTS.md).\n",
        )
        self.assert_pass()

    def test_local_link_with_parentheses_resolves(self):
        self.write("docs/guide_(v2).md", "# guide\n")
        self.write("docs/page.md", "[guide](guide_(v2).md)\n")
        self.assert_pass()

    def test_external_url_with_parentheses_is_skipped(self):
        self.write(
            "docs/page.md",
            "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))\n",
        )
        self.assert_pass()

    def test_nested_parentheses_destination_resolves(self):
        # A destination with several nested balanced parentheses resolves fully.
        self.write("docs/guide_(v2(beta)).md", "# guide\n")
        self.write("docs/page.md", "[guide](guide_(v2(beta)).md)\n")
        self.assert_pass()

    def test_deeply_nested_parentheses_destination(self):
        self.write("docs/a_(b(c(d(e)))).md", "# guide\n")
        self.write("docs/page.md", "[guide](a_(b(c(d(e)))).md)\n")
        self.assert_pass()

    def test_nested_parentheses_with_title(self):
        self.write("docs/guide_(v2(beta)).md", "# guide\n")
        self.write(
            "docs/page.md",
            '[guide](guide_(v2(beta)).md "Nested title")\n',
        )
        self.assert_pass()

    def test_external_url_with_nested_parentheses_is_skipped(self):
        self.write(
            "docs/page.md",
            "[pkg](https://pypi.org/project/some-pkg_(v2(beta)))/)\n",
        )
        self.assert_pass()

    def test_percent_encoded_parentheses_in_destination(self):
        self.write("docs/a_(b).md", "# guide\n")
        self.write("docs/page.md", "[guide](a_%28b%29.md)\n")
        self.assert_pass()

    def test_backtick_in_destination_after_comment_is_checked(self):
        # The regression in the brief: backticks inside an HTML comment open no
        # fence, so the later broken link is reported.
        self.write(
            "docs/page.md",
            "<!--\n```\n-->\n[broken](missing_(v2(beta)).md)\n",
        )
        self.assert_fail("missing_(v2(beta)).md")

    # --- defect 3: scheme-less web destinations -------------------------------

    def test_www_destination_is_external(self):
        self.write("docs/page.md", "[site](www.example.com/page)\n")
        self.assert_pass()

    # --- link shapes that must keep working ----------------------------------

    def test_angle_bracket_destination_with_space(self):
        self.write("docs/a b.md", "# spaced\n")
        self.write("docs/page.md", "[spaced](<a b.md>)\n")
        self.assert_pass()

    def test_title_after_destination(self):
        self.write("docs/page.md", '[AGENTS](../AGENTS.md "Agent rules")\n')
        self.assert_pass()

    def test_percent_encoded_destination(self):
        self.write("docs/a b.md", "# spaced\n")
        self.write("docs/page.md", "[spaced](a%20b.md)\n")
        self.assert_pass()

    def test_anchor_only_and_absolute_slash(self):
        self.write("docs/page.md", "[top](#top)\n\n[root](/AGENTS.md)\n")
        self.assert_pass()

    def test_directory_destination_is_accepted(self):
        (self.root / "docs" / "sub").mkdir()
        self.write("docs/page.md", "[dir](sub)\n")
        self.assert_pass()

    # --- symlinks ------------------------------------------------------------

    def test_symlink_inside_repository_passes(self):
        try:
            (self.root / "alias.md").symlink_to(self.root / "AGENTS.md")
        except (OSError, NotImplementedError):
            self.skipTest("symlinks are not permitted on this host")
        self.write("docs/page.md", "[alias](../alias.md)\n")
        self.assert_pass()

    def test_symlink_outside_repository_fails(self):
        outside = Path(self.tmp.name) / "outside.md"
        outside.write_text("# outside\n", encoding="utf-8")
        try:
            (self.root / "escape.md").symlink_to(outside)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks are not permitted on this host")
        self.write("docs/page.md", "[escape](../escape.md)\n")
        self.assert_fail("escapes repository root")

    # --- protections that must stay intact -----------------------------------

    def test_pasted_artifact_still_fails(self):
        self.write("docs/page.md", "Path: sandbox:/mnt/data/report.md\n")
        self.assert_fail("sandbox path")

    def test_artifact_inside_fence_still_fails(self):
        self.write("docs/page.md", "```\nfilecite turn3file0\n```\n")
        self.assert_fail("file citation token")

    def test_chat_wrapper_still_fails(self):
        self.write("docs/page.md", "[Message sent at 10:42]\n")
        self.assert_fail("chat timestamp wrapper")

    def test_pinned_beta_url_still_fails(self):
        self.write(
            "README.md",
            "# KAS\n\nhttps://github.com/saymer-alt/keenetic-auto-setup/"
            "releases/tag/v1.9.0-beta.2\n",
        )
        self.assert_fail("pinned preview")

    def test_pinned_beta_version_still_fails(self):
        self.write("README.md", "# KAS v1.9.0-beta.3\n")
        self.assert_fail("pinned preview")

    def test_missing_evergreen_guide_still_fails(self):
        (self.root / "docs" / "26-kas-web-beta-install.md").unlink()
        self.assert_fail("missing expected evergreen guide")


if __name__ == "__main__":
    unittest.main(verbosity=2)
