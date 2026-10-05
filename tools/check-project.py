#!/usr/bin/env python3
"""Check the distributable inventory; does not contact GitHub or read tokens."""
from pathlib import Path
import hashlib
import json
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
import runpy
validate_profile = runpy.run_path(str(root / "tools/configure-blog.py"))["validate"]
for profile in list((root / "config").glob("*.json")) + [root / "ios/cocoWriter/BlogProfile.json", root / "site-template/blog-profile.json"]:
    validate_profile(json.loads(profile.read_text()))
project = (root / "ios/cocoWriter.xcodeproj/project.pbxproj").read_text()
for p in (root / "ios/cocoWriter").glob("*.swift"):
    assert p.name in project, "Missing Xcode reference: " + p.name
for p in (root / "ios/Tests").glob("*.swift"):
    assert p.name in project, "Missing test reference: " + p.name
for p in (root / "ios").rglob("*.xcscheme"):
    ET.parse(p)
for p in (root / "ios").rglob("*.entitlements"):
    ET.parse(p)
assert not re.search(r'DEVELOPMENT_TEAM = (?!"")[A-Z0-9]', project), "Personal signing team is present"
assert (root / "ios/cocoWriter/Assets.xcassets/AppIcon.appiconset/AppIcon.png").is_file()
inventory = json.loads((root / "ios/cocoWriter/SBOM.cdx.json").read_text())
pins = json.loads((root / "ios/cocoWriter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
revisions = {p["identity"]: p["state"]["revision"] for p in pins["pins"]}
for component in inventory["components"]:
    properties = {p["name"]: p["value"] for p in component["properties"]}
    assert revisions[component["name"]] == properties["cocowriter:git-revision"]
    assert (root / "ios/cocoWriter" / properties["cocowriter:license-resource"]).is_file()
excluded = {".git", ".build-cache", ".validation-cache", "node_modules", "dist", "altstore", "releases", "__pycache__"}
for p in root.rglob("*"):
    if not p.is_file() or excluded.intersection(p.relative_to(root).parts) or p.name == ".source-integrity.json":
        continue
    if p.suffix in {".png", ".zip"}:
        continue
    text = p.read_text()
    assert not re.search(r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", text), "Potential secret in " + str(p.relative_to(root))
    if "ios" in p.relative_to(root).parts:
        assert "cocog.dev" not in text.lower(), "Original domain remains in " + p.name
        assert "cocoG3k" not in text, "Original repository remains in " + p.name
        assert "/Users/" not in text, "Personal filesystem path remains in " + p.name
assert (root / "site-template/package-lock.json").is_file()
for required in ["LICENSE", "README.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md", "site-template/LICENSE", "site-template/THIRD_PARTY_NOTICES.md"]:
    assert (root / required).is_file(), required
print("PASS: project inventory, empty signing teams, dependency notices, and public-source checks")

# This local-only manifest is excluded from Git and distribution archives.
manifest = root / ".source-integrity.json"
original = root.parent / "CocoGWriter-iPhone-Prototype"
if manifest.is_file() and original.is_dir():
    for name, expected in json.loads(manifest.read_text()).items():
        assert hashlib.sha256((original / name).read_bytes()).hexdigest() == expected, "Original file changed: " + name
    print("PASS: original project source files are unchanged")
