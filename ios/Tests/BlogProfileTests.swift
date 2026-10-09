import XCTest
@testable import cocoWriter

final class BlogProfileTests: XCTestCase {
    private func draft(_ profile: BlogProfile) -> Draft {
        var draft = Draft(kind: .diary); draft.blogProfile = profile
        draft.title = "日本語 \"title\""; draft.description = "説明"; draft.tags = "日記, test"
        draft.date = profile.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-10-05 12:34:56")!
        draft.body = "本文\n"
        return draft
    }
    func testExtraHeadersPreserveOriginalValuesAndRoundTripEdits() throws {
        for format in [BlogProfile.Format.yaml, .toml, .json] {
            var profile = BlogProfile.standard
            profile.frontMatter.format = format
            profile.frontMatter.extra = ["draft": .bool(true), "layout": .string("post"), "weight": .number(3), "aliases": .strings(["/old/"])]
            let original = draft(profile)
            var changedDefaults = profile
            changedDefaults.frontMatter.extra["draft"] = .bool(false)
            var imported = try RepositoryArticleMarkdown.decode(path: original.path, sha: "old", markdown: original.markdown, profile: changedDefaults)
            XCTAssertEqual(imported.extraHeaderFields["draft"], .bool(true))
            XCTAssertEqual(imported.markdown, original.markdown)
            try imported.setExtraHeader("draft", value: .bool(false))
            try imported.setExtraHeader("layout", value: .string("page"))
            try imported.setExtraHeader("weight", value: .number(7))
            try imported.setExtraHeader("aliases", value: .strings(["/new/", "/other/"]))
            XCTAssertTrue(imported.hasUnpublishedEdits)
            let saved = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(imported))
            XCTAssertEqual(saved.markdown, imported.markdown)
            let reloaded = try RepositoryArticleMarkdown.decode(path: saved.path, sha: "new", markdown: saved.markdown, profile: changedDefaults)
            XCTAssertEqual(reloaded.extraHeaderFields["draft"], .bool(false))
            XCTAssertEqual(reloaded.extraHeaderFields["layout"], .string("page"))
            XCTAssertEqual(reloaded.extraHeaderFields["weight"], .number(7))
            XCTAssertEqual(reloaded.extraHeaderFields["aliases"], .strings(["/new/", "/other/"]))
            XCTAssertEqual(reloaded.path, original.path)
            XCTAssertEqual(reloaded.body, saved.body)
        }
    }
    func testAdditionalHeaderEditsKeepUnknownMetadataAndOldDraftsReadable() throws {
        var profile = BlogProfile.standard
        profile.frontMatter.requireDescription = false
        profile.frontMatter.extra = ["draft": .bool(false), "layout": .string("post")]
        let markdown = "---\r\ntitle: 'Title'\r\ndate: '2026-01-22'\r\ndraft: true # keep until edited\r\ncustom: 'original'\r\nnested:\r\n  value: true\r\n---\r\nBody\r\n"
        var imported = try RepositoryArticleMarkdown.decode(path: "src/content/diary/post.md", sha: "old", markdown: markdown, profile: profile)
        XCTAssertEqual(imported.markdown, markdown)
        XCTAssertEqual(imported.extraHeaderFields["custom"], .string("original"))
        XCTAssertNil(imported.extraHeaderFields["nested"])
        try imported.setExtraHeader("custom", value: .string("edited"))
        XCTAssertTrue(imported.markdown.contains("draft: true # keep until edited\r\n"))
        XCTAssertTrue(imported.markdown.contains("nested:\r\n  value: true\r\n"))
        XCTAssertFalse(imported.markdown.contains("layout:"))
        try imported.setExtraHeader("layout", value: .string("page"))
        XCTAssertTrue(imported.markdown.contains("layout: \"page\"\r\n"))
        XCTAssertThrowsError(try imported.setExtraHeader("title", value: .string("wrong")))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as? [String: Any])
        object.removeValue(forKey: "extraHeaderEdits")
        let legacy = try JSONDecoder().decode(Draft.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.extraHeaderEdits)
        XCTAssertEqual(legacy.markdown, markdown)
    }
    func testNewArticleExtraHeaderOverridesDoNotChangeCategoryDefaults() throws {
        var profile = BlogProfile.standard
        profile.frontMatter.extra = ["draft": .bool(true)]
        var article = draft(profile)
        try article.setExtraHeader("draft", value: .bool(false))
        XCTAssertEqual(article.profile.frontMatter.extra["draft"], .bool(true))
        XCTAssertTrue(article.markdown.contains("draft: false"))
    }
    func testBundledProfileIsValidatedAndMatchesDefault() throws {
        XCTAssertNil(BlogProfile.configurationError)
        XCTAssertEqual(BlogProfile.current, .standard)
        let bytes = try JSONEncoder().encode(BlogProfile.standard)
        XCTAssertEqual(try BlogProfile.decode(bytes), .standard)
    }
    func testDirectoryDepthRootExtensionsAndBoundaries() throws {
        var profile = BlogProfile.standard
        profile.articleDirectory = "docs/blog/記事"; profile.filenameTemplate = "{year}/{month}/ios-{id}.markdown"
        try profile.validate()
        let draft = draft(profile)
        XCTAssertTrue(draft.path.hasPrefix("docs/blog/記事/2026/10/ios-"))
        XCTAssertTrue(RepositoryArticleMarkdown.validPath(draft.path, profile: profile))
        for path in ["docs/blog/記事-other/x.md", "docs/blog/記事/../x.md", "docs/blog/記事/_index.md"] {
            XCTAssertFalse(RepositoryArticleMarkdown.validPath(path, profile: profile))
        }
        profile.articleDirectory = ""
        XCTAssertTrue(profile.validArticlePath("post.md"))
        XCTAssertFalse(profile.validArticlePath("/post.md"))
    }
    func testJekyllFilenameDateAndExtraFields() throws {
        var profile = BlogProfile.standard
        profile.articleDirectory = "_posts"; profile.filenameTemplate = "{date}-ios-{id}.md"
        profile.frontMatter.dateStyle = .jekyll; profile.frontMatter.extra = ["layout": .string("post"), "published": .bool(true)]
        let original = draft(profile)
        XCTAssertTrue(original.path.hasPrefix("_posts/2026-10-05-ios-"))
        XCTAssertTrue(original.markdown.contains("layout: \"post\""))
        var imported = try RepositoryArticleMarkdown.decode(path: original.path, sha: "a", markdown: original.markdown, profile: profile)
        XCTAssertEqual(imported.id, original.id)
        XCTAssertEqual(imported.date, original.date)
        imported.date.addTimeInterval(86400)
        XCTAssertEqual(imported.path, original.path)
        XCTAssertTrue(imported.markdown.contains("2026-10-06 12:34:56 +0900"))
    }
    func testAllFormatsRoundTripAndPreserveMetadata() throws {
        for format in [BlogProfile.Format.yaml, .toml, .json] {
            var profile = BlogProfile.standard
            profile.articleDirectory = "content/posts"; profile.frontMatter.format = format
            profile.frontMatter.dateStyle = .iso8601; profile.frontMatter.fields.description = "summary"
            profile.frontMatter.fields.tags = "categories"
            profile.frontMatter.extra = ["draft": .bool(false), "layout": .string("post"), "weight": .number(10), "aliases": .strings(["/old/"])]
            let original = draft(profile)
            let dateLine = original.markdown.split(separator: "\n").first { $0.hasPrefix("date") || $0.hasPrefix("  \"date\"") }.map(String.init)
            if format == .json { XCTAssertTrue(dateLine?.hasPrefix("  \"date\": \"") == true) }
            else { XCTAssertTrue(dateLine?.hasPrefix("date" + (format == .toml ? " = 2026-" : ": 2026-")) == true) }
            XCTAssertFalse(original.markdown.contains(#"\/old\/"#))
            var imported = try RepositoryArticleMarkdown.decode(path: original.path, sha: "old", markdown: original.markdown, profile: profile)
            XCTAssertEqual(imported.markdown, original.markdown)
            XCTAssertEqual(imported.tags, original.tags)
            XCTAssertEqual(imported.date, original.date)
            imported.title = "変更したタイトル"; imported.body += "追記\n"
            let edited = try RepositoryArticleMarkdown.decode(path: original.path, sha: "new", markdown: imported.markdown, profile: profile)
            XCTAssertEqual(edited.title, imported.title); XCTAssertEqual(edited.body, imported.body)
            XCTAssertTrue(edited.markdown.contains("layout")); XCTAssertTrue(edited.markdown.contains("aliases")); XCTAssertTrue(edited.markdown.contains("draft"))
        }
    }
    func testYAMLDateIsEmittedAsTypedScalar() {
        let markdown = draft(.standard).markdown
        XCTAssertTrue(markdown.contains("\ndate: 2026-10-05\n"))
        XCTAssertFalse(markdown.contains("\ndate: \"2026-10-05\"\n"))
    }
    func testTOMLRootFieldsAndUnknownTablesRemainSeparate() throws {
        var profile = BlogProfile.standard; profile.articleDirectory = "content/posts"; profile.frontMatter.requireDescription = false
        let text = "+++\r\ntitle = 'old' # comment\r\ndate = 2026-10-05T12:34:56+09:00\r\ntags = ['日記', 'a,b']\r\n[params]\r\ntitle = 'nested'\r\ncustom = true\r\n+++\r\n本文\r\n"
        var imported = try RepositoryArticleMarkdown.decode(path: "content/posts/test.md", sha: "a", markdown: text, profile: profile)
        XCTAssertEqual(imported.markdown, text)
        imported.description = "追加"; imported.title = "new"
        XCTAssertTrue(imported.markdown.contains("description = \"追加\"\r\n[params]"))
        XCTAssertTrue(imported.markdown.contains("title = 'nested'\r\ncustom = true"))
        XCTAssertEqual(try RepositoryArticleMarkdown.decode(path: imported.path, sha: "b", markdown: imported.markdown, profile: profile).description, "追加")
    }
    func testJSONNestedObjectsAndQuotedBraces() throws {
        var profile = BlogProfile.standard; profile.frontMatter.requireDescription = false
        let text = "{\"title\":\"a } \\\" {\",\"date\":\"2026-10-05\",\"params\":{\"custom\":[1,true]}}\n\n本文"
        var imported = try RepositoryArticleMarkdown.decode(path: "src/content/diary/test.md", sha: "a", markdown: text, profile: profile)
        XCTAssertEqual(imported.markdown, text)
        imported.title = "new"
        XCTAssertTrue(imported.markdown.contains("custom"))
        XCTAssertEqual(try RepositoryArticleMarkdown.decode(path: imported.path, sha: "b", markdown: imported.markdown, profile: profile).title, "new")
    }
    func testImageStoragePublicPathMappingAndMarkdownReferences() throws {
        var profile = BlogProfile.standard
        profile.imageDirectory = "docs/static/media/uploads"; profile.imagePublicPath = "/media/photos"
        let path = profile.imagePath(id: UUID(), hash: String(repeating: "a", count: 64))
        let publicPath = try XCTUnwrap(profile.publicPath(for: path))
        XCTAssertTrue(publicPath.hasPrefix("/media/photos/"))
        XCTAssertEqual(profile.repositoryImagePath(for: publicPath), path)
        let images = ArticleImageReferences.imported(from: "![写真](\(publicPath))", profile: profile)
        XCTAssertEqual(images.first?.repositoryPath, path); XCTAssertEqual(images.first?.publicPath, publicPath)
        XCTAssertNil(profile.repositoryImagePath(for: publicPath + "?x=1"))
        XCTAssertFalse(profile.validImagePath("docs/static/media/uploads-other/" + path))
    }
    func testAbsoluteImagesIncludeProjectPagesBaseExactlyOnce() throws {
        var profile = BlogProfile.standard; profile.imageReferenceStyle = .absolute
        profile.imageDirectory = "assets/images/posts"; profile.imagePublicPath = "/assets/images/posts"
        let site = SiteConfiguration(owner: "example", repository: "journal", website: "https://example.github.io/journal/")
        let path = profile.imagePath(id: UUID(), hash: String(repeating: "a", count: 64))
        let reference = try XCTUnwrap(profile.imageReference(for: path, configuration: site))
        XCTAssertTrue(reference.hasPrefix("https://example.github.io/journal/assets/images/posts/"))
        XCTAssertEqual(profile.repositoryImageReference(reference, configuration: site), path)
        XCTAssertEqual(ArticleImageReferences.imported(from: "![写真](\(reference))", profile: profile, configuration: site).first?.repositoryPath, path)
        XCTAssertNil(profile.repositoryImageReference(reference.replacingOccurrences(of: "example.github.io", with: "other.example"), configuration: site))
        let customDomain = SiteConfiguration(website: "https://blog.example.org/")
        XCTAssertTrue(try XCTUnwrap(profile.imageReference(for: path, configuration: customDomain)).hasPrefix("https://blog.example.org/assets/images/posts/"))
    }
    func testInvalidProfilesAndBadEditableHeadersAreRejected() throws {
        for path in ["../articles", "/articles", "a//b", "a/./b", "a\\b"] {
            var profile = BlogProfile.standard; profile.articleDirectory = path
            XCTAssertThrowsError(try profile.validate())
        }
        var profile = BlogProfile.standard
        profile.frontMatter.fields.title = "date"; XCTAssertThrowsError(try profile.validate())
        profile = .standard; profile.frontMatter.extra = ["title": .string("fixed")]; XCTAssertThrowsError(try profile.validate())
        profile = .standard; profile.frontMatter.timeZone = "not-a-zone"; XCTAssertThrowsError(try profile.validate())
        profile = .standard; profile.filenameTemplate = "{title}.md"; XCTAssertThrowsError(try profile.validate())
        for header in ["title: x\ntitle: y\ndescription: z\ndate: 2026-10-05", "title: x\ndescription: y\ndate: 2026-02-30", "title: {nested: x}\ndescription: y\ndate: 2026-10-05"] {
            XCTAssertThrowsError(try RepositoryArticleMarkdown.decode(path: "src/content/diary/bad.md", sha: "a", markdown: "---\n" + header + "\n---\nbody", profile: .standard))
        }
        XCTAssertThrowsError(try RepositoryArticleMarkdown.decode(path: "src/content/diary/bad.md", sha: "a", markdown: "+++\ntitle = '''unsupported'''\ndescription = 'x'\ndate = 2026-10-05\n+++\nbody", profile: .standard))
    }
    func testSavedDraftKeepsItsBuildProfileAndLegacyDraftUsesDefault() throws {
        var profile = BlogProfile.standard; profile.articleDirectory = "_posts"; profile.frontMatter.format = .toml
        let saved = draft(profile)
        let restored = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.profile, profile); XCTAssertEqual(restored.path, saved.path); XCTAssertEqual(restored.markdown, saved.markdown)
        var legacy = saved; legacy.blogProfile = nil
        let restoredLegacy = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restoredLegacy.profile, .standard)
    }
    func testConfiguredDirectoryAndFormatReachGitHubContentsAPI() async throws {
        var profile = BlogProfile.standard
        profile.articleDirectory = "docs/blog/posts"; profile.frontMatter.format = .toml
        profile.frontMatter.fields.description = "summary"
        var article = draft(profile); article.pendingMarkdown = article.markdown
        let configuration = SiteConfiguration(owner: "example", repository: "custom-blog", branch: "publish/blog", website: "https://example.github.io/custom-blog/")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ProfileFixtureProtocol.self]
        ProfileFixtureProtocol.requests = []
        let publisher = GitHubPublisher(configuration: configuration, session: URLSession(configuration: sessionConfig), profile: profile)
        let result = try await publisher.publish(article, token: "fixture")
        XCTAssertEqual(result.sha, "new")
        let requests = ProfileFixtureProtocol.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(requests[0].url?.path, "/repos/example/custom-blog/contents/" + article.path)
        XCTAssertEqual(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "publish/blog")
        let put = requests[1]
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: ProfileFixtureProtocol.body(put)) as? [String: Any])
        XCTAssertEqual(object["branch"] as? String, "publish/blog")
        let bytes = try XCTUnwrap(Data(base64Encoded: object["content"] as! String))
        XCTAssertEqual(String(data: bytes, encoding: .utf8), article.markdown)
        XCTAssertTrue(article.markdown.hasPrefix("+++\n")); XCTAssertTrue(article.markdown.contains("summary = "))
        var changedProfile = profile; changedProfile.articleDirectory = "other/posts"
        let incompatible = GitHubPublisher(configuration: configuration, session: URLSession(configuration: sessionConfig), profile: changedProfile)
        do { _ = try await incompatible.publish(article, token: "fixture"); XCTFail("Must refuse a different saved profile") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ビルド設定")) }
        XCTAssertEqual(ProfileFixtureProtocol.requests.count, 2)
    }
    @MainActor func testRefreshKeepsArticlesFromAnEarlierBuildProfile() throws {
        var profile = BlogProfile.standard; profile.articleDirectory = "previous/posts"
        let old = try RepositoryArticleMarkdown.decode(path: "previous/posts/old.md", sha: "published", markdown: draft(profile).markdown, profile: profile)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        XCTAssertTrue(store.update(old)); XCTAssertTrue(store.mergePublishedArticles([]))
        XCTAssertEqual(store.drafts.first?.remoteSHA, "published")
        XCTAssertEqual(store.drafts.first?.profile, profile)
    }
    func testMismatchedImageMappingIsRejectedBeforeNetwork() async throws {
        var article = draft(.standard)
        let hash = String(repeating: "a", count: 64)
        let path = "different/photos/" + article.id.uuidString.lowercased() + "/" + hash + ".jpg"
        let image = ArticleImage(hash: hash, repositoryPath: path, width: 1, height: 1, byteCount: 1, publishedPath: "/images/diary/" + article.id.uuidString.lowercased() + "/" + hash + ".jpg")
        article.images = [image]; article.body = image.markdown; article.pendingMarkdown = article.markdown
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [ProfileFixtureProtocol.self]
        ProfileFixtureProtocol.requests = []
        let publisher = GitHubPublisher(configuration: SiteConfiguration(owner: "example", repository: "blog"), session: URLSession(configuration: sessionConfig))
        do { _ = try await publisher.publish(article, token: "fixture"); XCTFail("Must reject incompatible image paths") }
        catch { XCTAssertTrue(error.localizedDescription.contains("画像")) }
        XCTAssertTrue(ProfileFixtureProtocol.requests.isEmpty)
    }
}

