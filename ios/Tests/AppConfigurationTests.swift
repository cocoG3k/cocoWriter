import XCTest
@testable import cocoWriter

final class AppConfigurationTests: XCTestCase {
    private func legacyConfiguration() -> AppConfiguration {
        var app = AppConfiguration.standard
        app.storageDirectory = "LegacyWriter"
        app.keychainService = "LegacyWriter.GitHub"
        app.appGroupIdentifier = "group.org.example.LegacyWriter"
        app.defaultSite = .init(owner: "example", repository: "journal", branch: "main", website: "https://example.github.io/journal/", title: "Journal", tagline: "")
        app.legacyDestinationID = "example/journal@main"
        return app
    }
    func testInvalidStorageAndAmbiguousLegacyDestinationAreRejected() throws {
        for path in ["../old", "/old", "old/new", ".", "..", ""] {
            var app = legacyConfiguration(); app.storageDirectory = path
            XCTAssertThrowsError(try AppConfiguration.decode(JSONEncoder().encode(app)))
        }
        var app = legacyConfiguration(); app.legacyDestinationID = "another/repository@main"
        XCTAssertThrowsError(try AppConfiguration.decode(JSONEncoder().encode(app)))
    }
    func testOldStorageAndCredentialsAreConfiguredWithoutMovingFiles() throws {
        let app = try AppConfiguration.decode(JSONEncoder().encode(legacyConfiguration()))
        let root = URL(fileURLWithPath: "/fixture/Application Support")
        XCTAssertEqual(app.storageURL("drafts.json", applicationSupport: root).path, "/fixture/Application Support/LegacyWriter/drafts.json")
        XCTAssertEqual(app.storageURL("images", applicationSupport: root).path, "/fixture/Application Support/LegacyWriter/images")
        XCTAssertEqual(app.keychainService, "LegacyWriter.GitHub")
        XCTAssertEqual(SiteConfiguration.configuredDefault(app).destinationID, app.legacyDestinationID)
    }
    @MainActor func testLegacyArticlesKeepSnapshotsPathsAndDestinationWithoutRewritingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let app = legacyConfiguration()
        var draft = Draft(kind: .diary); draft.title = "Old draft"; draft.description = "Keep this"; draft.body = "Unfinished text"; draft.pinnedAt = Date()
        var pending = draft; pending.id = UUID(); pending.pendingMarkdown = "exact pending snapshot"; pending.pendingDeletionSHA = "deletion-sha"; pending.remoteSHA = "original-sha"; pending.repositoryPath = "src/content/diary/original.md"
        let hash = String(repeating: "a", count: 64)
        pending.images = [ArticleImage(hash: hash, repositoryPath: "public/images/diary/" + pending.id.uuidString.lowercased() + "/" + hash + ".jpg", width: 1, height: 1, byteCount: 100)]
        pending.imageCommitSHA = "image-recovery-sha"; pending.deletedAt = Date()
        var objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode([draft, pending])) as! [[String: Any]]
        for index in objects.indices { objects[index].removeValue(forKey: "blogProfile"); objects[index].removeValue(forKey: "remoteDestination") }
        let bytes = try JSONSerialization.data(withJSONObject: objects, options: .sortedKeys)
        try bytes.write(to: file)
        let store = DraftStore(url: file, preferences: preferences, configuration: app)
        XCTAssertTrue(store.loaded); XCTAssertNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: file), bytes, "Opening the upgrade must not rewrite legacy data")
        XCTAssertEqual(store.drafts.first?.body, draft.body); XCTAssertEqual(store.drafts.first?.pinnedAt, draft.pinnedAt)
        XCTAssertNil(store.drafts.first?.remoteDestination)
        let restored = try XCTUnwrap(store.drafts.last)
        XCTAssertEqual(restored.profile, .standard)
        XCTAssertEqual(restored.path, pending.path); XCTAssertEqual(restored.pendingMarkdown, pending.pendingMarkdown)
        XCTAssertEqual(restored.pendingDeletionSHA, pending.pendingDeletionSHA); XCTAssertEqual(restored.remoteSHA, pending.remoteSHA)
        XCTAssertEqual(restored.images, pending.images); XCTAssertEqual(restored.imageCommitSHA, pending.imageCommitSHA)
        XCTAssertEqual(restored.deletedAt, pending.deletedAt)
        XCTAssertEqual(restored.remoteDestination, app.legacyDestinationID)
        XCTAssertTrue(store.hasConnectedArticles)
        var another = store.site; another.repository = "another"
        XCTAssertThrowsError(try store.saveSiteConfiguration(another))
        XCTAssertTrue(store.persist())
        let reopened = DraftStore(url: file, preferences: preferences, configuration: app)
        XCTAssertEqual(reopened.drafts, store.drafts)
    }
    func testStoredConnectionOverridesBuildDefaults() throws {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        var site = SiteConfiguration.configuredDefault(legacyConfiguration()); site.title = "My saved title"
        preferences.set(try JSONEncoder().encode(site), forKey: SiteConfiguration.defaultsKey)
        XCTAssertEqual(SiteConfiguration.load(from: preferences, fallback: .fixture), site)
    }
    @MainActor func testConfiguredArticlesAreNotReboundAsLegacyData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts.json")
        var article = Draft(kind: .diary); article.title = "Configured article"; article.remoteSHA = "sha"
        try JSONEncoder().encode([article]).write(to: file)
        let store = DraftStore(url: file, preferences: UserDefaults(suiteName: UUID().uuidString)!, configuration: legacyConfiguration())
        XCTAssertEqual(store.drafts.first, article, "Only legacy records without a build profile can receive the legacy destination")
    }
    func testBothApplicationAndShareGroupHaveTheConfiguredIdentity() {
        XCTAssertNil(AppConfiguration.configurationError)
        XCTAssertEqual(MusicShareInbox.groupID, AppConfiguration.current.appGroupIdentifier)
    }
}
