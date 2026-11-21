#!/usr/bin/env python3
"""Offline, unprivileged regression for the Web installer OPKG record parser.

Tests the exact function extracted from kas-web-install.sh. No root, /opt,
network, package installs, fake OPKG process, or real device access required.
Issue #254: never accept absent, ambiguous or uninstalled package records.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import unittest


WEB = Path(__file__).resolve().parents[1] / "kas-web-install.sh"


def parser_from_web():
    source = WEB.read_text(encoding="utf-8")
    start_marker = "opkg_installed_version() {"
    if source.count(start_marker) != 1:
        raise AssertionError("expected exactly one OPKG version parser")
    start = source.index(start_marker)
    end = source.find("\n}\n", start)
    if end < 0:
        raise AssertionError("OPKG version parser has no closing brace")
    return source[start:end + 3], source


def shells():
    found = []
    for binary in ("/bin/sh", "/bin/dash", "/bin/bash"):
        if os.path.isfile(binary):
            found.append([binary])
    busybox = shutil.which("busybox")
    if busybox:
        found.append([busybox, "ash"])
    if not found:
        raise AssertionError("no shell is available for the regression")
    return found


def record(name="curl", version="8.23.0-1", state="install ok installed"):
    return f"Package: {name}\nVersion: {version}\nStatus: {state}\n"


class OpkgParserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parser, cls.web_source = parser_from_web()
        cls.test_shells = shells()

    def call(self, shell, package, status):
        # The full OPKG output is passed as an environment variable, never
        # interpolated into shell source; this also tests injection resistance.
        script = (self.parser +
                  '\nset -u\n'
                  'if _test_value=$(opkg_installed_version "$OPKG_NAME" "$OPKG_RECORD"); then\n'
                  '  printf "%s\\n" "$_test_value"\n'
                  'else\n'
                  '  exit 23\n'
                  'fi\n')
        env = dict(os.environ, OPKG_NAME=package, OPKG_RECORD=status)
        return subprocess.run(shell + ["-c", script], env=env,
                              capture_output=True, text=True, timeout=8)

    def test_valid_installed_records(self):
        for shell in self.test_shells:
            for package in ("curl", "libcurl"):
                for version in ("8.23.0-1", "8.15.0-2"):
                    with self.subTest(shell=shell, package=package, version=version):
                        out = self.call(shell, package,
                                        record(package, version))
                        self.assertEqual(out.returncode, 0, out.stderr)
                        self.assertEqual(out.stdout.strip(), version)

    def test_malformed_status_never_treated_as_installed(self):
        valid = record()
        bad_records = {
            "missing": "",
            "missing-package": valid.replace("Package: curl\n", ""),
            "missing-version": valid.replace("Version: 8.23.0-1\n", ""),
            "missing-status": valid.replace("Status: install ok installed\n", ""),
            "wrong-package": record(name="other"),
            "not-installed": record(state="deinstall ok config-files"),
            "hold-without-installed-ok": record(state="install hold installed"),
            "duplicate-version": valid + "Version: 8.23.0-1\n",
            "duplicate-package": valid + "Package: curl\n",
            "duplicate-status": valid + "Status: install ok installed\n",
            "multiple-records": valid + valid,
            "empty-version": record(version=""),
            "unsafe-version": record(version="8.23/../bad"),
            "version-with-whitespace": record(version="8.23 0-1"),
            "different-case": valid.replace("Status:", "status:"),
            "crlf-ambiguous": valid.replace("\n", "\r\n"),
        }
        for shell in self.test_shells:
            for label, value in bad_records.items():
                with self.subTest(shell=shell, case=label):
                    out = self.call(shell, "curl", value)
                    self.assertEqual(out.returncode, 23, (label, out.stdout, out.stderr))
                    self.assertFalse(out.stdout, (label, out.stdout))

    def test_installer_fails_before_loader_and_download(self):
        source = self.web_source
        self.assertIn("opkg_installed_version curl", source)
        self.assertIn("opkg_installed_version libcurl", source)
        fail = source.index("installed-package records missing, malformed or unconfirmed")
        loader = source.index("if ! LD_BIND_NOW=1 curl -V")
        download = source.index("get() {")
        self.assertLess(fail, loader)
        self.assertLess(loader, download)
        self.assertIn('if [ "$_curl_ver" != "$_libcurl_ver" ]; then', source)
        self.assertIn("version skew detected", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
