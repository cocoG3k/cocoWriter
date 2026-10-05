#!/usr/bin/env python3
"""Keep app, extension and shared container identifiers in agreement."""
from pathlib import Path
import argparse
import json
import re

parser = argparse.ArgumentParser(description="公開用コピーのアプリ識別子とApp Groupを設定します。")
parser.add_argument("--bundle-id", required=True, help="例: com.yourname.cocoWriter")
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}", args.bundle_id):
    parser.error("ドット区切りのBundle Identifierを指定してください。")
root = Path(__file__).resolve().parent.parent / "ios"
project = root / "cocoWriter.xcodeproj/project.pbxproj"
source = project.read_text()
old = re.search(r"PRODUCT_BUNDLE_IDENTIFIER = ([A-Za-z0-9.-]+);", source).group(1)
runtime = root / "cocoWriter/WriterConfiguration.json"
configuration = json.loads(runtime.read_text())
old_group = configuration["appGroupIdentifier"]
group = "group." + args.bundle_id
project.write_text(source.replace(old, args.bundle_id))
for path in [root / "cocoWriter/cocoWriter.entitlements", root / "ShareExtension/ShareExtension.entitlements"]:
    path.write_text(path.read_text().replace(old_group, group))
configuration["appGroupIdentifier"] = group
runtime.write_text(json.dumps(configuration, ensure_ascii=False, indent=2) + "\n")
print("Bundle Identifier:", args.bundle_id)
print("App Group:", group)
print("Xcodeで本体と共有拡張に自分のTeamを設定してください。")
