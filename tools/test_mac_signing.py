#!/usr/bin/env python3
"""Exercise nested XCTest signing without requiring Xcode or a certificate."""
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

sign_products = runpy.run_path(str(Path(__file__).with_name("test-mac.py")))["sign_test_products"]


class MacTestSigningTests(unittest.TestCase):
    def test_changed_dylib_and_enclosing_framework_are_signed_before_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Writer.app"
            framework = app / "Contents/Frameworks/XCUIAutomation.framework"
            dylib = framework / "Versions/A/Libraries/libXCTest.dylib"
            dylib.parent.mkdir(parents=True)
            dylib.touch()
            # Framework symlinks must not trigger signing the same code again.
            (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
            (framework / "Libraries").symlink_to("Versions/Current/Libraries", target_is_directory=True)
            tests = app / "Contents/PlugIns/WriterTests.xctest"
            tests.mkdir(parents=True)
            nested = tests / "Contents/Frameworks/TestSupport.framework"
            nested.mkdir(parents=True)
            extension = app / "Contents/PlugIns/Share.appex"
            extension.mkdir(parents=True)
            entitlements, share = root / "host.entitlements", root / "share.entitlements"
            with patch("subprocess.run") as run:
                sign_products(app, [tests], entitlements, share, {})
            calls = [call.args[0] for call in run.call_args_list]
            signed = [Path(cmd[-1]) for cmd in calls if "--force" in cmd]
            self.assertLess(signed.index(dylib), signed.index(framework))
            self.assertLess(signed.index(nested), signed.index(tests))
            self.assertLess(signed.index(framework), signed.index(app))
            self.assertEqual(signed[-1], app)
            self.assertEqual(len(signed), len(set(signed)))
            self.assertIn(["codesign", "--force", "--sign", "-", "--entitlements", str(share), str(extension)], calls)
            self.assertEqual(calls[-2], ["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)])
            self.assertEqual(calls[-1], ["codesign", "--verify", "--deep", "--strict", str(app)])

    def test_standalone_test_bundle_signs_nested_framework(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, tests = root / "Writer.app", root / "WriterTests.xctest"
            app.mkdir()
            nested = tests / "Contents/Frameworks/TestSupport.framework"
            nested.mkdir(parents=True)
            with patch("subprocess.run") as run:
                sign_products(app, [tests], root / "host.entitlements", root / "share.entitlements", {})
            signed = [Path(call.args[0][-1]) for call in run.call_args_list if "--force" in call.args[0]]
            self.assertLess(signed.index(nested), signed.index(tests))
            self.assertLess(signed.index(tests), signed.index(app))


if __name__ == "__main__":
    unittest.main()
