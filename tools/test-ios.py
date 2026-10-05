#!/usr/bin/env python3
"""Run XCTest on a dedicated simulator, without touching the original app."""
from pathlib import Path
import json
import os
import subprocess

root = Path(__file__).resolve().parent.parent
env = dict(os.environ)
env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
def run(*args):
    return subprocess.check_output(args, env=env, text=True).strip()
devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
matches = [(runtime, d) for runtime, items in devices.items() if "iOS" in runtime
           for d in items if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not matches:
    raise SystemExit("XcodeでiOS Simulatorを導入してから実行してください。")
def runtime_version(value):
    return tuple(int(part) for part in value.split("iOS-")[-1].split("-"))
runtime, template = sorted(matches, key=lambda x: runtime_version(x[0]))[-1]
device = next((d for d in devices[runtime] if d["name"] == "cocoWriter Validation"), None)
udid = device["udid"] if device else run("xcrun", "simctl", "create", "cocoWriter Validation", template["deviceTypeIdentifier"], runtime)
subprocess.run(["xcodebuild", "-project", str(root / "ios/cocoWriter.xcodeproj"), "-scheme", "cocoWriter",
                "-destination", "platform=iOS Simulator,id=" + udid,
                "-derivedDataPath", str(root / ".build-cache/main"), "CODE_SIGNING_ALLOWED=NO", "test"],
               env=env, check=True)
