# cocoWriter iOS

Open `cocoWriter.xcodeproj` and use the `cocoWriter` scheme. See the [project guide](../README.md) for signing, App Group setup and publishing configuration.

Swift Markdown 0.8.0 requires a compiler supporting Swift 6.2 or newer. The app uses Swift 5 language mode and targets iOS 17 or newer. All signing teams are blank in the public project; `org.example.cocoWriter` is a placeholder identifier.

The main app, `cocoWriterShare` and `cocoWriterTodos` extensions must use the same App Group. `tools/configure-signing.py` updates their identifiers together. App Group identifiers rewritten by AltStore are resolved using `ALTAppGroups`.

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

## TODO widgets

On iOS 17 or newer, open the updated app once, then add **TODO** from the Home
Screen widget gallery. Small (2×2) and medium (4×2) show a compact checkbox,
single-line task name and deadline. Long names truncate; undated tasks show a dash.
Edit each widget to choose earliest deadline (default, undated last), oldest added,
or newest added. Widgets do not scroll. The remaining count and background open
the app's pending TODO list; tapping a checkbox completes that task.

The `.Todos` bundle identifier is derived from the app identifier when generating
a variant. Existing app/share identifiers and the App Group stay unchanged. The
widget is embedded only for iOS, not Mac Catalyst. AltStore packaging signs all
three bundles with their shared App Group entitlement before AltStore re-signs.

The original notes file remains in Application Support. Only pending task IDs,
the first display line (up to 160 characters), dates and revisions are projected
to `TaskWidgets/tasks.json` in the existing App Group. Widget completions are
atomic command files; they immediately filter widget results, and the app merges
them at startup, foregrounding, or within five seconds while active. Repeated or
stale commands never toggle a completed, edited or deleted note back. Failed saves
keep commands for retry. Names are marked privacy-sensitive. Device data remains
local; no new network service is used.

Validation: `TaskWidgetTests` covers ordering, projection privacy, restart/repeat
completion, stale revisions, trash and failed saves. On a simulator or device,
check both sizes, long titles, no deadline, overdue dates, empty state, per-widget
sorting, completion while the app is terminated, and the background link into
TODOs. A real AltStore upgrade must additionally verify the widget gallery and
shared container access after re-signing; simulator tests cannot certify that.
