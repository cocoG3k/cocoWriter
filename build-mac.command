#!/bin/zsh
# Build a local Mac Catalyst app without using an Apple account or certificate.
set -euo pipefail
cd -- "${0:A:h}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
writer_profile="${COCOWRITER_PROFILE:-}"
writer_output="${COCOWRITER_MAC_OUTPUT:-$PWD/.local/mac/cocoWriter.app}"
writer_build="${COCOWRITER_MAC_BUILD:-$PWD/.build-cache/mac}"
writer_configuration="${COCOWRITER_MAC_CONFIGURATION:-Release}"
writer_jobs="${COCOWRITER_MAC_JOBS:-2}"
writer_arch_options=()
writer_open=0
while (( $# )); do
    case "$1" in
        --profile) (( $# >= 2 )) || { print '--profile の後に設定ファイルを指定してください。'; exit 2; }; writer_profile="$2"; shift 2 ;;
        --output) (( $# >= 2 )) || { print '--output の後に .app パスを指定してください。'; exit 2; }; writer_output="$2"; shift 2 ;;
        --open) writer_open=1; shift ;;
        *) print '使い方: ./build-mac.command [--profile profile.json] [--output path.app] [--open]'; exit 2 ;;
    esac
done
writer_output="${writer_output:A}"
writer_build="${writer_build:A}"
if [[ "$writer_configuration" != Debug && "$writer_configuration" != Release ]]; then
    print 'COCOWRITER_MAC_CONFIGURATION は Debug または Release を指定してください。'
    exit 2
fi
if [[ ! "$writer_jobs" =~ '^[1-9][0-9]*$' ]]; then
    print 'COCOWRITER_MAC_JOBS は同時に処理する数を指定してください。'
    exit 2
fi
if [[ -n "${COCOWRITER_MAC_ACTIVE_ARCH_ONLY:-}" ]]; then
    if [[ "$COCOWRITER_MAC_ACTIVE_ARCH_ONLY" != YES && "$COCOWRITER_MAC_ACTIVE_ARCH_ONLY" != NO ]]; then
        print 'COCOWRITER_MAC_ACTIVE_ARCH_ONLY は YES または NO を指定してください。'
        exit 2
    fi
    writer_arch_options+=("ONLY_ACTIVE_ARCH=$COCOWRITER_MAC_ACTIVE_ARCH_ONLY")
fi
writer_log="$writer_build/$writer_configuration-build.log"
if [[ "$writer_output" != *.app || "$writer_output" == /Applications/* || "$writer_output" == "$HOME/Applications/"* ]]; then
    print '出力には作業フォルダ内の .app パスを指定してください。'
    exit 2
fi
writer_ios="$PWD/ios"
if [[ -n "$writer_profile" ]]; then
    writer_profile="${writer_profile:A}"
    writer_ios="$writer_build/configured/ios"
    python3 tools/configure-variant.py "$writer_profile" --output "$writer_ios"
fi
mkdir -p -- "$writer_build" "${writer_output:h}"
print 'Mac版をビルドしています…'
if ! /usr/bin/xcrun xcodebuild \
    -project "$writer_ios/cocoWriter.xcodeproj" -scheme cocoWriter \
    -configuration "$writer_configuration" -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$writer_build" -jobs "$writer_jobs" \
    "${writer_arch_options[@]}" CODE_SIGNING_ALLOWED=NO build \
    > "$writer_log" 2>&1; then
    tail -60 "$writer_log"
    print "ビルドに失敗しました。ログ: $writer_log"
    exit 1
fi
writer_app="$writer_build/Build/Products/$writer_configuration-maccatalyst/cocoWriter.app"
[[ -d "$writer_app" ]]
writer_stage=$(mktemp -d "${writer_output:h}/.cocoWriter-mac.XXXXXX")
trap 'rm -rf -- "$writer_stage"' EXIT
/usr/bin/ditto "$writer_app" "$writer_stage/cocoWriter.app"
# A previous build-for-testing can leave its hosted test bundle in DerivedData.
# Local app exports contain only the app and its sharing extension.
for writer_test_bundle in "$writer_stage/cocoWriter.app"/**/*.xctest(N/); do
    /bin/rm -rf -- "$writer_test_bundle"
done
# Ad-hoc signing is for running this build on this Mac. Distribution requires
# the developer's own Developer ID and notarization, or Mac App Store signing.
for writer_dylib in "$writer_stage/cocoWriter.app"/**/*.dylib(N); do
    /usr/bin/codesign --force --sign - "$writer_dylib"
done
/usr/bin/codesign --force --sign - --entitlements "$writer_ios/ShareExtension/ShareExtension.entitlements" \
    "$writer_stage/cocoWriter.app/Contents/PlugIns/cocoWriterShare.appex"
/usr/bin/codesign --force --sign - --entitlements "$writer_ios/cocoWriter/cocoWriter.entitlements" \
    "$writer_stage/cocoWriter.app"
/usr/bin/codesign --verify --deep --strict "$writer_stage/cocoWriter.app"
# Replace the build artifact only. Documents, preferences and Keychain remain in
# their existing locations; no installed iPhone app is touched.
if [[ -e "$writer_output" ]]; then
    /bin/mv -- "$writer_output" "$writer_stage/previous.app"
fi
if ! /bin/mv -- "$writer_stage/cocoWriter.app" "$writer_output"; then
    if [[ -e "$writer_stage/previous.app" ]]; then /bin/mv -- "$writer_stage/previous.app" "$writer_output"; fi
    exit 1
fi
print "Mac版を作成しました: $writer_output"
if (( writer_open )); then /usr/bin/open "$writer_output"; fi
