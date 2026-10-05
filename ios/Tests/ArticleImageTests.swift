import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import cocoWriter

final class ArticleImageTests: XCTestCase {
    private func fixture(type: UTType = .jpeg, width: Int = 2400, height: Int = 1200, orientation: Int = 6) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let output = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 139.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:04 12:00:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Private camera"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return output as Data
    }
    func testJPEGStripsLocationAndCameraMetadataAndBakesRotation() throws {
        let original = try fixture()
        XCTAssertThrowsError(try PublicJPEG.validate(original))
        let image = try PublicJPEG.prepare(data: original)
        XCTAssertEqual(image.width, 800); XCTAssertEqual(image.height, 1600)
        XCTAssertLessThanOrEqual(image.data.count, PublicJPEG.maxBytes)
        try PublicJPEG.validate(image.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary]); XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
    }
    func testHEICAndTransparentPNGBecomeOpaqueJPEGWithoutUpscaling() throws {
        for type in [UTType.heic, UTType.png] {
            let image = try PublicJPEG.prepare(data: fixture(type: type, width: 120, height: 60, orientation: 1))
            XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 60)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(image.data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
            let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 480,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: 120, height: 60))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let offset = (30 * 120 + 100) * 4
            XCTAssertGreaterThan(bytes[offset], 240); XCTAssertGreaterThan(bytes[offset + 1], 240); XCTAssertGreaterThan(bytes[offset + 2], 240)
        }
    }
    func testRejectsRenamedInvalidDataAndXMPAndComments() throws {
        XCTAssertThrowsError(try PublicJPEG.prepare(data: Data("fake.jpg".utf8)))
        let clean = try PublicJPEG.prepare(data: fixture(width: 100, height: 50, orientation: 1)).data
        for marker: UInt8 in [0xe1, 0xed, 0xfe] {
            let injected = clean.prefix(2) + Data([0xff, marker, 0, 6, 65, 66, 67, 68]) + clean.dropFirst(2)
            XCTAssertThrowsError(try PublicJPEG.validate(injected))
            let afterScan = clean.dropLast(2) + Data([0xff, marker, 0, 6, 65, 66, 67, 68]) + clean.suffix(2)
            XCTAssertThrowsError(try PublicJPEG.validate(afterScan))
        }
        XCTAssertThrowsError(try PublicJPEG.validate(clean + Data("trailing data".utf8)))
    }
    func testAnimatedGIFBecomesOneJPEGFrame() throws {
        let original = try fixture(type: .png, width: 100, height: 50, orientation: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, frame, nil); CGImageDestinationAddImage(destination, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try PublicJPEG.prepare(data: output as Data)
        XCTAssertTrue(result.flattenedAnimation)
        try PublicJPEG.validate(result.data)
    }
    func testImportRecoversImageReferencesAndIgnoresCodeExamples() throws {
        let id = UUID(), hash = String(repeating: "a", count: 64)
        let path = "/images/diary/\(id.uuidString.lowercased())/\(hash).jpg"
        let body = "![説明](\(path))\n\n`![例](/images/diary/\(UUID().uuidString.lowercased())/\(hash).jpg)`"
        let markdown = "---\ntitle: 写真\ndescription: 説明\ndate: 2026-10-04\n---\n\n" + body
        let draft = try RepositoryArticleMarkdown.decode(path: "src/content/diary/photo.md", sha: "article", markdown: markdown)
        XCTAssertEqual(draft.referencedImages.map(\.publicPath), [path])
        XCTAssertEqual(draft.markdown, markdown)
        let html = BlogPreviewHTML.document(draft, configuration: .fixture)
        XCTAssertTrue(html.contains("src=\"https://example.github.io/my-journal" + path))
    }
    @MainActor func testLegacyDraftAndImageFilesAndOfflinePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ArticleImageFiles(root: root)
        let prepared = try PublicJPEG.prepare(data: fixture(width: 100, height: 50, orientation: 1))
        var draft = Draft(kind: .diary)
        let legacy = try JSONEncoder().encode([draft])
        XCTAssertTrue(try JSONDecoder().decode([Draft].self, from: legacy)[0].attachedImages.isEmpty)
        let image = try files.save(prepared, articleID: draft.id)
        draft.images = [image]; draft.body = image.markdown
        XCTAssertEqual(try files.read(image), prepared.data)
        let html = BlogPreviewHTML.document(draft, imageFiles: files)
        XCTAssertTrue(html.contains("data:image/jpeg;base64,")); XCTAssertTrue(html.contains("alt=\"写真\""))
        XCTAssertFalse(html.contains("src=\"https://example.github.io/my-journal/images"))
        try Data("corrupt".utf8).write(to: files.url(for: image))
        XCTAssertThrowsError(try files.read(image))
        XCTAssertTrue(ArticleImage.valid(image.repositoryPath))
        XCTAssertFalse(ArticleImage.valid("public/images/diary/../test.jpg"))
    }
    @MainActor func testCleanupPreservesDraftTrashAndPendingImagesAndSharedCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(url: root.appendingPathComponent("drafts.json"))
        let prepared = try PublicJPEG.prepare(data: fixture(width: 100, height: 50, orientation: 1))
        var draft = Draft(kind: .diary)
        let image = try store.imageFiles.save(prepared, articleID: draft.id)
        draft.images = [image]; draft.body = image.markdown
        XCTAssertTrue(store.update(draft)); XCTAssertEqual(try store.clearPublishedImageCopies(), 0)
        draft.remoteSHA = "article"; draft.imageCommitSHA = String(repeating: "a", count: 40); draft.uploadedImagePaths = [image.repositoryPath]
        draft.publishedMarkdown = draft.markdown
        draft.pendingMarkdown = draft.markdown
        XCTAssertTrue(store.update(draft)); XCTAssertEqual(try store.clearPublishedImageCopies(), 0)
        draft.pendingMarkdown = nil
        XCTAssertTrue(store.update(draft))
        let copy = try XCTUnwrap(store.duplicate(draft.id))
        XCTAssertEqual(try store.clearPublishedImageCopies(), 0)
        XCTAssertTrue(store.moveToTrash([copy.id])); XCTAssertEqual(try store.clearPublishedImageCopies(), 0)
        XCTAssertTrue(store.deletePermanently(copy.id)); XCTAssertEqual(try store.imageFiles.read(image), prepared.data)
        var edited = draft; edited.body += "\n編集中の本文"
        XCTAssertTrue(store.update(edited)); XCTAssertEqual(try store.clearPublishedImageCopies(), 0)
        XCTAssertTrue(store.update(draft))
        XCTAssertEqual(try store.clearPublishedImageCopies(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.imageFiles.url(for: image).path))
        XCTAssertEqual(store.drafts.first?.body, image.markdown)
    }
    func testArticleBundleContainsMarkdownAndProcessedJPEGAtRepositoryPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ArticleImageFiles(root: root)
        var draft = Draft(kind: .diary)
        let image = try files.save(PublicJPEG.prepare(data: fixture(width: 100, height: 50, orientation: 1)), articleID: draft.id)
        draft.images = [image]; draft.body = image.markdown
        let bundle = try ArticleBundle(draft: draft, imageFiles: files)
        XCTAssertEqual(bundle.markdown, draft.markdown)
        XCTAssertEqual(bundle.articlePath, draft.path)
        XCTAssertEqual(bundle.imageData.keys.sorted(), [image.repositoryPath])
        try PublicJPEG.validate(try XCTUnwrap(bundle.imageData[image.repositoryPath]))
    }
}

