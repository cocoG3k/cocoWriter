#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
variant_ios="${COCOWRITER_IOS_DIR:-$PWD/ios}"
variant_build="${COCOWRITER_BUILD_DIR:-$PWD/.build-cache/altstore}"
variant_output="${COCOWRITER_OUTPUT_DIR:-$PWD/altstore}"
variant_name="${COCOWRITER_DISTRIBUTION_NAME:-cocoWriter}"
if [[ ! "$variant_name" =~ '^[A-Za-z][A-Za-z0-9._-]*$' ]]; then
    print '配布ファイル名を確認してください。'
    exit 1
fi
[[ -d "$variant_ios/cocoWriter.xcodeproj" ]]
mkdir -p "$variant_build" "$variant_output"
print 'AltStore用のiPhoneアプリをビルドしています…'
if ! /usr/bin/xcrun xcodebuild \
    -project "$variant_ios/cocoWriter.xcodeproj" \
    -scheme cocoWriter -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$variant_build" \
    CODE_SIGNING_ALLOWED=NO build > "$variant_build/build.log" 2>&1; then
    tail -60 "$variant_build/build.log"
    print "ビルドに失敗しました。ログ: $variant_build/build.log"
    exit 1
fi

app_path="$variant_build/Build/Products/Release-iphoneos/cocoWriter.app"
stage_path=$(mktemp -d "$variant_build/package.XXXXXX")
trap 'rm -rf -- "$stage_path"' EXIT
mkdir -p "$stage_path/Payload"
/usr/bin/ditto "$app_path" "$stage_path/Payload/cocoWriter.app"
# Preserve App Group entitlements for AltStore to inspect before re-signing.
# Ad-hoc signing uses no account/certificate and cannot install on an iPhone.
/usr/bin/codesign --force --sign - --entitlements "$variant_ios/ShareExtension/ShareExtension.entitlements" "$stage_path/Payload/cocoWriter.app/PlugIns/cocoWriterShare.appex"
/usr/bin/codesign --force --sign - --entitlements "$variant_ios/cocoWriter/cocoWriter.entitlements" "$stage_path/Payload/cocoWriter.app"
/usr/bin/codesign --verify --deep --strict "$stage_path/Payload/cocoWriter.app"
/usr/bin/ditto -c -k --keepParent "$stage_path/Payload" "$stage_path/cocoWriter.ipa"
/bin/mv -f "$stage_path/cocoWriter.ipa" "$variant_output/$variant_name.ipa"
/usr/bin/zip -j -q "$stage_path/cocoWriter-AirDrop.zip" "$variant_output/$variant_name.ipa"
/bin/mv -f "$stage_path/cocoWriter-AirDrop.zip" "$variant_output/$variant_name-AirDrop.zip"
print "IPAを作成しました: $variant_output/$variant_name.ipa"
print "AirDrop用ZIP: $variant_output/$variant_name-AirDrop.zip"
print 'ZIPをiPhoneに送り、ファイルアプリで展開するとIPAを取り出せます。'
print 'iPhoneのAltStore → My Apps → ＋ から、このIPAを選択してください。'
print 'iPhone用の署名はAltStoreが行います。IPAには共有設定を保持するためのad-hoc署名だけを付けています。'
