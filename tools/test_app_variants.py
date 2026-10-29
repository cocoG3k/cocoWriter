#!/usr/bin/env python3
"""Verify identity preservation and shared-source project generation."""
from pathlib import Path
import json
import os
import plistlib
import re
import runpy
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
variant = runpy.run_path(str(ROOT / "tools/configure-variant.py"))

class AppVariantTests(unittest.TestCase):
    def profile(self):
        return json.loads((ROOT / "config/app/default.json").read_text())

    def test_unsafe_or_inconsistent_identity_is_rejected(self):
        for key, value in [("storageDirectory", "../old"), ("keychainService", "bad\nservice"),
                           ("extensionBundleIdentifier", "org.different.Share"), ("appGroupIdentifier", "bad.group"),
                           ("legacyDestinationID", "another/repository@main"), ("build", True)]:
            profile = self.profile(); profile[key] = value
            with self.assertRaises(ValueError): variant["validate"](profile)

    def test_generated_project_references_shared_sources_and_preserves_identity(self):
        original = (ROOT / "ios/cocoWriter.xcodeproj/project.pbxproj").read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = self.profile()
            profile.update(bundleIdentifier="org.example.ExistingWriter", extensionBundleIdentifier="org.example.ExistingWriter.Shared", appGroupIdentifier="group.org.example.ExistingWriter", storageDirectory="ExistingWriter", keychainService="ExistingWriter.GitHub", version="1.2.3", build=12, displayName="Existing Writer", blogProfile=str(ROOT / "config/default.json"))
            profile["defaultSite"] = dict(owner="example", repository="journal", branch="publish/blog", website="https://example.github.io/journal/", title="Existing blog", tagline="")
            profile["legacyDestinationID"] = "example/journal@publish/blog"
            file = root / "profile.json"; file.write_text(json.dumps(profile))
            output = root / "generated"
            project = variant["generate"](file, output)
            text = (project / "project.pbxproj").read_text()
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = org.example.ExistingWriter;", text)
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = org.example.ExistingWriter.Shared;", text)
            self.assertIn('path = "cocoWriter/WriterConfiguration.json"; sourceTree = SOURCE_ROOT;', text)
            for group in ["cocoWriter", "Tests", "ShareExtension"]:
                relative = os.path.relpath(ROOT / "ios" / group, output.resolve())
                self.assertTrue('path = ' + json.dumps(relative) + ';' in text, "Missing shared source group: " + group)
            self.assertFalse((output / "cocoWriter/Store.swift").exists(), "A variant must use shared sources, not a forked copy")
            config = json.loads((output / "cocoWriter/WriterConfiguration.json").read_text())
            for key in variant["RUNTIME_KEYS"]:
                self.assertEqual(config[key], profile[key])
            for folder, name in [("cocoWriter", "cocoWriter.entitlements"), ("ShareExtension", "ShareExtension.entitlements")]:
                value = plistlib.loads((output / folder / name).read_bytes())
                self.assertEqual(value["com.apple.security.application-groups"], [profile["appGroupIdentifier"]])
            self.assertEqual(plistlib.loads((output / "ShareExtension/Info.plist").read_bytes())["CFBundleDisplayName"], "Existing Writer")
            self.assertEqual(text.count("MARKETING_VERSION = 1.2.3;"), 4)
            self.assertEqual(text.count("CURRENT_PROJECT_VERSION = 12;"), 4)
            self.assertEqual(variant["generate"](file, output), project)
            self.assertEqual((ROOT / "ios/cocoWriter.xcodeproj/project.pbxproj").read_bytes(), original)

    def test_non_generated_project_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); existing = root / "old-project"; existing.mkdir()
            sentinel = existing / "keep.txt"; sentinel.write_text("keep")
            profile = self.profile(); profile["blogProfile"] = str(ROOT / "config/default.json")
            file = root / "profile.json"; file.write_text(json.dumps(profile))
            with self.assertRaises(ValueError): variant["generate"](file, existing)
            self.assertEqual(sentinel.read_text(), "keep")

    def test_mac_app_and_share_extension_preserve_identity_in_both_configurations(self):
        text = (ROOT / "ios/cocoWriter.xcodeproj/project.pbxproj").read_text()
        configurations = ["AA0000000000000000000003", "AA0000000000000000000004",
                          "BA0000000000000000000001", "BA0000000000000000000002"]
        for identifier in configurations:
            settings = re.search(r"^\s*" + identifier + r"(?: /\*.*?\*/)? = \{.*?buildSettings = \{(.*?)\};",
                                 text, re.MULTILINE | re.DOTALL).group(1)
            self.assertIn("SUPPORTS_MACCATALYST = YES;", settings)
            self.assertIn("DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO;", settings)
            self.assertIn('"TARGETED_DEVICE_FAMILY[sdk=macosx*]" = "2,6";', settings)
            self.assertIn("MACCATALYST_DEPLOYMENT_TARGET = 17.0;", settings)

    def test_mac_icon_sizes_match_asset_catalog(self):
        folder = ROOT / "ios/cocoWriter/Assets.xcassets/AppIcon.appiconset"
        icons = [icon for icon in json.loads((folder / "Contents.json").read_text())["images"] if icon["idiom"] == "mac"]
        self.assertEqual({(icon["size"], icon["scale"]) for icon in icons},
                         {(f"{size}x{size}", f"{scale}x") for size in [16, 32, 128, 256, 512] for scale in [1, 2]})
        for icon in icons:
            data = (folder / icon["filename"]).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            pixels = int(icon["size"].split("x")[0]) * int(icon["scale"].rstrip("x"))
            self.assertEqual(struct.unpack(">II", data[16:24]), (pixels, pixels))

if __name__ == "__main__":
    unittest.main()
