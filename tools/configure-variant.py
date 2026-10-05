#!/usr/bin/env python3
"""Generate a configured Xcode project that references the shared cocoWriter sources."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import re
import runpy
import shutil
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
BLOG = runpy.run_path(str(ROOT / "tools/configure-blog.py"))
RUNTIME_KEYS = ("schemaVersion", "storageDirectory", "keychainService", "appGroupIdentifier", "defaultSite", "legacyDestinationID")

def validate(profile):
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    def identifier(value):
        return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}", value)
    require(profile.get("schemaVersion") == 1, "schemaVersion must be 1")
    require(identifier(profile.get("bundleIdentifier")), "Invalid app Bundle Identifier")
    require(identifier(profile.get("extensionBundleIdentifier")) and profile["extensionBundleIdentifier"].startswith(profile["bundleIdentifier"] + "."), "Extension must use the app identifier prefix")
    require(identifier(profile.get("appGroupIdentifier")) and profile["appGroupIdentifier"].startswith("group."), "Invalid App Group")
    for key, limit in [("storageDirectory", 100), ("keychainService", 200)]:
        value = profile.get(key)
        require(isinstance(value, str) and len(value) <= limit and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) and value not in {".", ".."}, "Invalid " + key)
    name = profile.get("displayName")
    require(isinstance(name, str) and 0 < len(name) <= 100 and all(ord(c) >= 32 for c in name), "Invalid displayName")
    site = profile.get("defaultSite", {})
    require(set(site) == {"owner", "repository", "branch", "website", "title", "tagline"} and all(isinstance(v, str) for v in site.values()), "Provide all defaultSite fields")
    require(site["title"].strip(), "Site title must not be empty")
    if site["owner"] or site["repository"] or site["website"]:
        require(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", site["owner"]), "Invalid GitHub owner")
        require(re.fullmatch(r"[A-Za-z0-9._-]{1,100}", site["repository"]) and site["repository"] not in {".", ".."}, "Invalid repository")
        url = urlsplit(site["website"])
        require(url.scheme == "https" and url.hostname and not url.username and not url.password and not url.port and not url.query and not url.fragment and not any(x in {".", ".."} for x in url.path.split("/")), "Use a full HTTPS site URL")
    branch = site["branch"]
    require(re.fullmatch(r"[A-Za-z0-9._/-]+", branch) and ".." not in branch and all(part and not part.startswith(".") and not part.endswith((".", ".lock")) for part in branch.split("/")), "Invalid branch")
    if profile.get("legacyDestinationID") is not None:
        expected = (site["owner"] + "/" + site["repository"]).lower() + "@" + branch
        require(site["owner"] and site["repository"] and profile["legacyDestinationID"] == expected, "Legacy destination must match the configured original repository and branch")
    require(not profile.get("developmentTeam") or re.fullmatch(r"[A-Z0-9]{10}", profile["developmentTeam"]), "Invalid developmentTeam")
    require(not profile.get("version") or re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", profile["version"]), "Invalid version")
    require("build" not in profile or isinstance(profile["build"], int) and not isinstance(profile["build"], bool) and profile["build"] > 0, "build must be a positive integer")
    require(isinstance(profile.get("blogProfile"), str) and profile["blogProfile"], "Provide a blogProfile file")
    return profile

def generate(profile_path, output):
    profile_path = Path(profile_path).resolve()
    output = Path(output).resolve()
    profile = validate(json.loads(profile_path.read_text()))
    # Resolve and validate every input before touching a generated project.
    blog_path = (profile_path.parent / profile["blogProfile"]).resolve()
    blog = BLOG["validate"](json.loads(blog_path.read_text()))
    template = ""
    if "preview" in blog:
        template_path = (blog_path.parent / blog["preview"]["templateFile"]).resolve()
        template = BLOG["validate_preview"](template_path.read_text())
    blog = {k: v for k, v in blog.items() if k != "preview"}
    if output == ROOT / "ios" or output == ROOT or output in (ROOT / "ios").parents:
        raise ValueError("Use a separate generated directory, such as .local/my-blog/ios")
    marker = output / ".writer-variant.json"
    if output.exists() and any(output.iterdir()) and not marker.is_file():
        raise ValueError("Refusing to overwrite a directory that is not a generated cocoWriter variant")
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / "ios"
    project = (source / "cocoWriter.xcodeproj/project.pbxproj").read_text()
    # Source groups point to the canonical source tree; only configuration is duplicated.
    for group in ("cocoWriter", "Tests", "ShareExtension"):
        relative = Path(os.path.relpath(source / group, output)).as_posix()
        project = project.replace("path = " + group + ";", "path = " + json.dumps(relative) + ";")
    for name in ("WriterConfiguration.json", "BlogProfile.json", "BlogPreviewTemplate.html"):
        project = re.sub(r"(path = )" + re.escape(name) + r'; sourceTree = "<group>";', r'\1"cocoWriter/' + name + '"; sourceTree = SOURCE_ROOT;', project)
    project = re.sub(r"(path = )README.md; sourceTree = \"<group>\";", r'\1' + json.dumps(Path(os.path.relpath(source / "README.md", output)).as_posix()) + '; sourceTree = SOURCE_ROOT;', project)
    canonical = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = ([A-Za-z0-9.-]+);", project).group(1)
    project = project.replace(canonical + ".Share;", profile["extensionBundleIdentifier"] + ";")
    project = project.replace(canonical + ".Tests;", profile["bundleIdentifier"] + ".Tests;")
    project = project.replace(canonical + ";", profile["bundleIdentifier"] + ";")
    project = re.sub(r"INFOPLIST_KEY_CFBundleDisplayName = [^;]+;", "INFOPLIST_KEY_CFBundleDisplayName = " + json.dumps(profile["displayName"], ensure_ascii=False) + ";", project)
    project = re.sub(r"DEVELOPMENT_TEAM = [^;]+;", "DEVELOPMENT_TEAM = " + json.dumps(profile.get("developmentTeam", "")) + ";", project)
    if "version" in profile:
        project = re.sub(r"MARKETING_VERSION = [^;]+;", "MARKETING_VERSION = " + profile["version"] + ";", project)
    if "build" in profile:
        project = re.sub(r"CURRENT_PROJECT_VERSION = [^;]+;", "CURRENT_PROJECT_VERSION = " + str(profile["build"]) + ";", project)
    project_dir = output / "cocoWriter.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    for relative in ("xcshareddata/xcschemes", "project.xcworkspace/xcshareddata/swiftpm"):
        shutil.copytree(source / "cocoWriter.xcodeproj" / relative, project_dir / relative, dirs_exist_ok=True)
    (project_dir / "project.pbxproj").write_text(project)
    app = output / "cocoWriter"
    share = output / "ShareExtension"
    app.mkdir(exist_ok=True)
    share.mkdir(exist_ok=True)
    for folder, filename in ((app, "cocoWriter.entitlements"), (share, "ShareExtension.entitlements")):
        with (folder / filename).open("wb") as f:
            plistlib.dump({"com.apple.security.application-groups": [profile["appGroupIdentifier"]]}, f)
    info = plistlib.loads((source / "ShareExtension/Info.plist").read_bytes())
    info["CFBundleDisplayName"] = profile["displayName"]
    (share / "Info.plist").write_bytes(plistlib.dumps(info))
    (app / "WriterConfiguration.json").write_text(json.dumps({k: profile[k] for k in RUNTIME_KEYS if k in profile}, ensure_ascii=False, indent=2) + "\n")
    (app / "BlogProfile.json").write_text(json.dumps(blog, ensure_ascii=False, indent=2) + "\n")
    (app / "BlogPreviewTemplate.html").write_text(template)
    marker.write_text(json.dumps({"profile": str(profile_path), "source": str(source)}, indent=2) + "\n")
    return project_dir

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        print("Configured Xcode project:", generate(args.profile, args.output))
    except (ValueError, KeyError, OSError) as error:
        parser.error(str(error))

if __name__ == "__main__":
    main()
