# Third-party software

cocoWriter's own code is MIT licensed. The upstream terms below continue to apply to dependencies and their notices.

| Component | Version | License | Bundled notice |
| --- | --- | --- | --- |
| Swift Markdown | 0.8.0 | Apache-2.0 WITH Swift-exception | `ios/cocoWriter/SwiftMarkdown-LICENSE.txt`, `SwiftMarkdown-NOTICE.txt` |
| swift-cmark | 0.9.0 | BSD-2-Clause AND MIT | `ios/cocoWriter/SwiftCmark-COPYING.txt` |

The exact iOS package revisions are pinned in `ios/cocoWriter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and recorded in `ios/cocoWriter/SBOM.cdx.json`. Apple system frameworks are platform dependencies. Upstream test tools and CommonMark specification assets mentioned in cmark's notices are not bundled into the app.

The blog's dependency versions and licenses are listed in [site-template/THIRD_PARTY_NOTICES.md](site-template/THIRD_PARTY_NOTICES.md). Its lockfile pins the complete npm dependency tree. These npm packages are build tools; their code is not served as browser JavaScript by the generated blog.

The separate CocoG Writer application is the source of the app implementation. This fork replaces its publishing destination, personal signing configuration and branding assets. The original project's source remains untouched.
## sfuji.org preview templates

`preview-templates/sfuji-diary.html` and `sfuji-journey.html` contain the article-page shell and generated CSS from [sfujibijutsukan/sfujibijutsukan.github.io](https://github.com/sfujibijutsukan/sfujibijutsukan.github.io), commit `fe21042936871bbea0cca0432163ee4709bdf2fa`. Article bodies, scripts, and comment widgets have been removed; placeholders are used for draft content. The upstream theme and Tailwind CSS MIT licenses are included in `preview-templates/sfuji-LICENSE.txt` and in the HTML templates themselves.
