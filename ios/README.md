# cocoWriter iOS

Open `cocoWriter.xcodeproj` and use the `cocoWriter` scheme. See the [project guide](../README.md) for signing, App Group setup and publishing configuration.

Swift Markdown 0.8.0 requires a compiler supporting Swift 6.2 or newer. The app uses Swift 5 language mode and targets iOS 17 or newer. All signing teams are blank in the public project; `org.example.cocoWriter` is a placeholder identifier.

The `cocoWriterShare` extension and main app must use the same App Group. `tools/configure-signing.py` updates their identifiers together. App Group identifiers rewritten by AltStore are resolved using `ALTAppGroups`.

`python3 ../tools/test-ios.py` runs the XCTest suite on a dedicated simulator. No credentials or live publication are used by the tests.