final class ImagePublishingTests: XCTestCase {
    private func draftAndPublisher(_ key: String, configuration: SiteConfiguration = .fixture, profile: BlogProfile = .current) throws -> (Draft, ArticleImageFiles, GitHubPublisher) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = ArticleImageFiles(root: root)
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let output = NSMutableData(), dest = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        var draft = Draft(kind: .diary); draft.blogProfile = profile; draft.title = "写真日記"; draft.description = "説明"
        let image = try files.save(PublicJPEG.prepare(data: output as Data), articleID: draft.id, profile: profile, configuration: configuration)
        draft.images = [image]; draft.body = image.markdown; draft.pendingMarkdown = draft.markdown
        ImageGitFixture.reset(key, draft: draft, image: try files.read(image), configuration: configuration)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageGitFixture.self]
        return (draft, files, GitHubPublisher(configuration: configuration, session: URLSession(configuration: config), profile: profile))
    }
    func testCustomLayoutPublishesTOMLArticleAndPhotosTogether() async throws {
        var profile = BlogProfile.standard
        profile.articleDirectory = "docs/content/posts"; profile.imageDirectory = "static/photos/posts"
        profile.imagePublicPath = "/media/photos"; profile.frontMatter.format = .toml; profile.imageReferenceStyle = .absolute
        let (draft, files, publisher) = try draftAndPublisher("custom-layout", profile: profile)
        defer { try? FileManager.default.removeItem(at: files.root) }
        XCTAssertTrue(draft.path.hasPrefix("docs/content/posts/"))
        XCTAssertTrue(draft.markdown.hasPrefix("+++\n"))
        XCTAssertTrue(draft.images!.first!.repositoryPath.hasPrefix("static/photos/posts/"))
        XCTAssertTrue(draft.images!.first!.publicPath.hasPrefix("https://")); XCTAssertTrue(draft.images!.first!.publicPath.contains("/media/photos/"))
        let result = try await publisher.publish(draft, token: "custom-layout", imageFiles: files)
        XCTAssertNotNil(result.commitSHA)
        XCTAssertEqual(ImageGitFixture.writes("custom-layout").filter { $0.httpMethod == "PATCH" }.count, 1)
    }
    func testConfiguredRepositoryAndSlashBranchForAtomicPhotoCommit() async throws {
        var site = SiteConfiguration.fixture
        site.owner = "another-user"; site.repository = "photo-blog"; site.branch = "publish/blog"
        let (draft, files, publisher) = try draftAndPublisher("custom-branch", configuration: site)
        defer { try? FileManager.default.removeItem(at: files.root) }
        let result = try await publisher.publish(draft, token: "custom-branch", imageFiles: files)
        XCTAssertNotNil(result.commitSHA)
        let requests = ImageGitFixture.writes("custom-branch")
        XCTAssertTrue(requests.allSatisfy { $0.url!.path.hasPrefix("/repos/another-user/photo-blog/") })
        XCTAssertEqual(requests.last?.url?.path, "/repos/another-user/photo-blog/git/refs/heads/publish/blog")
        XCTAssertTrue(requests.last!.url!.absoluteString.hasSuffix("publish%2Fblog"))
    }
    func testOneCommitPublishesArticleAndImagesAndRetryDoesNotWriteAgain() async throws {
        let (draft, files, publisher) = try draftAndPublisher("success")
        defer { try? FileManager.default.removeItem(at: files.root) }
        let result = try await publisher.publish(draft, token: "success", imageFiles: files)
        XCTAssertEqual(result.sha, PublicJPEG.blobSHA(Data(draft.markdown.utf8)))
        XCTAssertNotNil(result.commitSHA)
        let writes = ImageGitFixture.writes("success")
        XCTAssertEqual(writes.filter { $0.httpMethod == "PATCH" }.count, 1)
        XCTAssertFalse(writes.contains { $0.url!.path.contains("/contents/") })
        _ = try await publisher.publish(draft, token: "success", imageFiles: files)
        XCTAssertEqual(ImageGitFixture.writes("success").count, writes.count)
    }
    func testLostReferenceResponseReconcilesArticleAndImages() async throws {
        let (draft, files, publisher) = try draftAndPublisher("lost-response")
        defer { try? FileManager.default.removeItem(at: files.root) }
        _ = try await publisher.publish(draft, token: "lost-response", imageFiles: files)
        XCTAssertEqual(ImageGitFixture.writes("lost-response").filter { $0.httpMethod == "PATCH" }.count, 1)
    }
    func testBranchChangeAndUploadFailureNeverUpdateMain() async throws {
        for key in ["branch-changed", "upload-failed"] {
            let (draft, files, publisher) = try draftAndPublisher(key)
            defer { try? FileManager.default.removeItem(at: files.root) }
            do { _ = try await publisher.publish(draft, token: key, imageFiles: files); XCTFail("Must preserve pending snapshot") } catch { }
            XCTAssertTrue(ImageGitFixture.writes(key).allSatisfy { $0.httpMethod != "PATCH" })
            XCTAssertNotNil(draft.pendingMarkdown)
        }
    }
    func testCorruptImageRejectedBeforeNetworkAndMissingImageBeforeWrites() async throws {
        let (draft, files, publisher) = try draftAndPublisher("corrupt")
        defer { try? FileManager.default.removeItem(at: files.root) }
        let file = try files.url(for: XCTUnwrap(draft.images?.first))
        try Data("private original renamed.jpg".utf8).write(to: file)
        do { _ = try await publisher.publish(draft, token: "corrupt", imageFiles: files); XCTFail("Must reject corrupt copy") } catch { }
        XCTAssertTrue(ImageGitFixture.writes("corrupt").isEmpty)
        try FileManager.default.removeItem(at: file)
        do { _ = try await publisher.publish(draft, token: "corrupt", imageFiles: files); XCTFail("Must reject missing image") } catch { }
        XCTAssertTrue(ImageGitFixture.writes("corrupt").isEmpty)
    }
    func testClearedPublishedCopyCanBeRestoredFromConfirmedCommit() async throws {
        var (draft, files, publisher) = try draftAndPublisher("restore")
        defer { try? FileManager.default.removeItem(at: files.root) }
        let result = try await publisher.publish(draft, token: "restore", imageFiles: files)
        draft.imageCommitSHA = result.commitSHA; draft.uploadedImagePaths = draft.referencedImages.map(\.repositoryPath)
        let image = try XCTUnwrap(draft.images?.first)
        try FileManager.default.removeItem(at: files.url(for: image))
        try await publisher.restoreImageCopies(draft, imageFiles: files, token: "restore")
        try PublicJPEG.validate(files.read(image))
    }
}

