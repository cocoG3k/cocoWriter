# Contributing

Bug reports, documentation fixes and pull requests are welcome. Include reproduction steps, the app or template version, and whether the problem occurs on a simulator, iPhone or published site. Remove tokens, private notes and personal photos from reports.

Keep publishing configuration in `SiteConfiguration`; do not hard-code a personal owner, repository, branch or domain. Keep tokens in Keychain. Preserve pending operations, SHA checks and non-forced Git ref updates when changing publication behavior. Do not silently repurpose existing connected drafts for another destination.

Run the iOS XCTest suite for app changes. Run template tests and a build for blog changes; check both a root URL and a repository prefix for changes to links or images. Keep package lockfiles and upstream license notices with dependency updates.

Use a separate app identifier and simulator for development. Do not use an existing user's installed app or private data for tests. Changes to the original CocoG Writer project are outside this repository.

Contributions to this project are provided under the MIT license; dependency files retain their existing licenses.
