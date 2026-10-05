#!/usr/bin/env python3
"""Package only Git-visible source, excluding caches, tokens and user state."""
from pathlib import Path
import re
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
version = re.search(r"MARKETING_VERSION = ([0-9.]+);", (root / "ios/cocoWriter.xcodeproj/project.pbxproj").read_text()).group(1)
subprocess.run(["python3", str(root / "tools/check-project.py")], cwd=root, check=True)
paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
paths = sorted(set(p for p in paths if p and (root / p).is_file()))
output = root / "releases"
output.mkdir(exist_ok=True)
for filename, prefix, selected in [
    (f"cocoWriter-{version}-source.zip", "cocoWriter/", paths),
    (f"cocoWriter-{version}-blog-template.zip", "my-journal/", [p for p in paths if p.startswith("site-template/")]),
]:
    with zipfile.ZipFile(output / filename, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in selected:
            relative = name.removeprefix("site-template/") if "blog-template" in filename else name
            archive.write(root / name, prefix + relative)
        assert archive.testzip() is None
        assert not any(part in {".git", ".build-cache", ".validation-cache", "node_modules", "dist", "altstore", "xcuserdata"}
                       for name in archive.namelist() for part in Path(name).parts)
    print("Created", (output / filename).relative_to(root))
