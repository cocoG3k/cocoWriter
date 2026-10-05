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