final class ArticleCategoryTests: XCTestCase {
    private var journey: ArticleCategory {
        var profile = BlogProfile.current
        profile.articleDirectory = "src/content/journey"
        profile.imageDirectory = "public/images/journey"; profile.imagePublicPath = "/images/journey"
        return ArticleCategory(name: "旅", profile: profile)
    }
    private var site: SiteConfiguration { SiteConfiguration(owner: "example", repository: "journal", website: "https://example.org/") }
    private func song() -> MusicItem {
        var item = MusicItem(); item.title = "旅で聴いた曲"; item.comment = "紹介文"
        item.spotifyURL = "https://open.spotify.com/track/0123456789ABCDEFGHIJKL"; item.confirmed = true
        return item
    }
    func testTagSelectionPreservesCustomTagsAndCategory() throws {
        var article = Draft(kind: .diary); article.tags = "思い出, 音楽"
        try article.selectCategory(journey, configuration: site)
        let profile = article.profile, path = article.path
        article.tags = ArticleTags.toggling("散歩", in: article.tags)
        XCTAssertEqual(article.tags, "思い出, 音楽, 散歩")
        article.tags = ArticleTags.toggling("音楽", in: article.tags)
        XCTAssertEqual(article.tags, "思い出, 散歩")
        XCTAssertEqual(article.profile, profile); XCTAssertEqual(article.path, path)
        try article.selectCategory(ArticleCategory.initial[0], configuration: site)
        XCTAssertEqual(article.tags, "思い出, 散歩")
        XCTAssertEqual(try ArticleTags.normalized([" 散歩 ", "音楽", "散歩"]), ["散歩", "音楽"])
        for invalid in ["", "散歩,音楽", "散歩、音楽", "散歩\n音楽"] {
            XCTAssertThrowsError(try ArticleTags.normalized([invalid]))
        }
    }
    @MainActor func testTagSuggestionsPersistIndependentlyOfArticleTags() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "tag-test-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: folder); isolated.removePersistentDomain(forName: suite) }
        let store = DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated)
        XCTAssertEqual(store.tagSuggestions, ArticleTags.initial)
        try store.saveTagSuggestions([" 散歩 ", "音楽", "散歩"])
        var article = store.newDraft(); article.tags = "音楽, 個人メモ"
        XCTAssertTrue(store.update(article))
        let reopened = DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated)
        XCTAssertEqual(reopened.tagSuggestions, ["散歩", "音楽"])
        XCTAssertThrowsError(try reopened.saveTagSuggestions(["不正,タグ"]))
        XCTAssertEqual(reopened.tagSuggestions, ["散歩", "音楽"])
        try reopened.saveTagSuggestions([])
        XCTAssertEqual(reopened.drafts.first?.tags, "音楽, 個人メモ")
        XCTAssertEqual(reopened.categories, ArticleCategory.initial)
        XCTAssertTrue(DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated).tagSuggestions.isEmpty)
    }
    func testMusicCanBeAddedToAnyArticleAndImportedMarkdown() throws {
        var article = Draft(kind: .diary); article.title = "旅の記録"; article.description = "説明"; article.body = "本文"
        XCTAssertNil(article.validation)
        article.music = [song()]
        XCTAssertTrue(article.containsMusic); XCTAssertTrue(ArticleFilter.music.includes(article))
        XCTAssertNil(article.validation)
        XCTAssertTrue(article.markdown.contains("紹介文")); XCTAssertTrue(article.markdown.contains("<iframe"))
        XCTAssertTrue(BlogPreviewHTML.document(article).contains("旅で聴いた曲"))
        article.music[0].confirmed = false; XCTAssertNotNil(article.validation)
        article.music = []; XCTAssertNil(article.validation); XCTAssertFalse(article.markdown.contains("<iframe"))
        let original = article.markdown.replacingOccurrences(of: "---\n\n本文", with: "custom: keep\n---\n\n本文")
        var imported = try RepositoryArticleMarkdown.decode(path: article.path, sha: "v1", markdown: original)
        imported.music = [song()]
        let sent = imported.markdown
        XCTAssertTrue(sent.contains("custom: keep")); XCTAssertTrue(sent.contains("紹介文"))
        imported.repositorySource = RepositorySource(markdown: sent, title: imported.title, description: imported.description, date: imported.date, tags: imported.tags)
        XCTAssertEqual(imported.markdown, sent)
        XCTAssertEqual(imported.markdown.components(separatedBy: "<iframe").count - 1, 1)
    }
    func testCategorySwitchKeepsContentAndRemapsPhotoReferences() throws {
        var article = Draft(kind: .diary); article.title = "旅の記録"; article.description = "説明"; article.tags = "思い出"
        let hash = String(repeating: "a", count: 64), oldPath = article.profile.imagePath(id: article.id, hash: String(repeating: "a", count: 64))
        let oldReference = try XCTUnwrap(article.profile.imageReference(for: oldPath, configuration: site))
        let image = ArticleImage(hash: hash, repositoryPath: oldPath, width: 10, height: 20, byteCount: 100, publishedPath: oldReference)
        article.images = [image]; article.body = "本文\n" + image.markdown
        article.music = [song()]; article.music[0].comment += "\n" + image.markdown
        let id = article.id
        try article.selectCategory(journey, configuration: site)
        XCTAssertEqual(article.id, id); XCTAssertEqual(article.tags, "思い出"); XCTAssertEqual(article.title, "旅の記録")
        XCTAssertTrue(article.path.hasPrefix("src/content/journey/")); XCTAssertTrue(article.supportsCurrentProfile); XCTAssertNil(article.validation)
        XCTAssertEqual(article.attachedImages.first?.hash, hash)
        XCTAssertTrue(article.attachedImages[0].repositoryPath.hasPrefix("public/images/journey/"))
        XCTAssertTrue(article.body.contains("/images/journey/")); XCTAssertTrue(article.music[0].comment.contains("/images/journey/"))
        XCTAssertEqual(article.referencedImages.count, 1)
        let restored = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(article))
        XCTAssertEqual(restored.profile, journey.profile); XCTAssertEqual(restored.categoryBaseProfile, .current)
        let projectSite = SiteConfiguration(owner: "example", repository: "journal", website: "https://example.github.io/journal/")
        let html = BlogPreviewHTML.document(restored, configuration: projectSite)
        XCTAssertTrue(html.contains("https://example.github.io/journal/images/journey/"))
        article.repositoryPath = article.path
        let frozen = article
        XCTAssertThrowsError(try article.selectCategory(ArticleCategory.initial[0], configuration: site)); XCTAssertEqual(article, frozen)
        var unsupported = restored; unsupported.categoryBaseProfile = nil; unsupported.articleSettingsVersion = nil
        XCTAssertFalse(unsupported.supportsCurrentProfile)
    }
    @MainActor func testSelectedCategoriesPersistAndRefreshOnlyScannedProfiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "category-test-" + UUID().uuidString
        // Keep this test's preferences isolated from the user's app settings.
        let isolated = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: folder); isolated.removePersistentDomain(forName: suite) }
        let store = DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated)
        try store.saveCategories(ArticleCategory.initial + [journey])
        var article = store.newDraft(); article.title = "旅"; article.description = "説明"
        try article.selectCategory(journey, configuration: site); article.repositoryPath = article.path; article.remoteSHA = "published"
        XCTAssertTrue(store.update(article))
        var changed = store.categories; changed[1].profile.imagePublicPath = "/other"
        try store.saveCategories(changed)
        XCTAssertEqual(store.drafts.first?.profile, journey.profile)
        changed = store.categories; changed[1].isEnabled = false; try store.saveCategories(changed)
        XCTAssertTrue(store.mergePublishedArticles([], scannedProfiles: store.enabledCategories.map(\.profile)))
        XCTAssertEqual(store.drafts.first?.remoteSHA, "published")
        let reopened = DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated)
        XCTAssertEqual(reopened.categories, changed); XCTAssertEqual(reopened.drafts.first?.profile, journey.profile)
        XCTAssertTrue(reopened.mergePublishedArticles([], scannedProfiles: [journey.profile]))
        XCTAssertNil(reopened.drafts.first?.remoteSHA)
        XCTAssertThrowsError(try reopened.saveCategories(changed.map { var value = $0; value.isEnabled = false; return value }))
        XCTAssertThrowsError(try reopened.saveCategories(ArticleCategory.initial + ArticleCategory.initial))
    }
    func testRefreshOnlyFetchesNewOrChangedArticleBodies() async throws {
        let token = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CategoryFixtureProtocol.self]
        let publisher = GitHubPublisher(configuration: site, session: URLSession(configuration: config))
        let categories = ArticleCategory.initial + [journey]
        let initial = try await publisher.publishedArticles(token: token, categories: categories)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 2)
        var edited = initial
        edited[0].title = "Local edits"; edited[0].body = "Do not upload or discard"
        try edited[0].setExtraHeader("draft", value: .bool(true))
        let refreshed = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: edited)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 2)
        XCTAssertEqual(refreshed.map(\.markdown), initial.map(\.markdown))
        var changed = initial
        changed[0].remoteSHA = String(repeating: "0", count: 40)
        _ = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: changed)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 3)
        var damaged = initial
        damaged[0].repositorySource?.markdown += "stale snapshot"
        _ = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: damaged)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 4)
        var legacy = initial
        legacy[0].publishedMarkdown = legacy[0].repositorySource?.markdown
        legacy[0].repositorySource = nil
        _ = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: legacy)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 4)
        legacy[0].publishedMarkdown = nil
        _ = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: legacy)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 5)
        var otherDestination = initial
        otherDestination[0].remoteDestination = "other/repo@main"
        _ = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: otherDestination)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 6)
        let withNewArticle = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: [initial[0]])
        XCTAssertEqual(withNewArticle.count, 2)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 7)
        var pending = initial
        pending[0].pendingMarkdown = "Unconfirmed send"
        pending[0].pendingDeletionSHA = pending[0].remoteSHA
        _ = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: pending)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 7)
        var disabledCategories = categories
        disabledCategories[1].isEnabled = false
        let filtered = try await publisher.publishedArticles(token: token, categories: disabledCategories, knownArticles: initial)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(CategoryFixtureProtocol.blobCount(token), 7)
    }
    func testRuntimeArticleFormatsAndFieldsRoundTripWithoutRebuilding() throws {
        for format in [BlogProfile.Format.yaml, .toml, .json] {
            var category = journey
            category.profile.frontMatter.format = format
            category.profile.frontMatter.fields = BlogProfile.Fields(title: "headline", description: "summary", date: "publishedAt", tags: "labels")
            category.profile.frontMatter.dateStyle = .iso8601
            category.profile.frontMatter.extra = ["draft": .bool(false), "weight": .number(3), "section": .string("旅"), "aliases": .strings(["one", "two"])]
            category.profile.filenameTemplate = "{date}-{id}.markdown"
            try ArticleCategory.validate([category])
            var draft = Draft(kind: .diary); draft.title = "新形式の記事"; draft.description = "説明"; draft.tags = "散歩, 音楽"; draft.body = "本文"
            try draft.selectCategory(category, configuration: site)
            XCTAssertNil(draft.validation); XCTAssertTrue(draft.supportsCurrentProfile)
            XCTAssertEqual(draft.publicationProfile, category.profile)
            XCTAssertTrue(draft.path.hasSuffix(".markdown")); XCTAssertTrue(draft.markdown.contains("headline"))
            let decoded = try RepositoryArticleMarkdown.decode(path: draft.path, sha: "v1", markdown: draft.markdown, profile: category.profile)
            XCTAssertEqual(decoded.title, draft.title); XCTAssertEqual(decoded.tags, draft.tags); XCTAssertEqual(decoded.body.trimmingCharacters(in: .whitespacesAndNewlines), "本文")
            let saved = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(draft))
            XCTAssertEqual(saved.profile, category.profile); XCTAssertEqual(saved.articleSettingsVersion, 1); XCTAssertNil(saved.validation)
            var future = saved; future.articleSettingsVersion = 2
            XCTAssertFalse(future.supportsCurrentProfile)
            var invalid = saved; invalid.blogProfile?.frontMatter.fields.date = "headline"
            XCTAssertFalse(invalid.supportsCurrentProfile)
        }
    }
    @MainActor func testEditingSettingsKeepsExistingArticlesAndPhotosAtOriginalPaths() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "article-settings-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: folder); isolated.removePersistentDomain(forName: suite) }
        let store = DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated)
        try store.saveCategories([journey])
        var old = store.newDraft(); old.title = "既存記事"; old.description = "説明"
        let path = old.profile.imagePath(id: old.id, hash: String(repeating: "a", count: 64))
        let reference = try XCTUnwrap(old.profile.imageReference(for: path, configuration: site))
        old.images = [ArticleImage(hash: String(repeating: "a", count: 64), repositoryPath: path, width: 10, height: 10, byteCount: 100, publishedPath: reference)]
        old.body = old.attachedImages[0].markdown; old.repositoryPath = old.path; old.remoteSHA = "v1"
        XCTAssertTrue(store.update(old))
        var changed = journey
        changed.profile.articleDirectory = "content/travel"; changed.profile.imageDirectory = "static/travel"; changed.profile.imagePublicPath = "/travel"
        changed.profile.frontMatter.format = .json; changed.profile.frontMatter.fields.title = "headline"
        try store.saveCategories([changed])
        let reopened = DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated)
        let saved = try XCTUnwrap(reopened.drafts.first)
        XCTAssertEqual(saved.profile, old.profile); XCTAssertEqual(saved.path, old.path); XCTAssertEqual(saved.markdown, old.markdown)
        XCTAssertEqual(saved.attachedImages, old.attachedImages); XCTAssertNil(saved.validation)
        let new = reopened.newDraft()
        XCTAssertEqual(new.profile, changed.profile); XCTAssertTrue(new.supportsCurrentProfile)
        XCTAssertTrue(reopened.mergePublishedArticles([], scannedProfiles: [changed.profile], scannedCategories: reopened.categories))
        XCTAssertEqual(reopened.drafts.first?.remoteSHA, "v1")
        changed = journey; changed.profile.frontMatter.fields.title = "headline"
        try reopened.saveCategories([changed])
        XCTAssertTrue(reopened.mergePublishedArticles([], scannedProfiles: [changed.profile], scannedCategories: reopened.categories))
        XCTAssertNil(reopened.drafts.first?.remoteSHA)
    }
    func testRemoteRefreshUsesSavedFieldsAfterCategorySettingsChange() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CategoryFixtureProtocol.self]
        let publisher = GitHubPublisher(configuration: site, session: URLSession(configuration: config))
        let initial = ArticleCategory.initial + [journey]
        let old = try await publisher.publishedArticles(token: "fixture", categories: initial)
        var changed = initial
        changed[0].profile.frontMatter.format = .toml
        changed[0].profile.frontMatter.fields = BlogProfile.Fields(title: "headline", description: "summary", date: "publishedAt", tags: "labels")
        changed[0].profile.articleExtensions = ["markdown"]
        changed[0].profile.filenameTemplate = "{id}.markdown"
        let refreshed = try await publisher.publishedArticles(token: "fixture", categories: changed, knownArticles: old)
        XCTAssertEqual(refreshed.count, old.count)
        for article in refreshed {
            let original = try XCTUnwrap(old.first { $0.path == article.path })
            XCTAssertEqual(article.profile, original.profile); XCTAssertEqual(article.markdown, original.markdown)
            XCTAssertTrue(article.supportsCurrentProfile)
        }
    }
    func testImportedArticleKeepsUnknownMetadataWhenSelectingDifferentFormat() throws {
        var source = Draft(kind: .diary); source.title = "既存"; source.description = "説明"; source.body = "本文"
        let markdown = source.markdown.replacingOccurrences(of: "---\n\n本文", with: "custom: keep\n---\n\n本文")
        var imported = try RepositoryArticleMarkdown.decode(path: source.path, sha: "v1", markdown: markdown)
        imported.repositoryPath = nil; imported.remoteSHA = nil
        var changed = journey; changed.profile.frontMatter.format = .toml
        XCTAssertThrowsError(try imported.selectCategory(changed, configuration: site))
        XCTAssertEqual(imported.markdown, markdown)
        changed.profile.frontMatter = imported.profile.frontMatter
        try imported.selectCategory(changed, configuration: site)
        XCTAssertEqual(imported.markdown, markdown)
        var duplicateKeys = journey; duplicateKeys.profile.frontMatter.fields.date = duplicateKeys.profile.frontMatter.fields.title
        XCTAssertThrowsError(try ArticleCategory.validate([duplicateKeys]))
    }
    @MainActor func testNestedCategoryRefreshKeepsUnscannedArticlesAndAvoidsDuplicates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "nested-category-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: folder); isolated.removePersistentDomain(forName: suite) }
        let store = DraftStore(url: folder.appendingPathComponent("drafts.json"), preferences: isolated)
        var parentProfile = BlogProfile.current; parentProfile.articleDirectory = "src/content"
        let parent = ArticleCategory(name: "記事", profile: parentProfile)
        var disabled = journey; disabled.isEnabled = false
        try store.saveCategories([parent, disabled])
        var original = Draft(kind: .diary); original.title = "旅"; original.description = "説明"
        try original.selectCategory(parent, configuration: site)
        original.repositoryPath = journey.id + "/existing.md"; original.remoteSHA = "v1"
        XCTAssertTrue(store.update(original))
        XCTAssertTrue(store.mergePublishedArticles([], scannedProfiles: [parentProfile], scannedCategories: store.categories))
        XCTAssertEqual(store.drafts.first?.remoteSHA, "v1")
        XCTAssertEqual(store.categoryID(for: original), journey.id)
        try store.saveCategories([parent, journey])
        var imported = try RepositoryArticleMarkdown.decode(path: original.path, sha: "v1", markdown: original.markdown, profile: journey.profile)
        imported.categoryBaseProfile = .current; imported.categoryName = journey.name
        XCTAssertTrue(store.mergePublishedArticles([imported], scannedProfiles: [parentProfile, journey.profile], scannedCategories: store.categories))
        XCTAssertEqual(store.drafts.count, 1); XCTAssertEqual(store.drafts.first?.id, original.id)
        XCTAssertEqual(store.drafts.first?.profile, original.profile)
        XCTAssertEqual(store.categoryLabel(for: original), "旅")
    }
    func testMultipleDirectoriesReadAndPublishWithTheirOwnPaths() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CategoryFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let publisher = GitHubPublisher(configuration: site, session: session)
        let directories = try await publisher.articleDirectories(token: "fixture")
        XCTAssertEqual(directories, ["docs", "src/content/diary", "src/content/journey"])
        let categories = ArticleCategory.initial + [journey]
        let articles = try await publisher.publishedArticles(token: "fixture", categories: categories)
        XCTAssertEqual(articles.count, 2)
        let trip = try XCTUnwrap(articles.first { $0.profile.articleDirectory == journey.id })
        XCTAssertEqual(trip.categoryName, "旅"); XCTAssertTrue(trip.supportsCurrentProfile)
        XCTAssertTrue(trip.markdown.contains("旅の本文"))
        var disabled = journey; disabled.isEnabled = false
        let diaryOnly = try await publisher.publishedArticles(token: "fixture", categories: ArticleCategory.initial + [disabled])
        XCTAssertEqual(diaryOnly.count, 1)
        var parent = BlogProfile.current; parent.articleDirectory = "src/content"
        let nested = try await publisher.publishedArticles(token: "fixture", categories: [ArticleCategory(name: "記事", profile: parent), disabled])
        XCTAssertEqual(nested.count, 1)
        XCTAssertTrue(nested.allSatisfy { !$0.path.contains("/journey/") })
        var new = Draft(kind: .diary); new.title = "新しい旅"; new.description = "説明"
        try new.selectCategory(journey, configuration: site); new.pendingMarkdown = new.markdown
        let target = GitHubPublisher(configuration: site, session: session, profile: new.publicationProfile)
        let result = try await target.publish(new, token: "fixture")
        XCTAssertEqual(result.sha, "new")
    }
}

