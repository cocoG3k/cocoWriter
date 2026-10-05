#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build-cache altstore
print 'AltStore用のiPhoneアプリをビルドしています…'
if ! /usr/bin/xcrun xcodebuild \
    -project ios/cocoWriter.xcodeproj \
    -scheme cocoWriter -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath .build-cache/altstore \
    CODE_SIGNING_ALLOWED=NO build > .build-cache/altstore-build.log 2>&1; then
    tail -60 .build-cache/altstore-build.log
    print 'ビルドに失敗しました。ログ: .build-cache/altstore-build.log'
    exit 1
fi

app_path="$PWD/.build-cache/altstore/Build/Products/Release-iphoneos/cocoWriter.app"
stage_path=$(mktemp -d "$PWD/.build-cache/altstore-package.XXXXXX")
trap 'rm -rf -- "$stage_path"' EXIT
mkdir -p "$stage_path/Payload"
/usr/bin/ditto "$app_path" "$stage_path/Payload/cocoWriter.app"
# Preserve App Group entitlements for AltStore to inspect before re-signing.
# Ad-hoc signing uses no account/certificate and cannot install on an iPhone.
/usr/bin/codesign --force --sign - --entitlements "$PWD/ios/ShareExtension/ShareExtension.entitlements" "$stage_path/Payload/cocoWriter.app/PlugIns/cocoWriterShare.appex"
/usr/bin/codesign --force --sign - --entitlements "$PWD/ios/cocoWriter/cocoWriter.entitlements" "$stage_path/Payload/cocoWriter.app"
/usr/bin/codesign --verify --deep --strict "$stage_path/Payload/cocoWriter.app"
/usr/bin/ditto -c -k --keepParent "$stage_path/Payload" "$stage_path/cocoWriter.ipa"
/bin/mv -f "$stage_path/cocoWriter.ipa" "$PWD/altstore/cocoWriter.ipa"
/usr/bin/zip -j -q "$stage_path/cocoWriter-AirDrop.zip" "$PWD/altstore/cocoWriter.ipa"
/bin/mv -f "$stage_path/cocoWriter-AirDrop.zip" "$PWD/altstore/cocoWriter-AirDrop.zip"
print "IPAを作成しました: $PWD/altstore/cocoWriter.ipa"
print "AirDrop用ZIP: $PWD/altstore/cocoWriter-AirDrop.zip"
print 'ZIPをiPhoneに送り、ファイルアプリで展開するとIPAを取り出せます。'
print 'iPhoneのAltStore → My Apps → ＋ から、このIPAを選択してください。'
print 'iPhone用の署名はAltStoreが行います。IPAには共有設定を保持するためのad-hoc署名だけを付けています。'
