#!/usr/bin/env python3
"""Run Mac Catalyst XCTest in an isolated local variant without Apple account signing."""
from pathlib import Path
import argparse
import datetime
import json
import os
import plistlib
import runpy
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def sign_test_products(app, test_bundles, testing_entitlements, share_entitlements, env):
    """Re-sign embedded test code from the inside out, then seal the host last."""
    sign = ["codesign", "--force", "--sign", "-"]
    roots = [app] + test_bundles
    dylibs = {p for folder in roots for p in folder.rglob("*.dylib") if not p.is_symlink()}
    for dylib in sorted(dylibs):
        subprocess.run(sign + [str(dylib)], env=env, check=True, capture_output=True)
    # Xcode embeds testing frameworks (including XCUIAutomation). Signing their
    # dylibs changes their resource seals, so each enclosing bundle needs signing.
    bundles = set(test_bundles)
    for folder in roots:
        bundles.update(p for p in folder.rglob("*")
                       if p.suffix in {".framework", ".xctest", ".appex"} and p.is_dir() and not p.is_symlink())
    for bundle in sorted(bundles, key=lambda p: (-len(p.parts), str(p))):
        entitlements = ["--entitlements", str(share_entitlements)] if bundle.suffix == ".appex" else []
        subprocess.run(sign + entitlements + [str(bundle)], env=env, check=True, capture_output=True)
    subprocess.run(sign + ["--entitlements", str(testing_entitlements), str(app)], env=env, check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, help="Optional local validation profile")
    parser.add_argument("--build-dir", type=Path, default=ROOT / ".build-cache/mac-tests")
    args = parser.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    profile = args.profile
    if profile is None:
        local = ROOT / ".local/mac-tests"
        local.mkdir(parents=True, exist_ok=True)
        value = json.loads((ROOT / "config/app/default.json").read_text())
        value.update(bundleIdentifier="org.example.cocoWriter.MacTests", extensionBundleIdentifier="org.example.cocoWriter.MacTests.Share",
                     appGroupIdentifier="group.org.example.cocoWriter.MacTests", storageDirectory="cocoWriter-MacTests",
                     keychainService="cocoWriter-MacTests.GitHub", displayName="cocoWriter Mac Tests",
                     blogProfile=str(ROOT / "config/default.json"))
        profile = local / "profile.json"
        profile.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    variant = runpy.run_path(str(ROOT / "tools/configure-variant.py"))
    project = variant["generate"](profile, build / "configured/ios")
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

    def run(command, log_name):
        log = build / log_name
        with log.open("w") as output:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            print("\n".join(log.read_text(errors="replace").splitlines()[-80:]))
            raise SystemExit(f"Failed; see {log}")
        return log

    common = ["xcodebuild", "-project", str(project), "-scheme", "cocoWriter", "-configuration", "Debug",
              "-destination", "platform=macOS,variant=Mac Catalyst", "-derivedDataPath", str(build),
              "-jobs", "2", "CODE_SIGNING_ALLOWED=NO"]
    print("Building isolated Mac Catalyst tests…", flush=True)
    run(common + ["build-for-testing"], "XCTest-build.log")
    products = build / "Build/Products"
    app = products / "Debug-maccatalyst/cocoWriter.app"
    test_bundles = list((products / "Debug-maccatalyst").glob("*.xctest")) + list(app.rglob("*.xctest"))
    assert app.is_dir() and test_bundles, "Missing test products"
    # XCTest must attach to this local test host. No application identifier,
    # signing team, certificate, or provisioning-profile entitlement is claimed.
    entitlements = plistlib.loads((project.parent / "cocoWriter/cocoWriter.entitlements").read_bytes())
    entitlements["com.apple.security.get-task-allow"] = True
    testing_entitlements = build / "test-host.entitlements"
    testing_entitlements.write_bytes(plistlib.dumps(entitlements))
    sign_test_products(app, test_bundles, testing_entitlements,
                       project.parent / "ShareExtension/ShareExtension.entitlements", env)
    run_file = max(products.glob("*.xctestrun"), key=lambda p: p.stat().st_mtime)
    result = build / ("tests-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".xcresult")
    print("Running Mac Catalyst XCTest…", flush=True)
    log = run(["xcodebuild", "test-without-building", "-xctestrun", str(run_file),
               "-destination", "platform=macOS,variant=Mac Catalyst", "-resultBundlePath", str(result),
               "-jobs", "2", "CODE_SIGNING_ALLOWED=NO"], "XCTest-run.log")
    for line in log.read_text(errors="replace").splitlines():
        if "Executed " in line or "** TEST " in line:
            print(line)
    print("Test result:", result)


if __name__ == "__main__":
    main()
