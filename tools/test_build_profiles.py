#!/usr/bin/env python3
"""Test profile selection in an isolated copy, without altering the app source."""
from pathlib import Path
import json
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
validate = runpy.run_path(str(ROOT / "tools/configure-blog.py"))["validate"]
validate_preview = runpy.run_path(str(ROOT / "tools/configure-blog.py"))["validate_preview"]

class BuildProfilesTests(unittest.TestCase):
    def test_all_presets_validate(self):
        for file in (ROOT / "config").glob("*.json"):
            validate(json.loads(file.read_text()))

    def test_invalid_settings_are_rejected(self):
        for field, value in [("articleDirectory", "../posts"), ("imageDirectory", "/images"),
                             ("imagePublicPath", "https://example.org/images"), ("filenameTemplate", "{title}.md"),
                             ("imageReferenceStyle", "unknown"), ("articleExtensions", ["html"])]:
            profile = json.loads((ROOT / "config/default.json").read_text())
            profile[field] = value
            with self.assertRaises(ValueError):
                validate(profile)

    def test_fixed_fields_and_editable_fields_must_not_overlap(self):
        profile = json.loads((ROOT / "config/default.json").read_text())
        profile["frontMatter"]["extra"] = {"title": "override"}
        with self.assertRaises(ValueError):
            validate(profile)

    def test_preview_template_validation(self):
        valid = (ROOT / "preview-templates/minimal.html").read_text()
        self.assertEqual(validate_preview(valid), valid)
        for invalid in [valid.replace("{{content}}", ""), valid.replace("{{title}}", "{{unsupported}}"), valid.replace("<head>", "<head><base href='https://example.org/'>"), valid.replace("<head>", "<head><meta http-equiv='refresh' content='0;url=https://example.org'>")]:
            with self.assertRaises(ValueError):
                validate_preview(invalid)

    def test_preview_selection_is_bundled_and_default_clears_it(self):
        with tempfile.TemporaryDirectory(prefix="cocowriter-preview-") as temporary:
            root = Path(temporary)
            (root / "tools").mkdir()
            app = root / "ios/cocoWriter/BlogProfile.json"
            app.parent.mkdir(parents=True)
            shutil.copy(ROOT / "tools/configure-blog.py", root / "tools/configure-blog.py")
            profile = json.loads((ROOT / "config/default.json").read_text())
            profile["preview"] = {"templateFile": "theme.html"}
            (root / "profile.json").write_text(json.dumps(profile))
            theme = (ROOT / "preview-templates/minimal.html").read_text()
            (root / "theme.html").write_text(theme)
            command = [sys.executable, str(root / "tools/configure-blog.py"), str(root / "profile.json")]
            subprocess.run(command + ["--check"], check=True, capture_output=True)
            self.assertFalse(app.exists())
            subprocess.run(command, check=True, capture_output=True)
            self.assertNotIn("preview", json.loads(app.read_text()))
            bundled = app.parent / "BlogPreviewTemplate.html"
            self.assertEqual(bundled.read_text(), theme)
            del profile["preview"]
            (root / "profile.json").write_text(json.dumps(profile))
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(bundled.read_text(), "")

    def test_check_and_apply_use_isolated_app_and_blog(self):
        with tempfile.TemporaryDirectory(prefix="cocowriter-profile-") as temporary:
            root = Path(temporary)
            (root / "tools").mkdir()
            app = root / "ios/cocoWriter/BlogProfile.json"
            app.parent.mkdir(parents=True)
            shutil.copy(ROOT / "tools/configure-blog.py", root / "tools/configure-blog.py")
            shutil.copy(ROOT / "config/default.json", app)
            profile = root / "custom.json"
            shutil.copy(ROOT / "config/hugo-toml.json", profile)
            blog = root / "blog"
            (blog / "tools").mkdir(parents=True)
            (blog / "tools/profile.mjs").write_text("// isolated fixture")
            (blog / "site.config.json").write_text("{}")
            command = [sys.executable, str(root / "tools/configure-blog.py"), str(profile), "--blog", str(blog)]
            before = app.read_bytes()
            subprocess.run(command + ["--check"], check=True, capture_output=True)
            self.assertEqual(app.read_bytes(), before)
            self.assertFalse((blog / "blog-profile.json").exists())
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(json.loads(app.read_text()), json.loads(profile.read_text()))
            self.assertEqual(app.read_bytes(), (blog / "blog-profile.json").read_bytes())
            self.assertTrue((blog / "content/posts").is_dir())

if __name__ == "__main__":
    unittest.main()