private final class CategoryFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var blobCounts: [String: Int] = [:]
    static func blobCount(_ token: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return blobCounts["Bearer " + token, default: 0]
    }
    static func markdown(isTrip: Bool) -> String {
        "---\ntitle: \"記事\"\ndescription: \"説明\"\ndate: 2026-10-05\ntags: []\n---\n\n" + (isTrip ? "旅の本文" : "日記の本文")
    }
    static var diarySHA: String { PublicJPEG.blobSHA(Data(markdown(isTrip: false).utf8)) }
    static var journeySHA: String { PublicJPEG.blobSHA(Data(markdown(isTrip: true).utf8)) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = request.url!.path
        var status = 200, payload: [String: Any] = [:]
        let diarySHA = Self.diarySHA, journeySHA = Self.journeySHA
        if path.contains("/git/trees/") {
            payload = ["truncated": false, "tree": [
                ["path": "src/content/diary/old.md", "type": "blob", "sha": diarySHA],
                ["path": "src/content/journey/trip.md", "type": "blob", "sha": journeySHA],
                ["path": "docs/readme.md", "type": "blob", "sha": String(repeating: "c", count: 40)],
                ["path": "src/content/template/_index.md", "type": "blob", "sha": String(repeating: "d", count: 40)]]]
        } else if path.contains("/git/blobs/") {
            let isTrip = path.hasSuffix(journeySHA)
            Self.lock.lock()
            Self.blobCounts[request.value(forHTTPHeaderField: "Authorization") ?? "", default: 0] += 1
            Self.lock.unlock()
            let markdown = Self.markdown(isTrip: isTrip)
            payload = ["sha": isTrip ? journeySHA : diarySHA, "encoding": "base64", "content": Data(markdown.utf8).base64EncodedString()]
        } else if path.contains("/contents/") {
            XCTAssertTrue(path.contains("/contents/src/content/journey/ios-"))
            if request.httpMethod == "PUT" {
                status = 201; payload = ["content": ["sha": "new"], "commit": ["html_url": "https://github.com/example/journal/commit/test"]]
            } else { status = 404 }
        } else { XCTFail("Unexpected request: \(path)"); status = 404 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class PreviewTemplateTests: XCTestCase {
    func testSiteArticleHTMLBreaksRenderWithoutAllowingAttributesOrScripts() {
        let html = BlogPreviewHTML.renderMarkdown("前<br>後\n\n<br><br />\n\n<HR>\n\n<br onmouseover=\"alert(1)\">\n\n<script>alert(1)</script>")
        XCTAssertTrue(html.contains("前<br>後"))
        XCTAssertTrue(html.contains("<br><br />"))
        XCTAssertTrue(html.contains("<HR>"))
        XCTAssertTrue(html.contains("&lt;br onmouseover="))
        XCTAssertFalse(html.contains("<br onmouseover="))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
    }
    func testSiteTemplateEscapesMetadataAndReplacesPlaceholdersOnce() throws {
        var draft = Draft(kind: .diary)
        draft.title = "{{content}} <秘密> & \"quoted\""
        draft.description = "<img src=x onerror=alert(1)>"
        draft.body = "## 本文\n\n**確認**\n\n<script>alert(1)</script>"
        draft.date = draft.profile.formatter("yyyy-MM-dd HH:mm").date(from: "2026-10-05 00:30")!
        let template = "<html><head><title>{{title}}</title><style>.site {color: teal}</style></head><body class=\"site\"><h1>{{title}}</h1><p>{{description}}</p><time>{{dateJapanese}}</time><article>{{content}}</article><footer>{{siteTitle}}</footer></body></html>"
        let html = BlogPreviewHTML.document(draft, configuration: SiteConfiguration(title: "Site & name"), template: template)
        XCTAssertTrue(html.contains("<body class=\"site\">"))
        XCTAssertTrue(html.contains("<h1>{{content}} &lt;秘密&gt; &amp; &quot;quoted&quot;</h1>"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertTrue(html.contains("<time>2026/10/5</time>"))
        XCTAssertTrue(html.contains("<strong>確認</strong>"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("<footer>Site &amp; name</footer>"))
        XCTAssertTrue(html.contains("<head><meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("form-action 'none'"))
    }

    func testExistingSiteImagesResolveWithoutBecomingManagedUploads() {
        let site = SiteConfiguration(website: "https://example.org/journal/")
        let image = "/images/trip/airplane.jpeg"
        XCTAssertEqual(site.previewAssetURL(for: image)?.absoluteString, "https://example.org/images/trip/airplane.jpeg")
        XCTAssertNil(site.publicAssetURL(for: image))
        XCTAssertTrue(ArticleImageReferences.imported(from: "![写真](\(image))", configuration: site).isEmpty)
        XCTAssertTrue(BlogPreviewHTML.renderMarkdown("![写真](\(image))", configuration: site).contains("<img src=\"https://example.org/images/trip/airplane.jpeg\""))
        for unsafe in ["//evil.example/image.jpg", "/../secret.jpg", "/%2e%2e/secret.jpg", "file:///private/image.jpg", "javascript:alert(1)", "https://name:secret@example.org/image.jpg", "/images\\other.jpg"] {
            XCTAssertNil(site.previewAssetURL(for: unsafe), unsafe)
        }
    }

    func testThemeChoiceDoesNotChangeSavedArticleProfile() throws {
        let bytes = try JSONEncoder().encode(BlogProfile.standard)
        var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        json["preview"] = ["templateFile": "../preview-templates/custom.html"]
        XCTAssertEqual(try BlogProfile.decode(JSONSerialization.data(withJSONObject: json)), BlogProfile.standard)
        var draft = Draft(kind: .diary); draft.title = "test"; draft.description = "description"
        XCTAssertTrue(BlogPreviewHTML.document(draft, template: "").contains("下書きプレビュー · 未公開"))
    }
}

private final class ProfileFixtureProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            output.append(buffer, count: count)
        }
        return output
    }
    override func startLoading() {
        var copy = request; copy.httpBody = Self.body(request)
        Self.requests.append(copy)
        let put = request.httpMethod == "PUT"
        let response = HTTPURLResponse(url: request.url!, statusCode: put ? 201 : 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let json = put ? #"{"content":{"sha":"new"},"commit":{"html_url":"https://github.com/example/custom-blog/commit/fixture"}}"# : #"{"message":"Not Found"}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
