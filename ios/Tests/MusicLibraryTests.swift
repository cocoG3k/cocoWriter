import XCTest
@testable import cocoWriter

final class MusicLibraryTests: XCTestCase {
    func testSharedURLAndTextNormalization() {
        XCTAssertEqual(SharedMusicLink.extract("好きな曲\nhttps://music.youtube.com/watch?v=abcdefghijk&si=tracking")?.absoluteString, "https://music.youtube.com/watch?v=abcdefghijk")
        XCTAssertNotNil(SharedMusicLink.extract("https://music.youtube.com/playlist?list=OLAK5uy_example"))
        XCTAssertNil(SharedMusicLink.extract("https://music.youtube.com.evil.example/watch?v=abcdefghijk"))
        XCTAssertNil(SharedMusicLink.extract("https://user@music.youtube.com/watch?v=abcdefghijk"))
        XCTAssertNil(SharedMusicLink.extract("普通のテキスト"))
    }
    @MainActor func testMigrationPersistsOnceAndCopiesRemainIndependent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("music.json")
        var original = MusicItem(); original.title = "曲"; original.comment = "ストックの紹介文"
        original.spotifyURL = "https://open.spotify.com/track/0123456789ABCDEFGHIJKL"; original.confirmed = true
        var oldDraft = Draft(kind: .music); oldDraft.music = [original]
        let library = MusicLibraryStore(url: url)
        var trashed = oldDraft; trashed.music[0].id = UUID(); trashed.deletedAt = Date()
        XCTAssertTrue(library.migrate(from: [oldDraft, oldDraft, trashed]))
        XCTAssertEqual(library.items, [original])
        var article = MusicLibraryStore.articleCopies(library.items)
        XCTAssertNotEqual(article[0].id, original.id); XCTAssertEqual(article[0].sourceID, original.id)
        XCTAssertTrue(article[0].confirmed)
        article[0].comment = "記事だけの紹介文"
        XCTAssertEqual(library.items[0].comment, "ストックの紹介文")
        XCTAssertTrue(library.remove(original.id)); XCTAssertEqual(article[0].title, "曲")
        let reloaded = MusicLibraryStore(url: url)
        XCTAssertTrue(reloaded.migrate(from: [oldDraft])); XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertEqual(oldDraft.music, [original])
    }
    @MainActor func testShareImportCreatesDurableArticleAndAcknowledgesExactlyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = folder.appendingPathComponent("inbox")
        var item = MusicItem(); item.youtubeURL = "https://music.youtube.com/watch?v=abcdefghijk"; item.comment = "聴いた感想"
        let request = SharedMusicRequest(item: item, createArticle: true, articleTitle: "今日の音楽", introduction: "はじめに")
        try MusicShareInbox.save(request, to: inbox)
        let library = MusicLibraryStore(url: folder.appendingPathComponent("music.json"))
        let drafts = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        let created = library.importShares(from: inbox, drafts: drafts)
        XCTAssertEqual(created.count, 1); XCTAssertEqual(created[0].title, "今日の音楽")
        XCTAssertEqual(created[0].body, "はじめに"); XCTAssertEqual(created[0].music[0].comment, "聴いた感想")
        XCTAssertEqual(created[0].music[0].sourceID, request.id)
        XCTAssertEqual(DraftStore(url: folder.appendingPathComponent("drafts.json")).drafts.count, 1)
        XCTAssertEqual(MusicLibraryStore(url: folder.appendingPathComponent("music.json")).items.count, 1)
        // Simulate a crash before acknowledging the share, then retry.
        try MusicShareInbox.save(request, to: inbox)
        XCTAssertTrue(library.importShares(from: inbox, drafts: drafts).isEmpty)
        XCTAssertEqual(drafts.drafts.count, 1); XCTAssertEqual(library.items.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        let stockOnly = SharedMusicRequest(item: item)
        try MusicShareInbox.save(stockOnly, to: inbox)
        XCTAssertTrue(library.importShares(from: inbox, drafts: drafts).isEmpty)
        XCTAssertEqual(library.items.count, 2); XCTAssertEqual(drafts.drafts.count, 1)
    }
    @MainActor func testFailedImportRetainsInboxAndProtectsCorruptLibrary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("blocker")
        try Data("protected".utf8).write(to: blocker)
        var item = MusicItem(); item.youtubeURL = "https://music.youtube.com/watch?v=abcdefghijk"
        let inbox = folder.appendingPathComponent("inbox")
        let request = SharedMusicRequest(item: item, createArticle: true)
        try MusicShareInbox.save(request, to: inbox)
        let library = MusicLibraryStore(url: folder.appendingPathComponent("music.json"))
        let drafts = DraftStore(url: blocker.appendingPathComponent("drafts.json"))
        XCTAssertTrue(library.importShares(from: inbox, drafts: drafts).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path).count, 1)
        XCTAssertNotNil(drafts.storageError)
        let corrupt = MusicLibraryStore(url: blocker)
        XCTAssertFalse(corrupt.loaded); XCTAssertFalse(corrupt.update(item))
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "protected")
    }
    @MainActor func testConfirmedPublicationHidesStockAndRemoteDeletionRestoresOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let musicURL = folder.appendingPathComponent("music.json")
        let draftURL = folder.appendingPathComponent("drafts.json")
        let library = MusicLibraryStore(url: musicURL)
        let drafts = DraftStore(url: draftURL)
        var stock = MusicItem(); stock.title = "掲載する曲"; stock.comment = "元の紹介文"
        XCTAssertTrue(library.update(stock))
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([stock])
        article.music[0].comment = "記事だけの紹介文"
        article.pendingMarkdown = article.markdown
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertEqual(library.items, [stock]) // No confirmed publication yet.
        article.remoteSHA = "published"; article.pendingMarkdown = nil
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertFalse(library.remove(stock.id)) // Protect the hidden recovery copy.
        let reloaded = MusicLibraryStore(url: musicURL)
        let reloadedDrafts = DraftStore(url: draftURL)
        XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertNotNil(reloadedDrafts.beginRemoteDeletion(article.id))
        XCTAssertTrue(reloaded.reconcile(from: reloadedDrafts)); XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertTrue(reloadedDrafts.cancelRemoteDeletion(article.id))
        XCTAssertTrue(reloaded.reconcile(from: reloadedDrafts)); XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertNotNil(reloadedDrafts.beginRemoteDeletion(article.id))
        XCTAssertTrue(reloadedDrafts.finishRemoteDeletion(article.id, expectedSHA: "published", commitURL: nil))
        XCTAssertTrue(reloaded.reconcile(from: reloadedDrafts))
        XCTAssertEqual(reloaded.items, [stock])
        XCTAssertTrue(reloaded.reconcile(from: reloadedDrafts))
        XCTAssertEqual(MusicLibraryStore(url: musicURL).items, [stock])
    }
    @MainActor func testPendingUpdateKeepsPublishedSelectionUntilNewRevisionIsConfirmed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MusicLibraryStore(url: folder.appendingPathComponent("music.json"))
        let drafts = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        var first = MusicItem(); first.title = "最初の曲"
        var second = MusicItem(); second.title = "次の曲"
        XCTAssertTrue(library.update(first)); XCTAssertTrue(library.update(second))
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([first]); article.remoteSHA = "v1"
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertEqual(library.items, [second])
        article.music = MusicLibraryStore.articleCopies([second])
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertEqual(library.items, [second]) // Editing does not change published songs.
        article.pendingMarkdown = article.markdown
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertEqual(library.items, [second])
        article.remoteSHA = "v2"; article.pendingMarkdown = nil
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertEqual(library.items, [first])
    }
    @MainActor func testSharedSongReturnsOnlyAfterAllPublishedArticlesBecomeDrafts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MusicLibraryStore(url: folder.appendingPathComponent("music.json"))
        let drafts = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        var stock = MusicItem(); stock.title = "複数の記事に掲載"
        XCTAssertTrue(library.update(stock))
        var first = Draft(kind: .music); first.music = MusicLibraryStore.articleCopies([stock]); first.remoteSHA = "first"
        var second = Draft(kind: .music); second.music = MusicLibraryStore.articleCopies([stock]); second.remoteSHA = "second"
        XCTAssertTrue(drafts.update(first)); XCTAssertTrue(drafts.update(second))
        XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        XCTAssertNotNil(drafts.duplicate(first.id))
        XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        first.remoteSHA = nil
        XCTAssertTrue(drafts.update(first)); XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        second.remoteSHA = nil
        XCTAssertTrue(drafts.update(second)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertEqual(library.items, [stock])
    }
    @MainActor func testRemoteRefreshPreservesAssociationAcrossReturnAndRepublication() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MusicLibraryStore(url: folder.appendingPathComponent("music.json"))
        let drafts = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        var stock = MusicItem(); stock.title = "元の曲"
        XCTAssertTrue(library.update(stock))
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([stock]); article.remoteSHA = "v1"
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        var remote = article; remote.music = []; remote.remoteSHA = "v2"
        remote.repositorySource = RepositorySource(markdown: "---\ntitle: 遠隔の記事\n---\n本文", title: "遠隔の記事", description: "説明", date: Date(), tags: "曲紹介")
        XCTAssertNotNil(drafts.keepEditsAndLoadLatest(remote))
        XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        XCTAssertTrue(drafts.mergePublishedArticles([]))
        XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertEqual(library.items, [stock])
        var returned = try XCTUnwrap(drafts.drafts.first { $0.id == article.id }); returned.remoteSHA = "v3"
        XCTAssertTrue(drafts.update(returned)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertTrue(library.items.isEmpty)
    }
    @MainActor func testLegacyStockMigrationAndDirectArticleSongsCanBeRestored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let musicURL = folder.appendingPathComponent("music.json")
        var stock = MusicItem(); stock.title = "旧ストック"
        let legacy: [String: Any] = ["items": try JSONSerialization.jsonObject(with: JSONEncoder().encode([stock])), "migrated": true]
        try JSONSerialization.data(withJSONObject: legacy).write(to: musicURL)
        let library = MusicLibraryStore(url: musicURL)
        let drafts = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        XCTAssertTrue(library.loaded); XCTAssertEqual(library.items, [stock])
        var direct = MusicItem(); direct.title = "記事で直接追加した曲"
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([stock]) + [direct]; article.remoteSHA = "published"
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        article.remoteSHA = nil
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertEqual(library.items, [stock, direct])
    }
    @MainActor func testMigrationUsesOriginalStockIDInsteadOfCreatingArticleDuplicates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MusicLibraryStore(url: folder.appendingPathComponent("music.json"))
        var stock = MusicItem(); stock.title = "元の曲"
        XCTAssertTrue(library.update(stock))
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([stock])
        XCTAssertTrue(library.migrate(from: [article])); XCTAssertEqual(library.items, [stock])
    }
    @MainActor func testReconciliationRecoversAfterCrashBetweenSavingArticleAndStock() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let musicURL = folder.appendingPathComponent("music.json"), draftURL = folder.appendingPathComponent("drafts.json")
        let library = MusicLibraryStore(url: musicURL), drafts = DraftStore(url: draftURL)
        let stock = MusicItem(); XCTAssertTrue(library.update(stock))
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([stock]); article.remoteSHA = "published"
        XCTAssertTrue(drafts.update(article)) // Crash before stock reconciliation.
        let reloaded = MusicLibraryStore(url: musicURL)
        XCTAssertTrue(reloaded.reconcile(from: DraftStore(url: draftURL))); XCTAssertTrue(reloaded.items.isEmpty)
        article.remoteSHA = nil; XCTAssertTrue(drafts.update(article)) // Crash before restoring stock.
        let restored = MusicLibraryStore(url: musicURL)
        XCTAssertTrue(restored.reconcile(from: DraftStore(url: draftURL))); XCTAssertEqual(restored.items, [stock])
    }
    @MainActor func testFailedStockWriteAndFailedDraftSaveDoNotLoseSongs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let musicURL = folder.appendingPathComponent("music.json"), draftURL = folder.appendingPathComponent("drafts.json")
        let library = MusicLibraryStore(url: musicURL), drafts = DraftStore(url: draftURL)
        let stock = MusicItem(); XCTAssertTrue(library.update(stock))
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([stock]); article.remoteSHA = "published"
        XCTAssertTrue(drafts.update(article))
        try FileManager.default.moveItem(at: musicURL, to: folder.appendingPathComponent("backup.json"))
        try FileManager.default.createDirectory(at: musicURL, withIntermediateDirectories: false)
        XCTAssertFalse(library.reconcile(from: drafts)); XCTAssertEqual(library.items, [stock]); XCTAssertNotNil(library.storageError)
        try FileManager.default.removeItem(at: musicURL)
        XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        try FileManager.default.removeItem(at: draftURL)
        try FileManager.default.createDirectory(at: draftURL, withIntermediateDirectories: false)
        article.remoteSHA = nil
        XCTAssertFalse(drafts.update(article)); XCTAssertFalse(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        try FileManager.default.removeItem(at: draftURL)
        XCTAssertTrue(drafts.persist()); XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertEqual(library.items, [stock])
    }
    @MainActor func testLocallyTrashingPublishedArticleDoesNotFreeItsSongs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MusicLibraryStore(url: folder.appendingPathComponent("music.json"))
        let drafts = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        let stock = MusicItem(); XCTAssertTrue(library.update(stock))
        var article = Draft(kind: .music); article.music = MusicLibraryStore.articleCopies([stock]); article.remoteSHA = "published"
        XCTAssertTrue(drafts.update(article)); XCTAssertTrue(library.reconcile(from: drafts))
        XCTAssertTrue(drafts.moveToTrash([article.id])); XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
        XCTAssertTrue(drafts.deletePermanently(article.id)); XCTAssertTrue(library.reconcile(from: drafts)); XCTAssertTrue(library.items.isEmpty)
    }

}
