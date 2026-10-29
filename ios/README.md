# cocoWriter iOS

Open `cocoWriter.xcodeproj` and use the `cocoWriter` scheme. See the [project guide](../README.md) for signing, App Group setup and publishing configuration.

Swift Markdown 0.8.0 requires a compiler supporting Swift 6.2 or newer. The app uses Swift 5 language mode and targets iOS 17 or newer. All signing teams are blank in the public project; `org.example.cocoWriter` is a placeholder identifier.

The `cocoWriterShare` extension and main app must use the same App Group. `tools/configure-signing.py` updates their identifiers together. App Group identifiers rewritten by AltStore are resolved using `ALTAppGroups`.

`python3 ../tools/test-ios.py` runs the XCTest suite on a dedicated simulator. No credentials or live publication are used by the tests.

## Mac Catalyst

The shared app also runs on macOS 14 or newer, with Mac controls, a sidebar,
article search, a split article editor, a responsive preview/inspector and keyboard
shortcuts. Select **My Mac (Mac Catalyst)** with the same `cocoWriter` scheme, or
run `../build-mac.command --open` from this directory. Pass `--profile` to preserve
an existing variant's identity and storage settings. Generated projects still
reference these shared sources.

The script creates an ad-hoc signed local `.app`; distributing to other Macs
requires Developer ID signing and notarization or a Mac App Store configuration.
Data and credentials remain local to each device; iPhone and Mac do not sync
unpublished drafts or private notes automatically.

Local ad-hoc Mac builds cannot persist GitHub tokens in the Data Protection
Keychain. Settings offers **Use token for this session only** (Japanese UI:
「この起動中だけトークンを使う」). The token stays in memory and must be re-entered
after quitting. Keychain persistence requires a suitably signed and provisioned
Mac Catalyst app. Tokens are never saved to a plain-text file.