private final class ImageGitFixture: URLProtocol {
    struct State {
        let draft: Draft
        let image: Data
        var published = false
        var committed = false
        var requests: [URLRequest] = []
    }
    private static let lock = NSLock()
    private static var states: [String: State] = [:]
    private static let base = String(repeating: "a", count: 40), commit = String(repeating: "b", count: 40)
    static var configurations: [String: SiteConfiguration] = [:]
    static func reset(_ key: String, draft: Draft, image: Data, configuration: SiteConfiguration) { lock.lock(); defer { lock.unlock() }; states[key] = State(draft: draft, image: image); configurations[key] = configuration }
    static func writes(_ key: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return states[key]!.requests.filter { $0.httpMethod != "GET" }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func body() -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization")!.replacingOccurrences(of: "Bearer ", with: "")
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = Self.states[key]!; state.requests.append(request)
        let url = request.url!, method = request.httpMethod!, body = body()
        let configuration = Self.configurations[key]!
        XCTAssertTrue(url.path.hasPrefix("/repos/" + configuration.repositorySlug + "/"))
        var status = 200, response: [String: Any] = [:], timeout = false
        if url.path.hasSuffix("/git/ref/heads/" + configuration.branch) {
            response = ["object": ["sha": key == "branch-changed" && state.committed ? String(repeating: "c", count: 40) : state.published ? Self.commit : Self.base]]
        } else if url.path.contains("/contents/") {
            let ref = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            XCTAssertTrue([Self.base, Self.commit, String(repeating: "c", count: 40)].contains(ref))
            if !state.published { status = 404 }
            else {
                let bytes = url.path.hasSuffix(".jpg") ? state.image : Data(state.draft.markdown.utf8)
                response = ["sha": PublicJPEG.blobSHA(bytes), "encoding": "base64", "content": bytes.base64EncodedString()]
            }
        } else if method == "GET", url.path.contains("/git/commits/") {
            response = ["tree": ["sha": "base-tree"]]
        } else if url.path.hasSuffix("/git/blobs") {
            let bytes = Data(base64Encoded: body["content"] as! String)!
            XCTAssertTrue(bytes == state.image || bytes == Data(state.draft.markdown.utf8))
            response = ["sha": PublicJPEG.blobSHA(bytes)]; timeout = key == "upload-failed"
        } else if url.path.hasSuffix("/git/trees") {
            XCTAssertEqual(body["base_tree"] as? String, "base-tree")
            let tree = body["tree"] as! [[String: String]]
            XCTAssertEqual(Set(tree.map { $0["path"]! }), Set([state.draft.path, state.draft.images!.first!.repositoryPath]))
            response = ["sha": "new-tree"]
        } else if url.path.hasSuffix("/git/commits") {
            XCTAssertEqual(body["parents"] as? [String], [Self.base]); state.committed = true
            response = ["sha": Self.commit, "html_url": "https://github.com/image-commit"]
        } else if url.path.hasSuffix("/git/refs/heads/" + configuration.branch) {
            XCTAssertEqual(method, "PATCH"); XCTAssertEqual(body["force"] as? Bool, false)
            state.published = true; timeout = key == "lost-response"
            response = ["object": ["sha": Self.commit]]
        } else { XCTFail("Unexpected request: \(url.path)") }
        Self.states[key] = state
        if timeout { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let data = try! JSONSerialization.data(withJSONObject: response)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
