import XCTest
import Combine
@testable import cocoWriter

final class WriterTests: XCTestCase {
    let spotify = "https://open.spotify.com/track/0123456789ABCDEFGHIJKL?si=ignored"
    @MainActor func testRemoteDeletionPublishesOnlyTheCompleteShelfChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drafts.json")
        let store = DraftStore(url: url)
        var article = Draft(kind: .diary)
        article.title = "削除結果を確認する記事"; article.body = "端末に残す本文"
        article.remoteSHA = "published-sha"; article.remoteChanged = true
        XCTAssertTrue(store.update(article))
        XCTAssertNotNil(store.beginRemoteDeletion(article.id))
        var snapshots: [[Draft]] = []
        let subscription = store.$drafts.dropFirst().sink { snapshots.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(store.finishRemoteDeletion(article.id, expectedSHA: "published-sha", commitURL: "https://example.com/commit"))
        XCTAssertEqual(snapshots.count, 1, "A list must receive a single complete deletion result")
        let result = try XCTUnwrap(snapshots.first?.first)
        XCTAssertNil(result.remoteSHA); XCTAssertNil(result.pendingDeletionSHA); XCTAssertNil(result.remoteChanged)
        XCTAssertEqual(result.body, article.body); XCTAssertEqual(result.commitURL, "https://example.com/commit")
        XCTAssertEqual(ArticleLibrary.items(snapshots[0], shelf: .drafts).map(\.id), [article.id])
        XCTAssertTrue(ArticleLibrary.items(snapshots[0], shelf: .published).isEmpty)
        XCTAssertEqual(DraftStore(url: url).drafts, snapshots[0])
    }
    func testLegacyDraftMigrationAndLibraryFilters() throws {
        var diary = Draft(kind: .diary); diary.title = "日記"; diary.updatedAt = Date(timeIntervalSince1970: 100)
        var music = Draft(kind: .music); music.title = "曲紹介"; music.updatedAt = Date(timeIntervalSince1970: 200)
        var published = Draft(kind: .diary); published.remoteSHA = "saved-sha"
        var pending = published; pending.id = UUID(); pending.pendingMarkdown = "protected snapshot"
        var removed = diary; removed.id = UUID(); removed.deletedAt = Date()
        let all = [diary, music, published, pending, removed]
        XCTAssertEqual(Set(ArticleLibrary.items(all, shelf: .drafts).map(\.id)), [diary.id, music.id, pending.id])
        XCTAssertEqual(ArticleLibrary.items(all, shelf: .published).map(\.id), [published.id])
        XCTAssertEqual(ArticleLibrary.items(all, shelf: .drafts, filter: .music).map(\.id), [music.id])
        XCTAssertEqual(Set(ArticleLibrary.items(all, shelf: .drafts, filter: .diary).map(\.id)), [diary.id, pending.id])
        diary.pinnedAt = Date(); XCTAssertEqual(ArticleLibrary.items([music, diary], shelf: .drafts).first?.id, diary.id)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diary)) as! [String: Any]
        old.removeValue(forKey: "pinnedAt"); old.removeValue(forKey: "deletedAt")
        let migrated = try JSONDecoder().decode(Draft.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(migrated.pinnedAt); XCTAssertNil(migrated.deletedAt); XCTAssertEqual(migrated.body, diary.body)
    }
    @MainActor func testArticleManagementPersistsAndDuplicateClearsPublication() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drafts.json"); let store = DraftStore(url: url)
        var published = Draft(kind: .music); published.title = "公開した曲"; published.remoteSHA = "saved"; published.commitURL = "https://github.com/example"
        var item = MusicItem(); item.title = "曲"; item.spotifyURL = spotify; item.confirmed = true; published.music = [item]
        XCTAssertTrue(store.update(published)); XCTAssertTrue(store.togglePin(published.id))
        let copy = try XCTUnwrap(store.duplicate(published.id))
        XCTAssertNotEqual(copy.id, published.id); XCTAssertNotEqual(copy.filename, published.filename)
        XCTAssertNil(copy.remoteSHA); XCTAssertNil(copy.commitURL); XCTAssertNil(copy.pendingMarkdown); XCTAssertNil(copy.pinnedAt)
        XCTAssertNotEqual(copy.music[0].id, item.id); XCTAssertEqual(copy.music[0].spotifyURL, item.spotifyURL)
        XCTAssertFalse(store.deletePermanently(copy.id))
        XCTAssertTrue(store.moveToTrash([copy.id, published.id]))
        XCTAssertTrue(DraftStore(url: url).drafts.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(store.restore(published.id)); XCTAssertTrue(store.drafts.first { $0.id == published.id }!.isPublished)
        XCTAssertTrue(store.deletePermanently(copy.id))
        XCTAssertEqual(DraftStore(url: url).drafts.map(\.id), [published.id])
    }
    @MainActor func testPendingDraftCannotBeDeletedAndFailedDeleteRollsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        var pending = Draft(kind: .diary); pending.pendingMarkdown = "protected"
        XCTAssertTrue(good.update(pending)); XCTAssertFalse(good.moveToTrash([pending.id])); XCTAssertNil(good.drafts.first?.deletedAt)
        let blocker = folder.appendingPathComponent("not-a-folder"); try Data("file".utf8).write(to: blocker)
        let failed = DraftStore(url: blocker.appendingPathComponent("drafts.json")); let draft = Draft(kind: .diary)
        XCTAssertFalse(failed.update(draft)); XCTAssertFalse(failed.moveToTrash([draft.id]))
        XCTAssertEqual(failed.drafts.first?.id, draft.id); XCTAssertNil(failed.drafts.first?.deletedAt)
        XCTAssertNotNil(failed.storageError)
    }
    @MainActor func testPrivateNotesStaySeparateAndRestoreAfterRestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let articleURL = folder.appendingPathComponent("drafts.json"), noteURL = folder.appendingPathComponent("private-notes.json")
        let articles = DraftStore(url: articleURL), notes = PrivateNoteStore(url: noteURL)
        var article = Draft(kind: .diary); article.title = "ブログ用"; XCTAssertTrue(articles.update(article))
        var note = PrivateNote(); note.kind = .journal; note.title = "自分の記録"; note.body = "**公開しないメモ**\n日本語🎵"
        XCTAssertTrue(notes.update(note)); XCTAssertTrue(notes.togglePin(note.id))
        let reopened = PrivateNoteStore(url: noteURL)
        XCTAssertEqual(reopened.active.first?.body, note.body); XCTAssertEqual(reopened.active.first?.kind, .journal); XCTAssertNotNil(reopened.active.first?.pinnedAt)
        XCTAssertEqual(DraftStore(url: articleURL).drafts.map(\.title), ["ブログ用"])
        let json = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertFalse(json.contains("remoteSHA")); XCTAssertFalse(json.contains("pendingMarkdown"))
        XCTAssertThrowsError(try JSONDecoder().decode([Draft].self, from: Data(contentsOf: noteURL)))
    }
    @MainActor func testPrivateNoteTrashAndUnreadableProtection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("private-notes.json"); let store = PrivateNoteStore(url: url)
        let first = PrivateNote(), second = PrivateNote(); XCTAssertTrue(store.update(first)); XCTAssertTrue(store.update(second))
        XCTAssertTrue(store.moveToTrash([first.id, second.id])); XCTAssertTrue(store.active.isEmpty)
        XCTAssertEqual(PrivateNoteStore(url: url).trash.count, 2)
        XCTAssertTrue(store.restore(first.id)); XCTAssertTrue(store.deletePermanently(second.id))
        XCTAssertEqual(PrivateNoteStore(url: url).active.map(\.id), [first.id])
        try Data("broken".utf8).write(to: url)
        let broken = PrivateNoteStore(url: url); XCTAssertFalse(broken.loaded); XCTAssertFalse(broken.update(first))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
    func testCasualNoteTagsHandleJapaneseEmojiAndIgnoreHeadingsAndURLFragments() {
        let text = "散歩でひと息 #気づき、#散歩 ＃音楽🎵 #家族👨‍👩‍👧 #Cafe #cafe\n# 見出し\n## 小見出し\nhttps://example.com/#fragment"
        XCTAssertEqual(NoteTags.extract(from: text), ["気づき", "散歩", "音楽🎵", "家族👨‍👩‍👧", "Cafe"])
        XCTAssertEqual(NoteTags.appending("気づき", to: text), text)
        XCTAssertEqual(NoteTags.appending("日常", to: "ひとこと"), "ひとこと #日常 ")
        XCTAssertEqual(NoteTags.extract(from: "#café #cafe\u{301}"), ["café"])
    }
    func testNoteDisplaySeparatesTagsWithoutChangingStoredBody() {
        var note = PrivateNote()
        note.body = "今日は #散歩 公園へ。\n#日常 #散歩\n\n音楽🎵 ＃好き\n## 見出し\nhttps://example.com/#fragment"
        let original = note.body
        XCTAssertEqual(note.displayBody, "今日は 公園へ。\n\n音楽🎵\n## 見出し\nhttps://example.com/#fragment")
        XCTAssertEqual(note.tags, ["散歩", "日常", "好き"])
        XCTAssertEqual(note.body, original)
        XCTAssertEqual(NoteTags.removing(from: "#家族👨‍👩‍👧 家でゆっくり #Cafe #cafe"), "家でゆっくり")
        XCTAssertEqual(NoteTags.removing(from: "#食べ物、また作りたい。"), "、また作りたい。")
        XCTAssertEqual(NoteTags.removing(from: "タグのない本文\n\n次の行"), "タグのない本文\n\n次の行")
    }
    func testTagOnlyNoteDisplayAndAdjacentPunctuationKeepTagsAvailable() {
        var note = PrivateNote(); note.body = "#好き ＃音楽🎵"
        XCTAssertTrue(note.displayBody.isEmpty)
        XCTAssertEqual(note.tags, ["好き", "音楽🎵"])
        XCTAssertEqual(NoteTags.removing(from: "今日（#散歩）に行った"), "今日（）に行った")
        XCTAssertEqual(NoteTags.removing(from: "https://example.com/#食べ物\n# 見出し"), "https://example.com/#食べ物\n# 見出し")
    }
    func testTagMarkerInsertionKeepsUnicodeAndStartsAUsableTag() {
        let empty = NoteTags.insertingMarker(in: "", at: NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.text, "#"); XCTAssertEqual(empty.selection, NSRange(location: 1, length: 0))
        let text = "散歩🎵の帰り"
        let edit = NoteTags.insertingMarker(in: text, at: NSRange(location: "散歩🎵".utf16.count, length: 0))
        XCTAssertEqual(edit.text, "散歩🎵 #の帰り")
        XCTAssertEqual(edit.selection.location, "散歩🎵 #".utf16.count)
        XCTAssertEqual(NoteTags.insertingMarker(in: "前 後", at: NSRange(location: 2, length: 1)).text, "前 #")
        XCTAssertEqual(NoteTags.appending("散歩", to: "ひとこと #"), "ひとこと #散歩 ")
        XCTAssertEqual(NoteTags.appending("散歩", to: "＃"), "＃散歩 ")
        XCTAssertEqual(NoteTags.extract(from: NoteTags.appending("散歩", to: empty.text)), ["散歩"])
        let stale = text.endIndex..<text.endIndex
        XCTAssertEqual(NoteTags.selectionRange(stale, in: ""), NSRange(location: 0, length: 0))
        let valid = text.index(after: text.startIndex)..<text.endIndex
        XCTAssertEqual(NoteTags.selectionRange(valid, in: text), NSRange(valid, in: text))
    }
    @MainActor func testTagCatalogReorderAndHidePersistWithoutChangingSavedNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json"), store = PrivateNoteStore(url: url)
        XCTAssertTrue(store.addEntry(body: "そのまま残す #音楽 #Cafe #気づき"))
        let original = try Data(contentsOf: url)
        let music = try XCTUnwrap(store.tags.firstIndex(of: "音楽"))
        XCTAssertTrue(store.moveTags(from: IndexSet(integer: music), to: 0))
        XCTAssertEqual(store.tags.first, "音楽")
        XCTAssertTrue(store.hideTag("cafe")); XCTAssertFalse(store.tags.contains("Cafe"))
        XCTAssertTrue(store.hideTag("気づき")); XCTAssertFalse(store.tags.contains("気づき"))
        XCTAssertEqual(try Data(contentsOf: url), original)
        let reopened = PrivateNoteStore(url: url)
        XCTAssertEqual(reopened.tags, store.tags)
        XCTAssertEqual(PrivateNoteTimeline.items(reopened.notes, tag: "cafe").count, 1)
        XCTAssertTrue(reopened.restoreTag("Cafe")); XCTAssertEqual(reopened.tags.last, "Cafe")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testRemovedTagsStayHiddenUntilExplicitlyAddedAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json"), store = PrivateNoteStore(url: url)
        XCTAssertTrue(store.addEntry(body: "最初 #Cafe")); XCTAssertTrue(store.hideTag("Cafe"))
        var old = try XCTUnwrap(store.notes.first); old.title = "タイトルだけ編集"
        XCTAssertTrue(store.update(old)); XCTAssertFalse(store.tags.contains("Cafe"))
        XCTAssertTrue(store.togglePin(old.id)); XCTAssertTrue(store.moveToTrash([old.id])); XCTAssertTrue(store.restore(old.id))
        XCTAssertFalse(store.tags.contains("Cafe"))
        XCTAssertTrue(store.addEntry(body: "新しいメモ #cafe"))
        XCTAssertEqual(store.tags.filter { NoteTags.key($0) == "cafe" }, ["cafe"])
        XCTAssertTrue(store.tagCatalog.hidden.isEmpty)
        XCTAssertTrue(store.hideTag("cafe"))
        old.body = "元メモからタグを外した"; XCTAssertTrue(store.update(old))
        old.body += " #Cafe"; XCTAssertTrue(store.update(old))
        XCTAssertTrue(store.tags.contains("Cafe"))
    }
    @MainActor func testEditingTagCharacterByCharacterDoesNotRetainIntermediateTags() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json"), store = PrivateNoteStore(url: url)
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertTrue(store.addEntry(body: "昼ごはん #食べ物"))
        var note = try XCTUnwrap(store.notes.first)
        for tag in ["食べ", "食", "", "料", "料理"] {
            note.body = "昼ごはん #" + tag
            XCTAssertTrue(store.update(note))
            let expected = tag.isEmpty ? [] : [tag]
            XCTAssertEqual(store.tags, expected)
            XCTAssertEqual(store.tagCatalog.order, expected)
            XCTAssertEqual(PrivateNoteStore(url: url).tags, expected)
        }
        note.body = "昼ごはん"
        XCTAssertTrue(store.update(note))
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertTrue(PrivateNoteStore(url: url).tagCatalog.order.isEmpty)
    }
    @MainActor func testTagRemainsUntilRemovedFromLastNoteWithNormalizedSpelling() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PrivateNoteStore(url: folder.appendingPathComponent("notes.json"))
        XCTAssertTrue(store.addEntry(body: "最初 #café"))
        var first = try XCTUnwrap(store.notes.first)
        XCTAssertTrue(store.addEntry(body: "次 #CAFE\u{301}"))
        var second = try XCTUnwrap(store.notes.first)
        first.body = "最初のタグを削除"
        XCTAssertTrue(store.update(first))
        XCTAssertEqual(store.tags.map(NoteTags.key), ["café"])
        second.body = "最後のタグを削除"
        XCTAssertTrue(store.update(second))
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertTrue(store.tagCatalog.order.isEmpty)
    }
    @MainActor func testLoadingPrunesLegacyUnusedTagsAndPreservesSettingsAndNoteData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notes.json"), tagURL = folder.appendingPathComponent("tags.json")
        var note = PrivateNote(); note.body = "既存メモ #食べ物 #音楽 #Cafe"
        let original = try JSONEncoder().encode([note])
        try original.write(to: url)
        var catalog = NoteTagCatalog()
        catalog.order = ["気づき", "音楽", "食べ物", "食べ", "食", "アイデア"]
        catalog.hidden = ["Cafe", "存在しない"]
        try JSONEncoder().encode(catalog).write(to: tagURL)
        let store = PrivateNoteStore(url: url, tagURL: tagURL)
        XCTAssertEqual(store.tags, ["音楽", "食べ物"])
        XCTAssertEqual(store.tagCatalog.order, ["音楽", "食べ物"])
        XCTAssertEqual(store.tagCatalog.hidden, ["Cafe"])
        XCTAssertEqual(try JSONDecoder().decode(NoteTagCatalog.self, from: Data(contentsOf: tagURL)), store.tagCatalog)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(store.restoreTag("Cafe"))
        XCTAssertEqual(store.tags, ["音楽", "食べ物", "Cafe"])
    }
    @MainActor func testTrashedNoteTagsDisappearAndRestoreWithSettingsUntilPermanentlyDeleted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json"), store = PrivateNoteStore(url: url)
        XCTAssertTrue(store.addEntry(body: "メモ #食べ物 #音楽 #Cafe"))
        let id = try XCTUnwrap(store.notes.first?.id)
        XCTAssertTrue(store.moveTags(from: IndexSet(integer: 1), to: 0))
        XCTAssertTrue(store.hideTag("Cafe"))
        XCTAssertTrue(store.moveToTrash([id]))
        XCTAssertTrue(store.tags.isEmpty)
        let reopened = PrivateNoteStore(url: url)
        XCTAssertTrue(reopened.restore(id))
        XCTAssertEqual(reopened.tags, ["音楽", "食べ物"])
        XCTAssertEqual(reopened.tagCatalog.hidden, ["Cafe"])
        XCTAssertTrue(reopened.moveToTrash([id]))
        XCTAssertTrue(reopened.deletePermanently(id))
        XCTAssertTrue(reopened.tagCatalog.order.isEmpty)
        XCTAssertTrue(reopened.tagCatalog.hidden.isEmpty)
        XCTAssertTrue(PrivateNoteStore(url: url).tags.isEmpty)
    }
    @MainActor func testTagSettingFailureDoesNotLoseNotesOrPretendDeletionSucceeded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("blocked"); try Data("file".utf8).write(to: blocker)
        let url = folder.appendingPathComponent("notes.json")
        let store = PrivateNoteStore(url: url, tagURL: blocker.appendingPathComponent("tags.json"))
        XCTAssertTrue(store.addEntry(body: "メモの保存を優先 #散歩"))
        XCTAssertNotNil(store.tagStorageError)
        XCTAssertFalse(store.hideTag("散歩")); XCTAssertTrue(store.tags.contains("散歩"))
        XCTAssertEqual(PrivateNoteStore(url: url).notes.first?.body, "メモの保存を優先 #散歩")
        let corrupt = folder.appendingPathComponent("corrupt.json"); try Data("broken".utf8).write(to: corrupt)
        let protected = PrivateNoteStore(url: url, tagURL: corrupt)
        XCTAssertFalse(protected.tagsLoaded); XCTAssertFalse(protected.hideTag("散歩"))
        XCTAssertTrue(protected.addEntry(body: "タグ設定が読めなくてもメモは残る #日常"))
        XCTAssertEqual(try String(contentsOf: corrupt, encoding: .utf8), "broken")
    }
    func testNoteTimelineUsesEntryDatesAndCombinesTagAndTextFilters() {
        var old = PrivateNote(); old.body = "朝の散歩 #気づき"; old.date = Date(timeIntervalSince1970: 100); old.updatedAt = Date.distantFuture
        var recent = PrivateNote(); recent.body = "音楽でひと息 #音楽 #気づき"; recent.kind = .journal; recent.date = Date(timeIntervalSince1970: 200)
        var pinned = PrivateNote(); pinned.body = "好きな喫茶店 #好き"; pinned.date = Date(timeIntervalSince1970: 50); pinned.pinnedAt = Date()
        var removed = recent; removed.id = UUID(); removed.body = "消したメモ #削除"; removed.deletedAt = Date()
        let notes = [old, removed, recent, pinned]
        XCTAssertEqual(PrivateNoteTimeline.items(notes).map(\.id), [pinned.id, recent.id, old.id])
        XCTAssertEqual(PrivateNoteTimeline.items(notes, kind: .journal, tag: "気づき", query: "ひと息").map(\.id), [recent.id])
        XCTAssertEqual(PrivateNoteTimeline.items(notes, tag: "音楽", query: "散歩").count, 0)
        XCTAssertEqual(Set(PrivateNoteTimeline.tags(in: notes)), ["好き", "音楽", "気づき"])
    }
    func testDailyTimelineUsesLocalDayAndReadsMorningToNightRegardlessOfPins() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        var before = PrivateNote(); before.date = day.addingTimeInterval(-1)
        var morning = PrivateNote(); morning.date = day.addingTimeInterval(9 * 3600); morning.body = "朝 #日常"
        var night = PrivateNote(); night.date = day.addingTimeInterval(23 * 3600); night.body = "夜 #日常"; night.pinnedAt = Date()
        var after = PrivateNote(); after.date = calendar.date(byAdding: .day, value: 1, to: day)!
        let notes = [after, night, before, morning]
        XCTAssertEqual(PrivateNoteTimeline.entries(notes, day: day, calendar: calendar).map(\.id), [morning.id, night.id])
        XCTAssertEqual(PrivateNoteTimeline.entries(notes, day: day, calendar: calendar, tag: "日常", query: "朝").map(\.id), [morning.id])
        XCTAssertEqual(PrivateNoteTimeline.entries(notes).map(\.id), [after.id, night.id, morning.id, before.id])
    }
    func testDiaryWeekCrossesMonths() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let sunday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let week = PrivateNoteTimeline.week(containing: sunday, calendar: calendar)
        XCTAssertEqual(week.count, 7); XCTAssertEqual(week.map { calendar.component(.day, from: $0) }, [28, 29, 30, 1, 2, 3, 4])
        XCTAssertEqual(calendar.component(.month, from: week[0]), 9)
    }
    @MainActor func testQuickNotesSaveWithoutTitleAndLegacyNotesStillLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json")
        var legacy = PrivateNote(); legacy.kind = .journal; legacy.title = "昔の日記"; legacy.body = "そのまま残す本文"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode([legacy]).write(to: url)
        let store = PrivateNoteStore(url: url)
        XCTAssertTrue(store.loaded); XCTAssertFalse(store.addEntry(body: " \n　"))
        let date = Date(timeIntervalSince1970: 500)
        XCTAssertTrue(store.addEntry(body: "  風が気持ちいい #散歩\n", date: date))
        let reopened = PrivateNoteStore(url: url)
        let note = try XCTUnwrap(reopened.notes.first { $0.id != legacy.id })
        XCTAssertEqual(note.title, ""); XCTAssertEqual(note.body, "風が気持ちいい #散歩")
        XCTAssertEqual(note.displayTitle, "風が気持ちいい #散歩"); XCTAssertEqual(note.tags, ["散歩"]); XCTAssertEqual(note.date, date)
        XCTAssertEqual(reopened.notes.first { $0.id == legacy.id }, legacy)
    }
    @MainActor func testFailedQuickCaptureCanRetryWithoutDuplicateNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocker)
        let store = PrivateNoteStore(url: blocker.appendingPathComponent("notes.json"))
        XCTAssertFalse(store.addEntry(body: "消したくない一言 #気づき")); XCTAssertTrue(store.notes.isEmpty); XCTAssertNotNil(store.storageError)
        try FileManager.default.removeItem(at: blocker)
        XCTAssertTrue(store.addEntry(body: "消したくない一言 #気づき")); XCTAssertEqual(store.notes.count, 1); XCTAssertNil(store.storageError)
    }
    func testSBOMAndLicensesAreBundled() throws {
        let inventory = try XCTUnwrap(DependencyInventory.bundled)
        XCTAssertEqual(inventory.specVersion, "1.6")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: inventory.components.map { ($0.name, $0.version) }), ["swift-markdown":"0.8.0", "swift-cmark":"0.9.0"])
        for component in inventory.components { XCTAssertEqual(component.revision.count, 40); XCTAssertFalse(DependencyInventory.resource(component.licenseFile).hasPrefix("ファイルを読み込めません")) }
        XCTAssertTrue(DependencyInventory.resource("SwiftMarkdown-NOTICE.txt").contains("The Swift Markdown Project"))
    }
    func testSpotifyNormalization() {
        XCTAssertEqual(SpotifyLink(spotify)?.url.absoluteString, "https://open.spotify.com/track/0123456789ABCDEFGHIJKL")
        XCTAssertEqual(SpotifyLink("https://open.spotify.com/intl-ja/album/0123456789ABCDEFGHIJKL")?.kind, "album")
        XCTAssertEqual(SpotifyLink("https://open.spotify.com/embed/track/0123456789ABCDEFGHIJKL")?.embedURL.absoluteString, "https://open.spotify.com/embed/track/0123456789ABCDEFGHIJKL")
    }
    func testUnsafeSpotifyInputsRejected() {
        for value in ["http://open.spotify.com/track/0123456789ABCDEFGHIJKL", "https://open.spotify.com.evil.example/track/0123456789ABCDEFGHIJKL", "https://evil@open.spotify.com/track/0123456789ABCDEFGHIJKL", "https://open.spotify.com:443/track/0123456789ABCDEFGHIJKL", "https://open.spotify.com/playlist/0123456789ABCDEFGHIJKL", "https://open.spotify.com/track/<script>", "https://open.spotify.com/track/short", "javascript:alert(1)"] { XCTAssertNil(SpotifyLink(value), value) }
    }
    func testYouTubeMusicNormalization() {
        XCTAssertEqual(MusicLink.youtube("https://music.youtube.com/watch?v=abcdefghijk&si=tracking")?.absoluteString, "https://music.youtube.com/watch?v=abcdefghijk")
        XCTAssertNil(MusicLink.youtube("https://music.youtube.com.evil.example/watch?v=a"))
        XCTAssertNil(MusicLink.youtube("http://music.youtube.com/watch?v=a"))
        XCTAssertNil(MusicLink.youtube("https://music.youtube.com/watch"))
        XCTAssertNil(MusicLink.youtube("https://music.youtube.com/watch?v=short"))
        XCTAssertNil(MusicLink.youtube("https://user@music.youtube.com/watch?v=abcdefghijk"))
        XCTAssertNil(MusicLink.youtube("https://music.youtube.com:443/watch?v=abcdefghijk"))
        XCTAssertEqual(MusicLink.youtube("https://music.youtube.com/playlist?list=OLAK5uy_example&si=x")?.absoluteString, "https://music.youtube.com/playlist?list=OLAK5uy_example")
    }
    func testYAMLScalarEscaping() throws {
        for value in ["引用\"と改行\n---\n", "null", "#tag: yes", "日本語🎵", "\u{0000}\t\\"] {
            // A valid JSON string is also a valid YAML 1.2 quoted scalar.
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(Draft.yaml(value).utf8)), value)
        }
    }
    func testStableFileNameAndCodableRoundTrip() throws {
        var draft = Draft(kind: .diary)
        let filename = draft.filename
        draft.title = "different title"; draft.date = Date.distantPast
        XCTAssertEqual(draft.filename, filename)
        XCTAssertEqual(try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(draft)), draft)
        XCTAssertTrue(draft.path.hasPrefix("src/content/diary/ios-"))
    }
    func testMusicRequiresExplicitConfirmation() {
        var draft = Draft(kind: .music)
        draft.title = "音楽"; draft.description = "説明"
        var item = MusicItem(); item.title = "曲"; item.spotifyURL = spotify
        draft.music = [item]
        XCTAssertNotNil(draft.validation)
        XCTAssertFalse(draft.markdown.contains("<iframe"))
        draft.music[0].confirmed = true
        XCTAssertNil(draft.validation)
        XCTAssertTrue(draft.markdown.contains("https://open.spotify.com/embed/track/0123456789ABCDEFGHIJKL"))
        XCTAssertFalse(draft.markdown.contains("?si="))
    }
    func testOrderAndFrontmatter() {
        var draft = Draft(kind: .music)
        draft.title = "聴いた曲"; draft.description = "a: b\n---"; draft.tags = "音楽, 日記、J-pop\n"
        var first = MusicItem(); first.title = "First"; first.spotifyURL = spotify; first.confirmed = true
        var second = first; second.id = UUID(); second.title = "Second"
        draft.music = [first, second]
        let text = draft.markdown
        XCTAssertTrue(text.hasPrefix("---\ntitle: "))
        XCTAssertTrue(text.contains("tags: [\"音楽\", \"日記\", \"J-pop\"]"))
        XCTAssertLessThan(text.range(of: "### First")!.lowerBound, text.range(of: "### Second")!.lowerBound)
        XCTAssertEqual(text.components(separatedBy: "<iframe").count - 1, 2)
    }
    @MainActor func testPersistenceAndUnreadableFileProtection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drafts.json")
        let store = DraftStore(url: url)
        var draft = Draft(kind: .diary); draft.body = "下書き"; draft.pendingMarkdown = "pending exact content"
        XCTAssertTrue(store.update(draft))
        let reopened = DraftStore(url: url)
        XCTAssertEqual(reopened.drafts.first?.body, "下書き")
        XCTAssertEqual(reopened.drafts.first?.pendingMarkdown, "pending exact content")
        try Data("broken".utf8).write(to: url)
        let broken = DraftStore(url: url)
        XCTAssertFalse(broken.loaded)
        XCTAssertFalse(broken.update(draft))
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }
    func testMarkdownFormattingPreservesUnicodeAndSelection() {
        let body = "今日🎵の音"
        let selection = (body as NSString).range(of: "🎵の")
        let bold = MarkdownEditing.apply(.bold, to: body, selection: selection)
        XCTAssertEqual(bold.text, "今日**🎵の**音")
        XCTAssertEqual((bold.text as NSString).substring(with: bold.selection), "🎵の")
        let removed = MarkdownEditing.apply(.bold, to: bold.text, selection: bold.selection)
        XCTAssertEqual(removed.text, body)
        let italic = MarkdownEditing.apply(.italic, to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(italic.text, "*斜体*")
        XCTAssertEqual((italic.text as NSString).substring(with: italic.selection), "斜体")
        let link = MarkdownEditing.apply(.link, to: body, selection: selection)
        XCTAssertEqual(link.text, "今日[🎵の](https://)音")
        XCTAssertEqual((link.text as NSString).substring(with: link.selection), "https://")
        let combined = MarkdownEditing.apply(.italic, to: "**日本語**", selection: NSRange(location: 2, length: 3))
        XCTAssertEqual(combined.text, "***日本語***")
        XCTAssertEqual(MarkdownEditing.apply(.italic, to: combined.text, selection: combined.selection).text, "**日本語**")
    }
    func testMarkdownBlocksIncludeLastSelectedLineWithoutNextLine() {
        let body = "朝\n夜\n次"
        let both = MarkdownEditing.apply(.bullet, to: body, selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(both.text, "- 朝\n- 夜\n次")
        let undo = MarkdownEditing.apply(.bullet, to: both.text, selection: both.selection)
        XCTAssertEqual(undo.text, body)
        let first = MarkdownEditing.apply(.heading(2), to: body, selection: NSRange(location: 0, length: 2))
        XCTAssertEqual(first.text, "## 朝\n夜\n次")
        XCTAssertEqual(MarkdownEditing.apply(.heading(3), to: "# 日本語", selection: NSRange(location: 3, length: 0)).text, "### 日本語")
        XCTAssertEqual(MarkdownEditing.apply(.numbered, to: "a\nb", selection: NSRange(location: 0, length: 3)).text, "1. a\n2. b")
        XCTAssertEqual(MarkdownEditing.apply(.numbered, to: "2. メモ", selection: NSRange(location: 5, length: 0)).text, "メモ")
        XCTAssertEqual(MarkdownEditing.apply(.numbered, to: "- a\n- b", selection: NSRange(location: 0, length: 7)).text, "1. a\n2. b")
    }
    func testBlogMarkdownRendersFormattingAndEscapesHTML() {
        let html = BlogPreviewHTML.renderMarkdown("## 朝\n\n**太字**と*斜体*\n\n- 音\n- 日記\n\n`<code>`\n\n<script>alert(1)</script>\n\n[危険](javascript:alert%281%29)")
        XCTAssertTrue(html.contains("<h2>朝</h2>"))
        XCTAssertTrue(html.contains("<strong>太字</strong>"))
        XCTAssertTrue(html.contains("<em>斜体</em>"))
        XCTAssertTrue(html.contains("<ul><li>音</li><li>日記</li></ul>"))
        XCTAssertTrue(html.contains("<code>&lt;code&gt;</code>"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        var draft = Draft(kind: .diary); draft.title = "<秘密>&\""
        let preview = BlogPreviewHTML.document(draft)
        XCTAssertTrue(preview.contains("&lt;秘密&gt;&amp;&quot;"))
        XCTAssertTrue(preview.contains("下書きプレビュー · 未公開"))
    }
    func testMusicSourcesNormalizeSongIDsAndRegions() throws {
        let apple = try XCTUnwrap(SharedMusicLink.parse("https://music.apple.com/jp/album/曲名/1053933969?i=1053934844&l=en&at=tracker"))
        XCTAssertEqual(apple.service, .apple); XCTAssertEqual(apple.trackID, "1053934844"); XCTAssertEqual(apple.country, "jp")
        XCTAssertEqual(apple.url.absoluteString, "https://music.apple.com/jp/song/1053934844")
        XCTAssertEqual(SharedMusicLink.parse("https://music.apple.com/gb/song/hymn/1053934844?ls=1")?.trackID, "1053934844")
        for host in SharedMusicLink.amazonHosts {
            let link = try XCTUnwrap(SharedMusicLink.parse("https://\(host)/albums/B084KP4NBH/?trackAsin=B084KPC3Q7&do=play&ref=dm_sh"))
            XCTAssertEqual(link.service, .amazon); XCTAssertEqual(link.trackID, "B084KPC3Q7")
            XCTAssertEqual(link.url.absoluteString, "https://\(host)/tracks/B084KPC3Q7")
        }
        XCTAssertEqual(SharedMusicLink.parse("https://youtu.be/YykjpeuMNEk?si=tracking")?.url.absoluteString, "https://music.youtube.com/watch?v=YykjpeuMNEk")
        XCTAssertEqual(SharedMusicLink.parse("https://www.youtube.com/watch?v=YykjpeuMNEk&list=ignored")?.trackID, "YykjpeuMNEk")
        for url in ["https://apple.co/30NF6YA", "https://amzn.to/3v5N2DO", "https://a.co/d/9G0RkjN"] { XCTAssertTrue(try XCTUnwrap(SharedMusicLink.parse(url)).isShort) }
        XCTAssertEqual(SharedMusicLink.extract("好きな曲\nhttps://music.apple.com/us/album/hymn/1053933969?i=1053934844")?.absoluteString, "https://music.apple.com/us/song/1053934844")
        XCTAssertEqual(SharedMusicLink.extract("Selfless https://music.amazon.co.jp/albums/B084KP4NBH?trackAsin=B084KPC3Q7&ref=dm_sh")?.path, "/tracks/B084KPC3Q7")
    }
    func testAmbiguousAndUnsafeMusicSourcesAreRejected() {
        for raw in ["http://music.apple.com/us/song/123", "https://music.apple.com.evil.example/us/song/123", "https://user@music.amazon.com/tracks/B084KPC3Q7", "https://music.amazon.com:443/tracks/B084KPC3Q7", "https://music.amazon.evil.example/tracks/B084KPC3Q7", "https://music.amazon.com/tracks/short", "https://music.apple.com/us/album/name/123?i=1&i=2", "https://music.apple.com/us/album/name/123?i=oops", "https://music.amazon.com/albums/B084KP4NBH?trackAsin=B084KPC3Q7&trackAsin=B084KPC3Q7", "https://music.youtube.com/watch?v=abcdefghijk&v=lmnopqrstuv", "https://music.apple.com/us/song/0", "https://apple.co/", "https://a.co/../../secret", "https://music.apple.com/us/song/123?i=456", "https://music.amazon.com/tracks/B084KPC3Q7?trackAsin=B084KP4NBH"] {
            XCTAssertNil(SharedMusicLink.parse(raw), raw)
        }
        for raw in ["https://music.apple.com/us/album/a-head-full-of-dreams/1053933969", "https://music.apple.com/jp/playlist/name/pl.123", "https://music.amazon.com/albums/B084KP4NBH", "https://music.amazon.com/playlists/B084KP4NBH", "https://music.youtube.com/playlist?list=OLAK5uy_example"] {
            XCTAssertNotNil(SharedMusicLink.parse(raw)?.issue, raw)
        }
    }
    func testAppleLookupUsesExactSongAndPreservesVersions() throws {
        let data = Data(#"{"results":[{"kind":"album","trackId":1053934844,"trackName":"Wrong","artistName":"Wrong"},{"kind":"song","trackId":123,"trackName":"Wrong","artistName":"Wrong"},{"kind":"song","trackId":1053934844,"trackName":"Selfless (Live)","artistName":"The Strokes","trackTimeMillis":222000}]}"#.utf8)
        XCTAssertEqual(try MusicPageParser.appleLookup(data, trackID: "1053934844"), MusicMetadata(title: "Selfless (Live)", artist: "The Strokes", duration: 222000))
        XCTAssertThrowsError(try MusicPageParser.appleLookup(data, trackID: "999"))
        XCTAssertThrowsError(try MusicPageParser.appleLookup(Data(#"{"results":[]}"#.utf8), trackID: "1053934844"))
    }
    func testPublicSongRequiresRecordingIdentityAndArtist() throws {
        let source = try XCTUnwrap(SharedMusicLink.parse("https://music.apple.com/us/song/1053934844"))
        let html = #"<script id=schema:song type="application/ld+json">{"@type":"MusicComposition","audio":{"@type":"MusicRecording","url":"https://music.apple.com/us/song/hymn/1053934844","name":"Hymn & Weekend","byArtist":[{"name":"Coldplay"}]}}</script>"#
        XCTAssertEqual(try MusicPageParser.publicSong(html, source: source).artist, "Coldplay")
        XCTAssertThrowsError(try MusicPageParser.publicSong(html.replacingOccurrences(of: "1053934844", with: "123"), source: source))
        XCTAssertThrowsError(try MusicPageParser.publicSong(html.replacingOccurrences(of: "MusicRecording", with: "MusicAlbum"), source: source))
        XCTAssertThrowsError(try MusicPageParser.publicSong("<html>Sign in</html>", source: source))
        let amazon = try XCTUnwrap(SharedMusicLink.parse("https://music.amazon.com/tracks/B084KPC3Q7"))
        let amazonHTML = #"<script type='application/ld+json'>{"@graph":[{"@type":"MusicRecording","url":"https://music.amazon.com/tracks/B084KPC3Q7","name":"Selfless","byArtist":{"name":"The Strokes"}}]}</script>"#
        XCTAssertEqual(try MusicPageParser.publicSong(amazonHTML, source: amazon).title, "Selfless")
    }
    func testSonglinkRejectsDifferentProviderIDAndAlbum() throws {
        let source = try XCTUnwrap(SharedMusicLink.parse("https://music.amazon.com/tracks/B084KPC3Q7"))
        let html = MultiServiceMusicFixture.songlink(provider: "amazon", id: "B084KPC3Q7")
        XCTAssertEqual(try MusicPageParser.songlink(html, source: source).1.count, 1)
        for wrong in [html.replacingOccurrences(of: "amazon", with: "itunes"), html.replacingOccurrences(of: "B084KPC3Q7", with: "B084KP4NBH"), html.replacingOccurrences(of: "\"type\":\"song\"", with: "\"type\":\"album\"")] {
            XCTAssertThrowsError(try MusicPageParser.songlink(wrong, source: source))
        }
    }
    func testNewSourcesReuseMappedSpotifyCandidates() async throws {
        for raw in ["https://music.apple.com/us/album/title/1053933969?i=1053934844", "https://music.amazon.co.jp/albums/B084KP4NBH?trackAsin=B084KPC3Q7"] {
            let result = try await multiServiceResolver().resolve(URL(string: raw)!)
            XCTAssertEqual(result.metadata.title, "Selfless")
            XCTAssertEqual(result.candidates.count, 1); XCTAssertEqual(result.candidates.first?.artist, "The Strokes")
            XCTAssertNil(result.notice)
        }
    }
    func testAppleFallbackRejectsSonglinkAlbumAndUsesRegionalLookup() async throws {
        let result = try await multiServiceResolver().resolve(URL(string: "https://music.apple.com/jp/song/222")!)
        XCTAssertEqual(result.metadata.title, "Lookup JP"); XCTAssertEqual(result.metadata.artist, "Artist")
        XCTAssertTrue(result.candidates.isEmpty); XCTAssertNotNil(result.notice)
        let other = try await multiServiceResolver().resolve(URL(string: "https://music.apple.com/us/song/222")!)
        XCTAssertEqual(other.metadata.title, "Lookup US")
    }
    func testApplePublicPageFallbackAndAmazonMetadataFallback() async throws {
        let apple = try await multiServiceResolver().resolve(URL(string: "https://music.apple.com/us/song/333")!)
        XCTAssertEqual(apple.metadata.title, "Public Song")
        let amazon = try await multiServiceResolver().resolve(URL(string: "https://music.amazon.com/tracks/B000PUBLIC")!)
        XCTAssertEqual(amazon.metadata.artist, "Public Artist")
    }
    func testShortURLExpansionAndFinalDestinationValidation() async throws {
        let result = try await multiServiceResolver().resolve(URL(string: "https://apple.co/good123")!)
        XCTAssertEqual(result.metadata.title, "Selfless")
        for raw in ["https://apple.co/bad123", "https://amzn.to/album123", "https://apple.co/cross123"] {
            do { _ = try await multiServiceResolver().resolve(URL(string: raw)!); XCTFail(raw) }
            catch { XCTAssertTrue(error.localizedDescription.contains("手入力"), error.localizedDescription) }
        }
        // A final response URL cannot substitute another track after a redirect.
        do { _ = try await multiServiceResolver().resolve(URL(string: "https://music.amazon.com/tracks/B000REDIR1")!); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Spotify")) }
    }
    func testRedirectPolicyBlocksUnsafeHopsAndBoundsRedirects() throws {
        for raw in ["http://music.apple.com/us/song/123", "https://music.apple.com.evil.example/us/song/123", "https://user@music.apple.com/us/song/123", "https://music.apple.com:443/us/song/123", "https://open.spotify.com/track/0123456789ABCDEFGHIJKL", "https://music.apple.com/us/artist/name/123"] {
            XCTAssertFalse(MusicRedirectPolicy.allows(URL(string: raw)!, sharing: .apple))
        }
        let original = URL(string: "https://apple.co/good123")!
        let destination = URL(string: "https://music.apple.com/us/song/1053934844")!
        XCTAssertTrue(MusicRedirectPolicy.allows(destination, sharing: .apple))
        XCTAssertFalse(MusicRedirectPolicy.preservesIdentity(from: destination, to: URL(string: "https://music.apple.com/us/song/222")!))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        let policy = MusicRedirectPolicy(sharing: .apple)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for index in 1...6 {
            var accepted = false
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: destination)) { accepted = $0 != nil }
            XCTAssertEqual(accepted, index <= 5)
        }
    }
    func testUnavailableMetadataExplainsManualContinuation() async throws {
        for raw in ["https://music.amazon.com/tracks/B000FAILED", "https://music.apple.com/us/song/444", "https://music.youtube.com/watch?v=FAILFAILFAI", "https://music.amazon.com/albums/B084KP4NBH"] {
            do { _ = try await multiServiceResolver().resolve(URL(string: raw)!); XCTFail(raw) }
            catch { XCTAssertTrue(error.localizedDescription.contains("手入力")); XCTAssertTrue(error.localizedDescription.contains("Spotify") || error.localizedDescription.contains("曲情報")) }
        }
    }
    func testCacheKeepsServiceRegionAndRefreshSeparate() async throws {
        let resolver = multiServiceResolver()
        let jp = URL(string: "https://music.apple.com/jp/song/222")!, us = URL(string: "https://music.apple.com/us/song/222")!
        let japan = try await resolver.resolve(jp), america = try await resolver.resolve(us)
        XCTAssertNotEqual(japan.metadata.title, america.metadata.title)
        let countBeforeCache = MultiServiceMusicFixture.count(for: "https://song.link/i/222")
        _ = try await resolver.resolve(jp)
        XCTAssertEqual(MultiServiceMusicFixture.count(for: "https://song.link/i/222"), countBeforeCache)
        let refreshed = try await resolver.refresh(jp)
        XCTAssertEqual(refreshed.metadata, japan.metadata)
        XCTAssertEqual(MultiServiceMusicFixture.count(for: "https://song.link/i/222"), countBeforeCache + 1)
        // Numeric video IDs and Apple IDs may collide; provider is part of the cache key.
        let apple = try await resolver.resolve(URL(string: "https://music.apple.com/us/song/10539348440")!)
        let youtube = try await resolver.resolve(URL(string: "https://music.youtube.com/watch?v=10539348440")!)
        XCTAssertEqual(apple.metadata.title, "Apple Song"); XCTAssertEqual(youtube.metadata.title, "YouTube Song")
    }
    func testLegacyMusicJSONAndManualCompletionRemainCompatible() throws {
        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"Old Song","artist":"Artist","comment":"Memo","youtubeURL":"https://music.youtube.com/playlist?list=OLAK5uy_example","spotifyURL":"https://open.spotify.com/track/0123456789ABCDEFGHIJKL","confirmed":true}"#.utf8)
        let item = try JSONDecoder().decode(MusicItem.self, from: legacy)
        XCTAssertEqual(item.title, "Old Song"); XCTAssertNil(item.sourceID)
        XCTAssertEqual(try JSONDecoder().decode(MusicItem.self, from: JSONEncoder().encode(item)), item)
        var draft = Draft(kind: .music); draft.title = "記事"; draft.description = "説明"; draft.music = [item]
        for raw in [item.youtubeURL, "https://music.apple.com/us/song/1053934844", "https://music.amazon.com/tracks/B084KPC3Q7", "https://unavailable.example/song"] {
            draft.music[0].youtubeURL = raw
            XCTAssertNil(draft.validation); XCTAssertTrue(draft.markdown.contains("<iframe"))
            XCTAssertEqual(try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(draft)).music[0].youtubeURL, raw)
        }
        draft.music[0].confirmed = false
        XCTAssertNotNil(draft.validation); XCTAssertFalse(draft.markdown.contains("<iframe"))
    }
    private func multiServiceResolver() -> PublicMusicResolver {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MultiServiceMusicFixture.self]
        return PublicMusicResolver(session: URLSession(configuration: config))
    }
    func testMusicMetadataAndPublicPageParsing() throws {
        let embed = Data(#"{"title":"Coldplay - Hymn For The Weekend (Official Video)","author_name":"Coldplay"}"#.utf8)
        let info = try MusicPageParser.oembed(embed)
        XCTAssertEqual(info.title, "Hymn For The Weekend")
        XCTAssertEqual(info.artist, "Coldplay")
        XCTAssertEqual(MusicPageParser.searchTitle("アイドル - Idol"), "アイドル")
        XCTAssertTrue(MusicPageParser.sameTitle("Hymn for the Weekend (feat. Beyoncé)", "Hymn For The Weekend"))
        XCTAssertFalse(MusicPageParser.sameTitle("Hymn for the Weekend (Seeb Remix)", "Hymn for the Weekend"))
        XCTAssertFalse(MusicPageParser.sameArtist("Coldplay", "Cover Band"))
        let html = #"<a href="/intl-en/track/3RiPr603aXAoi4GHyXx0uy"><span>Hymn for the Weekend</span></a><a href="/track/short">wrong</a>"#
        let tracks = MusicPageParser.albumTracks(html)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].title, "Hymn for the Weekend")
        XCTAssertEqual(tracks[0].link.url.absoluteString, "https://open.spotify.com/track/3RiPr603aXAoi4GHyXx0uy")
        XCTAssertEqual(MusicPageParser.unescape("Up&amp;Up &#x1F3B5;"), "Up&Up 🎵")
        let page = #"<meta content="Hymn for the Weekend" property="og:title"><meta property="og:description" content="Coldplay · Album · Song · 2015"><meta property="og:type" content="music.song">"#
        XCTAssertEqual(MusicPageParser.spotifyTrack(page)?.artist, "Coldplay")
        XCTAssertThrowsError(try MusicPageParser.songlink("<html>service unavailable</html>", videoID: "YykjpeuMNEk"))
    }
    func testPublicResolverFindsTrackThroughReleaseAndCaches() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MusicFixtureProtocol.self]
        let resolver = PublicMusicResolver(session: URLSession(configuration: config))
        let url = URL(string: "https://music.youtube.com/watch?v=YykjpeuMNEk")!
        let result = try await resolver.resolve(url)
        XCTAssertEqual(result.metadata.artist, "Coldplay")
        XCTAssertEqual(result.candidates.map(\.id), ["https://open.spotify.com/track/3RiPr603aXAoi4GHyXx0uy"])
        XCTAssertEqual(result.candidates.first?.album, "A Head Full of Dreams")
        let cached = try await resolver.resolve(url)
        XCTAssertEqual(cached.candidates, result.candidates)
        XCTAssertNil(result.notice)
    }
    func testSpotifySearchKeepsJapaneseAndReservedCharactersInOnePath() throws {
        let url = try XCTUnwrap(MusicLink.search(title: "ループ＆ループ / ? #", artist: "ASIAN KUNG-FU GENERATION"))
        XCTAssertEqual(url.host, "open.spotify.com")
        XCTAssertNil(url.query); XCTAssertNil(url.fragment)
        XCTAssertEqual(url.path, "/search/ループ＆ループ / ? # ASIAN KUNG-FU GENERATION")
        XCTAssertTrue(url.absoluteString.contains("%2F"))
        XCTAssertNil(MusicLink.search(title: " \n", artist: ""))
    }
    func testBroaderMusicMatchingRetainsVersionsAsReviewableCandidates() {
        let loop = MusicSearchPlan(MusicMetadata(title: "ループ＆ループ", artist: "ASIAN KUNG-FU GENERATION", duration: nil))
        XCTAssertEqual(loop.titleScore("ループ&ループ"), 0)
        XCTAssertEqual(loop.titleScore("ループ&ループ (2016 Version)"), 1)
        XCTAssertNil(loop.titleScore("リライト"))
        let info = MusicPageParser.clean(title: "フジファブリック (Fujifabric) - 茜色の夕日(Akaneiro No Yuuhi)", artist: "フジファブリック Official Channel", duration: nil)
        XCTAssertEqual(info.artist, "フジファブリック")
        var plan = MusicSearchPlan(info)
        XCTAssertEqual(plan.titleScore("茜色の夕日"), 0)
        XCTAssertEqual(plan.titleScore("Akaneiro No Yuuhi"), 0)
        XCTAssertEqual(plan.titleScore("Akaneiro No Yuhi"), 2)
        plan.addArtists(["Fujifabric"])
        XCTAssertTrue(plan.artistMatches("Fujifabric"))
        XCTAssertFalse(plan.artistMatches("Cover Band"))
        XCTAssertNil(MusicSearchPlan(MusicMetadata(title: "Love", artist: "A", duration: nil)).titleScore("Live"))
    }
    func testBilingualCreditsAndLabelUploadsUseThePerformer() {
        let info = MusicPageParser.clean(title: "折坂悠太 - 朝顔 (Official Music Video) / Yuta Orisaka - Asagao", artist: "Orisaka Yuta", duration: nil)
        XCTAssertEqual(info.title, "朝顔 / Asagao")
        let plan = MusicSearchPlan(info)
        XCTAssertEqual(plan.titleScore("朝顔"), 0)
        XCTAssertEqual(plan.titleScore("Asagao"), 0)
        XCTAssertTrue(plan.artistMatches("Yuta Orisaka"))
        let label = MusicPageParser.clean(title: "Snail Mail - \"Pristine\" (Official Lyric Video)", artist: "Matador Records", duration: nil)
        XCTAssertEqual(label.title, "Pristine"); XCTAssertEqual(label.artist, "Snail Mail")
    }
    func testIndieVideoCreditsRecoverPerformerAndPresentationLabels() {
        let cases: [(String, String, String, String)] = [
            (#"Tempalay "そなちね" (Official Music Video)"#, "Tempalay", "Tempalay", "そなちね"),
            ("cero / Summer Soul【OFFICIAL MUSIC VIDEO】", "KAKUBARHYTHM", "cero", "Summer Soul"),
            ("D.A.N. - SSWB (Official Video)", "lute", "D.A.N.", "SSWB"),
            ("Yogee New Waves / CLIMAX NIGHT (New Version - Official MV)", "YOGEE NEW WAVES", "YOGEE NEW WAVES", "CLIMAX NIGHT (New Version)"),
            ("OGRE YOU ASSHOLE - ロープ［OFFICIAL MUSIC VIDEO］", "VAP OFFICIAL MUSIC CHANNEL", "OGRE YOU ASSHOLE", "ロープ"),
            ("踊ってばかりの国『ghost』Music Video(2019)", "踊ってばかりの国official", "踊ってばかりの国", "ghost"),
            (#""Doused" // DIIV"#, "CapturedTracks", "DIIV", "Doused"),
            ("Pedestrian At Best - Courtney Barnett", "courtneybarnett", "courtneybarnett", "Pedestrian At Best"),
            ("君島大空 MV「遠視のコントラルト」", "apollosounds2013", "君島大空", "遠視のコントラルト"),
            ("Clairo - Bags (Japanese Lyric Video)", "Claire Cottrill", "Clairo", "Bags"),
            ("[MV] hyukoh(혁오) _ Comes And Goes(와리가리)", "1theK (원더케이)", "hyukoh(혁오)", "Comes And Goes(와리가리)"),
            ("とぼけた顔 (𝑀𝑈𝑆𝐼𝐶 𝑉𝐼𝐷𝐸𝑂) // 浦上想起", "浦上想起 URAKAMI Souki", "浦上想起", "とぼけた顔")
        ]
        for (title, channel, artist, song) in cases {
            let info = MusicPageParser.clean(title: title, artist: channel, duration: nil)
            XCTAssertEqual(info.artist, artist, title); XCTAssertEqual(info.title, song, title)
        }
    }
    func testQuotedSoundtrackAndFestivalAnnotationsDoNotBecomeSongCredits() {
        let soundtrack = MusicPageParser.clean(title: #"Sufjan Stevens - Mystery of Love (From "Call Me By Your Name" Soundtrack)"#, artist: "SonySoundtracksVEVO", duration: nil)
        XCTAssertEqual(soundtrack.artist, "Sufjan Stevens")
        XCTAssertEqual(soundtrack.title, #"Mystery of Love (From "Call Me By Your Name" Soundtrack)"#)
        XCTAssertEqual(MusicSearchPlan(soundtrack).titleScore("Mystery of Love"), 1)
        let festival = MusicPageParser.clean(title: #"kurayamisaka - curtain call（FUJI ROCK FESTIVAL'24 "ROOKIE A GO-GO"）"#, artist: "Fuji Rock Festival", duration: nil)
        XCTAssertEqual(festival.artist, "kurayamisaka")
        XCTAssertEqual(MusicSearchPlan(festival).titleScore("curtain call"), 1)
        XCTAssertEqual(MusicPageParser.clean(title: "Song - Remix", artist: "Artist", duration: nil).title, "Song - Remix")
    }
    func testJapaneseSongTranslationsAreNotMisreadAsPerformerCredits() {
        for (song, translation, artist) in [("狐", "kitsune", "betcover!!"), ("エイリアンズ", "Aliens", "KIRINJI"), ("光るとき", "Hikaru toki", "Hitsujibungaku"), ("グッドバイ", "Guddo Bai", "toe")] {
            let info = MusicPageParser.clean(title: song + " - " + translation, artist: artist, duration: nil)
            XCTAssertEqual(info.artist, artist)
            XCTAssertEqual(MusicSearchPlan(info).titleScore(song), 0)
            XCTAssertEqual(MusicSearchPlan(info).titleScore(translation), 0)
        }
        let label = MusicPageParser.clean(title: "青葉市子 - hello", artist: "Victor Entertainment", duration: nil)
        XCTAssertEqual(label.artist, "青葉市子"); XCTAssertEqual(label.title, "hello")
    }
    func testJapaneseVersionSuffixesKeepWarningsAndRankAfterOriginal() {
        let plan = MusicSearchPlan(MusicMetadata(title: "エイリアンズ", artist: "KIRINJI", duration: nil))
        XCTAssertEqual(plan.titleScore("エイリアンズ"), 0)
        XCTAssertEqual(plan.titleScore("エイリアンズ - 2018 Remaster"), 1)
        XCTAssertEqual(plan.titleScore("エイリアンズ - Instrumental 2018 Remaster"), 1)
        XCTAssertEqual(MusicSearchPlan(MusicMetadata(title: "狐", artist: "betcover!!", duration: nil)).titleScore("狐 - Live"), 1)
        XCTAssertEqual(MusicSearchPlan(MusicMetadata(title: "セツナ", artist: "Sunny Day Service", duration: nil)).titleScore("セツナ（live2）"), 1)
        XCTAssertEqual(MusicSearchPlan(MusicMetadata(title: "光るとき - Hikaru toki", artist: "羊文学", duration: nil)).titleScore("Hikaru toki"), 0)
    }
    func testBilingualIndieTitlesAndFeaturedCreditsKeepSearchVariants() {
        let cats = MusicPageParser.clean(title: "Siamese Cats - Cauliflower (Official Audio Video)　シャムキャッツ - カリフラワー", artist: "Siamese Cats", duration: nil)
        XCTAssertEqual(cats.title, "Cauliflower / カリフラワー")
        XCTAssertEqual(MusicSearchPlan(cats).titleScore("カリフラワー"), 0)
        let shibata = MusicSearchPlan(MusicMetadata(title: "雑感 | Understood", artist: "柴田聡子 | Satoko Shibata", duration: nil))
        XCTAssertEqual(shibata.titleScore("Understood"), 0)
        XCTAssertEqual(MusicPageParser.searchTitle("夜を使いはたして feat. PUNPEE"), "夜を使いはたして")
        XCTAssertEqual(MusicSearchPlan(MusicMetadata(title: "긴 꿈 (A Long Dream)", artist: "SE SO NEON", duration: nil)).titleScore("A Long Dream"), 0)
        XCTAssertEqual(MusicSearchPlan(MusicMetadata(title: "Comes And Goes(와리가리)", artist: "hyukoh", duration: nil)).titleScore("와리가리"), 0)
        XCTAssertEqual(MusicSearchPlan(MusicMetadata(title: "はあとぶれいく June 15th, 2021", artist: "Zazen Boys", duration: nil)).titleScore("はあとぶれいく"), 1)
        XCTAssertEqual(MusicSearchPlan(MusicMetadata(title: "山海 Wayfarer", artist: "草東沒有派對", duration: nil)).titleScore("山海"), 0)
    }
    func testArtistCatalogLinksAreBoundedToSpotifyAndDeduplicated() {
        XCTAssertNil(SpotifyLink("https://open.spotify.com/artist/2YtvgEYiTH6jh7n2UmUdXX"))
        XCTAssertEqual(MusicPageParser.spotifyArtistURL("https://open.spotify.com/intl-ja/artist/2YtvgEYiTH6jh7n2UmUdXX?si=x")?.path, "/artist/2YtvgEYiTH6jh7n2UmUdXX")
        XCTAssertNil(MusicPageParser.spotifyArtistURL("https://open.spotify.com.evil.example/artist/2YtvgEYiTH6jh7n2UmUdXX"))
        XCTAssertNil(MusicPageParser.spotifyArtistURL("https://user@open.spotify.com/artist/2YtvgEYiTH6jh7n2UmUdXX"))
        let albums = MusicPageParser.artistAlbums(#"<a href="/album/1bW2uDVWI51ttFReQYFWQ0">fam fam</a><a href="/album/1bW2uDVWI51ttFReQYFWQ0">same</a><a href="https://evil.example/album/5HMF0jFGPGqtHka0GoIoge">wrong</a>"#)
        XCTAssertEqual(albums.map(\.id), ["1bW2uDVWI51ttFReQYFWQ0"])
    }
    func testResolverFindsIndieSongWithoutReleaseSpotifyRelations() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JapaneseMusicFixtureProtocol.self]
        let resolver = PublicMusicResolver(session: URLSession(configuration: config))
        let result = try await resolver.resolve(URL(string: "https://music.youtube.com/watch?v=PL9-6rClgXs")!)
        XCTAssertEqual(result.candidates.first?.title, "明るい未来")
        XCTAssertEqual(result.candidates.first?.album, "fam fam")
        XCTAssertNil(result.notice)
    }
    func testJapaneseResolverUsesArtistAliasesAndContinuesAfterBrokenRelease() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JapaneseMusicFixtureProtocol.self]
        let resolver = PublicMusicResolver(session: URLSession(configuration: config))
        let result = try await resolver.resolve(URL(string: "https://music.youtube.com/watch?v=vYo-hpzuS2c")!)
        XCTAssertEqual(result.metadata.artist, "フジファブリック")
        XCTAssertEqual(result.candidates.map(\.title), ["茜色の夕日", "茜色の夕日 (Remastered 2019)"])
        XCTAssertEqual(result.candidates.first?.artist, "Fujifabric")
        XCTAssertNotNil(result.candidates.last?.matchNote)
        XCTAssertNil(result.notice)
    }
    func testCatalogTrackIDBridgesEnglishTitleToJapaneseRecording() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JapaneseMusicFixtureProtocol.self]
        let resolver = PublicMusicResolver(session: URLSession(configuration: config))
        let result = try await resolver.resolve(URL(string: "https://music.youtube.com/watch?v=RFTl5AJdBZc")!)
        XCTAssertEqual(result.metadata.title, "Loop & Loop")
        XCTAssertEqual(result.candidates.first?.title, "ループ＆ループ")
        XCTAssertEqual(result.candidates.first?.spotify.id, "19mAWClvP2t0JzctutaM0t")
        XCTAssertNil(result.notice)
    }
}

extension WriterTests {
    func testPublishedSortingUsesArticleDateAndHasStableSameDayOrder() {
        var older = Draft(kind: .diary); older.title = "A"; older.remoteSHA = "old"; older.date = Date(timeIntervalSince1970: 100); older.updatedAt = .distantFuture; older.pinnedAt = Date()
        var newer = Draft(kind: .diary); newer.title = "B"; newer.remoteSHA = "new"; newer.date = Date(timeIntervalSince1970: 200); newer.updatedAt = .distantPast
        XCTAssertEqual(ArticleLibrary.items([older, newer], shelf: .published).map(\.id), [newer.id, older.id])
        XCTAssertEqual(ArticleLibrary.items([older, newer], shelf: .published, publishedSort: .oldest).map(\.id), [older.id, newer.id])
        XCTAssertEqual(ArticleLibrary.items([older, newer], shelf: .published, publishedSort: .recentlyEdited).first?.id, older.id)
        XCTAssertEqual(ArticleLibrary.items([older, newer], shelf: .published, publishedSort: .title).first?.id, older.id)
        XCTAssertEqual(ArticleLibrary.items([older, newer], shelf: .published, publishedSort: .pinned).first?.id, older.id)
        older.date = newer.date
        let before = ArticleLibrary.items([older, newer], shelf: .published).map(\.id)
        newer.updatedAt = Date(); older.updatedAt = .distantPast
        XCTAssertEqual(ArticleLibrary.items([older, newer], shelf: .published).map(\.id), before)
    }
    private var importedMarkdown: String {
        "---\ntitle: \"昔の記事\"\ndescription: \"説明\"\ndate: 2026-01-26\ntags:\n  - \"曲紹介\"\ncategory: \"music\"\ncustom: keep-this\n---\n\n### 曲\n\n<iframe src=\"https://open.spotify.com/embed/album/0123456789ABCDEFGHIJKL?utm_source=generator\" width=\"60%\" height=\"352\"></iframe>\n\n本文🎵\n"
    }
    private func imported(_ sha: String = "old") throws -> Draft {
        try RepositoryArticleMarkdown.decode(path: "src/content/diary/2026-01-26.md", sha: sha, markdown: importedMarkdown)
    }
    private func fixturePublisher(_ scenario: String) -> GitHubPublisher {
        GitHubFixtureProtocol.reset(scenario)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubFixtureProtocol.self]
        return GitHubPublisher(configuration: .fixture, session: URLSession(configuration: config))
    }
    func testImportPreservesExactMarkdownUnknownMetadataAndSpotify() throws {
        var draft = try imported()
        XCTAssertEqual(draft.markdown, importedMarkdown)
        XCTAssertEqual(draft.kind, .music); XCTAssertNil(draft.validation)
        XCTAssertTrue(draft.isPublished); XCTAssertFalse(draft.hasUnpublishedEdits)
        XCTAssertEqual(draft.filename, "2026-01-26.md")
        XCTAssertEqual(try imported("new").id, draft.id)
        draft.title = "修正したタイトル"; draft.body += "追加した本文\n"
        XCTAssertTrue(draft.hasUnpublishedEdits)
        XCTAssertTrue(draft.markdown.contains("category: \"music\"\ncustom: keep-this"))
        XCTAssertTrue(draft.markdown.contains("utm_source=generator\" width=\"60%\""))
        XCTAssertEqual(draft.path, "src/content/diary/2026-01-26.md")
        let html = BlogPreviewHTML.document(draft, configuration: .fixture)
        XCTAssertTrue(html.contains("src=\"https://open.spotify.com/embed/album/0123456789ABCDEFGHIJKL\""))
        XCTAssertFalse(html.contains("utm_source"))
    }
    func testImportHandlesInlineTagsCRLFAndStableAppIdentifiers() throws {
        let id = UUID()
        let source = "---\r\ntitle: '日本語の記事'\r\ndescription: simple\r\ndate: 2026-10-03\r\ntags: [日記, '気づき']\r\n---\r\n\r\n本文\r\n"
        let draft = try RepositoryArticleMarkdown.decode(path: "src/content/diary/ios-\(id.uuidString.lowercased()).md", sha: "old", markdown: source)
        XCTAssertEqual(draft.id, id); XCTAssertEqual(draft.tags, "日記, 気づき")
        XCTAssertEqual(draft.markdown, source)
        XCTAssertThrowsError(try RepositoryArticleMarkdown.decode(path: "src/content/diary/../config.md", sha: "old", markdown: source))
        XCTAssertFalse(RepositoryArticleMarkdown.validPath("README.md"))
    }
    @MainActor func testRepositoryRefreshProtectsEditsAndPreservesLocalNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drafts.json"); let store = DraftStore(url: url)
        let original = try imported(); XCTAssertTrue(store.mergePublishedArticles([original]))
        XCTAssertTrue(store.mergePublishedArticles([original])); XCTAssertEqual(store.drafts.count, 1)
        var edited = original; edited.body += "端末で編集中\n"; XCTAssertTrue(store.update(edited))
        let latest = try RepositoryArticleMarkdown.decode(path: original.path, sha: "new", markdown: importedMarkdown.replacingOccurrences(of: "本文🎵", with: "GitHubの変更"))
        XCTAssertTrue(store.mergePublishedArticles([latest]))
        XCTAssertEqual(store.drafts.first?.body, edited.body); XCTAssertEqual(store.drafts.first?.remoteSHA, "old")
        XCTAssertEqual(store.drafts.first?.remoteChanged, true)
        let loaded = try XCTUnwrap(store.keepEditsAndLoadLatest(latest))
        XCTAssertEqual(loaded.remoteSHA, "new"); XCTAssertEqual(loaded.body, latest.body)
        let backup = try XCTUnwrap(store.drafts.first { !$0.isPublished })
        XCTAssertEqual(backup.body, edited.body); XCTAssertNil(backup.repositoryPath); XCTAssertNotEqual(backup.path, loaded.path)
        XCTAssertEqual(DraftStore(url: url).drafts.count, 2)
        XCTAssertTrue(store.mergePublishedArticles([]))
        XCTAssertTrue(store.drafts.allSatisfy { !$0.isPublished }); XCTAssertEqual(store.drafts.count, 2)
    }
    @MainActor func testPendingRemoteDeletionSurvivesRestartAndKeepsBody() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drafts.json"); let store = DraftStore(url: url)
        let article = try imported(); XCTAssertTrue(store.update(article))
        let snapshot = try XCTUnwrap(store.beginRemoteDeletion(article.id))
        XCTAssertEqual(snapshot.pendingDeletionSHA, "old")
        XCTAssertTrue(snapshot.isPublished); XCTAssertEqual(ArticleLibrary.items(store.drafts, shelf: .published).count, 1)
        XCTAssertEqual(DraftStore(url: url).drafts.first?.pendingDeletionSHA, "old")
        XCTAssertFalse(store.moveToTrash([article.id])); XCTAssertNil(store.duplicate(article.id))
        XCTAssertTrue(store.mergePublishedArticles([])); XCTAssertEqual(store.drafts.first?.remoteSHA, "old")
        XCTAssertFalse(store.finishRemoteDeletion(article.id, expectedSHA: "wrong", commitURL: nil))
        XCTAssertTrue(store.finishRemoteDeletion(article.id, expectedSHA: "old", commitURL: "https://github.com/delete"))
        let restored = try XCTUnwrap(DraftStore(url: url).drafts.first)
        XCTAssertNil(restored.remoteSHA); XCTAssertNil(restored.pendingDeletionSHA); XCTAssertFalse(restored.isPublished)
        XCTAssertEqual(restored.markdown, article.markdown); XCTAssertEqual(restored.path, article.path)
    }
    @MainActor func testRefreshDiscoversExternallyPublishedDraftAndKeepsItsLocalText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DraftStore(url: folder.appendingPathComponent("drafts.json"))
        let remote = try imported()
        var local = remote; local.remoteSHA = nil; local.body += "端末だけの書きかけ\n"
        XCTAssertTrue(store.update(local)); XCTAssertTrue(store.mergePublishedArticles([remote]))
        XCTAssertEqual(ArticleLibrary.items(store.drafts, shelf: .published).count, 1)
        let kept = try XCTUnwrap(ArticleLibrary.items(store.drafts, shelf: .drafts).first)
        XCTAssertEqual(kept.body, local.body); XCTAssertNotEqual(kept.path, remote.path)
    }
    @MainActor func testFailedLocalSavePreventsBeginningRemoteDeletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("blocked"); try Data("not a folder".utf8).write(to: blocker)
        let store = DraftStore(url: blocker.appendingPathComponent("drafts.json")); let article = try imported()
        XCTAssertFalse(store.update(article)); XCTAssertNil(store.beginRemoteDeletion(article.id))
        XCTAssertNil(store.drafts.first?.pendingDeletionSHA)
    }
    func testDeleteUsesExactPathSHAAndMainBranch() async throws {
        let publisher = fixturePublisher("delete-success")
        var draft = try imported(); draft.pendingDeletionSHA = "old"
        let result = try await publisher.deletePublished(draft, token: "delete-success")
        XCTAssertEqual(result, "https://github.com/delete-commit")
        XCTAssertEqual(GitHubFixtureProtocol.methods("delete-success"), ["GET", "DELETE"])
    }
    func testChangedRemoteArticleCannotBeDeletedOrPublishedWhileDeletionPending() async throws {
        let publisher = fixturePublisher("delete-changed")
        var draft = try imported(); draft.pendingDeletionSHA = "old"
        do { _ = try await publisher.deletePublished(draft, token: "delete-changed"); XCTFail("Should reject changed file") }
        catch { XCTAssertTrue(error is GitHubPublisher.DeletionError) }
        draft.pendingMarkdown = "edited"
        do { _ = try await publisher.publish(draft, token: "delete-changed"); XCTFail("Should block publish") } catch { }
        XCTAssertEqual(GitHubFixtureProtocol.methods("delete-changed"), ["GET"])
    }
    func testLostDeleteResponseReconcilesAbsenceWithoutSecondDelete() async throws {
        let publisher = fixturePublisher("delete-lost-response")
        var draft = try imported(); draft.pendingDeletionSHA = "old"
        let result = try await publisher.deletePublished(draft, token: "delete-lost-response")
        XCTAssertNil(result)
        XCTAssertEqual(GitHubFixtureProtocol.methods("delete-lost-response"), ["GET", "DELETE", "GET", "GET"])
    }
    func testMissingAccessDoesNotLookLikeSuccessfulDeletion() async throws {
        let publisher = fixturePublisher("delete-hidden-repository")
        var draft = try imported(); draft.pendingDeletionSHA = "old"
        do { _ = try await publisher.deletePublished(draft, token: "delete-hidden-repository"); XCTFail("Hidden repo is not confirmed deleted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("アクセス")) }
        XCTAssertEqual(GitHubFixtureProtocol.methods("delete-hidden-repository"), ["GET", "GET"])
    }
    func testUncertainDeletionPreservesRetryState() async throws {
        let publisher = fixturePublisher("delete-offline")
        var draft = try imported(); draft.pendingDeletionSHA = "old"
        do { _ = try await publisher.deletePublished(draft, token: "delete-offline"); XCTFail("Offline check is not success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("確定できません")) }
        XCTAssertEqual(draft.pendingDeletionSHA, "old")
    }
    func testImportReadsAllMarkdownBlobsFromOneRepositorySnapshot() async throws {
        let publisher = fixturePublisher("import")
        let articles = try await publisher.publishedArticles(token: "import")
        XCTAssertEqual(articles.map(\.filename), ["first.md", "second.md"])
        XCTAssertTrue(articles.allSatisfy { $0.isPublished })
        XCTAssertEqual(articles.first?.remoteSHA, String(repeating: "a", count: 40))
        XCTAssertEqual(GitHubFixtureProtocol.methods("import"), ["GET", "GET", "GET"])
    }
    func testEditedImportedArticleUpdatesExistingFileInsteadOfCreatingUUIDFile() async throws {
        let publisher = fixturePublisher("edit-existing")
        var draft = try imported(); draft.title = "変更した記事"; draft.pendingMarkdown = draft.markdown
        let result = try await publisher.publish(draft, token: "edit-existing")
        XCTAssertEqual(result.sha, "updated")
        XCTAssertEqual(GitHubFixtureProtocol.methods("edit-existing"), ["GET", "PUT"])
    }
}

private final class GitHubFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [String: [URLRequest]] = [:]
    static func reset(_ key: String) { lock.lock(); defer { lock.unlock() }; requests[key] = [] }
    static func methods(_ key: String) -> [String] { lock.lock(); defer { lock.unlock() }; return requests[key, default: []].map { $0.httpMethod ?? "GET" } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func body() -> [String: String] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        Self.lock.lock(); let number = Self.requests[key, default: []].count; Self.requests[key, default: []].append(request); Self.lock.unlock()
        let method = request.httpMethod ?? "GET", url = request.url!
        XCTAssertEqual(url.host, "api.github.com")
        var status = 200
        var payload: [String: Any] = ["sha": "old", "encoding": "base64", "content": Data("original".utf8).base64EncodedString()]
        if key == "import" {
            let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
            if url.path.contains("/git/trees/") {
                payload = ["truncated": false, "tree": [
                    ["path": "src/content/diary/first.md", "type": "blob", "sha": a],
                    ["path": "src/content/diary/second.md", "type": "blob", "sha": b],
                    ["path": "src/content/config.ts", "type": "blob", "sha": a]]]
            } else {
                XCTAssertTrue(url.path.hasSuffix(a) || url.path.hasSuffix(b))
                let md = "---\ntitle: \"記事\"\ndescription: \"説明\"\ndate: 2026-01-22\ntags: [\"日記\"]\n---\n\n本文\n"
                payload = ["sha": url.path.hasSuffix(a) ? a : b, "encoding": "base64", "content": Data(md.utf8).base64EncodedString()]
            }
        } else if url.path.hasSuffix("/branches/main") {
            status = key == "delete-hidden-repository" ? 404 : 200; payload = ["name": "main"]
        } else {
            XCTAssertEqual(url.path, "/repos/example/my-journal/contents/src/content/diary/2026-01-26.md")
            if method == "DELETE" || method == "PUT" {
                let values = body(); XCTAssertEqual(values["sha"], "old"); XCTAssertEqual(values["branch"], "main")
                if key == "delete-lost-response" || key == "delete-offline" {
                    client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
                }
                if method == "PUT" {
                    let markdown = String(data: Data(base64Encoded: values["content"] ?? "") ?? Data(), encoding: .utf8) ?? ""
                    XCTAssertTrue(markdown.contains("変更した記事")); XCTAssertTrue(markdown.contains("custom: keep-this"))
                    payload = ["content": ["sha": "updated"], "commit": ["html_url": "https://github.com/update-commit"]]
                } else { payload = ["content": NSNull(), "commit": ["html_url": "https://github.com/delete-commit"]] }
            } else {
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "main")
                if key == "delete-changed" { payload["sha"] = "changed" }
                if key == "delete-hidden-repository" || (key == "delete-lost-response" && number > 0) { status = 404 }
                if key == "delete-offline" && number > 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class JapaneseMusicFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        var text = ""
        switch (url.host ?? "", url.path) {
        case ("song.link", _):
            let loop = url.path.contains("RFTl5AJdBZc")
            let indie = url.path.contains("PL9-6rClgXs")
            let entity: [String: Any] = ["provider": "youtube", "id": indie ? "PL9-6rClgXs" : loop ? "RFTl5AJdBZc" : "vYo-hpzuS2c", "title": indie ? "明るい未来" : loop ? "Loop & Loop" : "茜色の夕日", "artistName": indie ? "never young beach" : loop ? "ASIAN KUNG-FU GENERATION" : "フジファブリック", "duration": loop ? 227000 : 339000]
            let object: [String: Any] = ["props": ["pageProps": ["pageData": ["entityData": entity, "sections": []]]]]
            text = "<script id=\"__NEXT_DATA__\">" + String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "</script>"
        case ("musicbrainz.org", "/ws/2/recording"):
            if value("query").contains("明るい未来") {
                text = #"{"recordings":[{"title":"明るい未来","artist-credit":[{"name":"never young beach","artist":{"id":"indie","name":"never young beach"}}],"releases":[{"release-group":{"id":"indie"}}]}]}"#
            } else if value("query").contains("茜色") {
                // Strict artist search misses the localized credit; title-only search finds its aliases.
                text = value("query").contains(" AND ") ? #"{"recordings":[]}"# : #"{"recordings":[{"title":"茜色の夕日","length":339000,"artist-credit":[{"name":"Fujifabric","artist":{"name":"Fujifabric","aliases":[{"name":"フジファブリック"}]}}],"releases":[{"release-group":{"id":"broken"}},{"release-group":{"id":"fujifabric"}}]}]}"#
            } else if value("query").contains("ループ") {
                text = #"{"recordings":[{"title":"ループ&ループ","artist-credit":[{"name":"ASIAN KUNG-FU GENERATION"}],"releases":[{"release-group":{"id":"loop"}}]}]}"#
            } else { text = #"{"recordings":[]}"# }
        case ("musicbrainz.org", "/ws/2/release"):
            if value("release-group") == "broken" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
            if value("release-group") == "indie" { text = #"{"releases":[]}"#; break }
            let album = value("release-group") == "loop" ? "1wXO8XMYLvkOjctIpbZrII" : "0IyU3nxsBtuYvvGRnJeg4M"
            text = "{\"releases\":[{\"relations\":[{\"url\":{\"resource\":\"https://open.spotify.com/album/\(album)\"}}]}]}"
        case ("musicbrainz.org", "/ws/2/artist/indie"):
            text = #"{"id":"indie","name":"never young beach","relations":[{"url":{"resource":"https://open.spotify.com/artist/2YtvgEYiTH6jh7n2UmUdXX"}}]}"#
        case ("open.spotify.com", "/artist/2YtvgEYiTH6jh7n2UmUdXX"):
            text = #"<script type="application/ld+json">{"@type":"MusicGroup","name":"never young beach"}</script><a href="/album/1bW2uDVWI51ttFReQYFWQ0">fam fam</a>"#
        case ("open.spotify.com", "/album/1bW2uDVWI51ttFReQYFWQ0"):
            text = #"<meta property="og:title" content="fam fam"><a href="/track/5Gbgx64AeuCcXIFys7ymqK">明るい未来</a>"#
        case ("open.spotify.com", "/track/5Gbgx64AeuCcXIFys7ymqK"):
            text = #"<meta property="og:type" content="music.song"><meta property="og:title" content="明るい未来"><meta property="og:description" content="never young beach · fam fam · Song · 2016">"#
        case ("itunes.apple.com", "/search"):
            text = #"{"results":[{"trackId":1536394890,"trackName":"Loop & Loop","artistName":"ASIAN KUNG-FU GENERATION"}]}"#
        case ("itunes.apple.com", "/lookup"):
            XCTAssertEqual(value("id"), "1536394890")
            text = #"{"results":[{"trackId":1536394890,"trackName":"ループ&ループ","artistName":"ASIAN KUNG-FU GENERATION"}]}"#
        case ("open.spotify.com", "/album/1wXO8XMYLvkOjctIpbZrII"):
            text = #"<meta property="og:title" content="ループ＆ループ"><a href="/track/19mAWClvP2t0JzctutaM0t">ループ＆ループ</a>"#
        case ("open.spotify.com", "/album/0IyU3nxsBtuYvvGRnJeg4M"):
            text = #"<meta property="og:title" content="FAB FOX"><a href="/track/2p8ji4NXTvYvAIRnK2d1kH">茜色の夕日</a><a href="/track/3ZLVWWt6XwuCg95b45BG4N">茜色の夕日 (Remastered 2019)</a><a href="/track/0123456789ABCDEFGHIJKL">若者のすべて</a>"#
        case ("open.spotify.com", _):
            let loop = url.path.contains("19mAWClvP2t0JzctutaM0t")
            let title = loop ? "ループ＆ループ" : url.path.contains("3ZLVWW") ? "茜色の夕日 (Remastered 2019)" : "茜色の夕日"
            text = "<meta property=\"og:type\" content=\"music.song\"><meta property=\"og:title\" content=\"\(title)\"><meta property=\"og:description\" content=\"\(loop ? "ASIAN KUNG-FU GENERATION" : "Fujifabric") · Song\">"
        default: client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class MusicFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let text: String
        switch (url.host ?? "", url.path) {
        case ("song.link", _):
            text = #"<script id="__NEXT_DATA__">{"props":{"pageProps":{"pageData":{"entityData":{"provider":"youtube","id":"YykjpeuMNEk","title":"Hymn for the Weekend (feat. Beyoncé)","artistName":"Coldplay","duration":261000},"sections":[]}}}}</script>"#
        case ("musicbrainz.org", "/ws/2/recording"):
            text = #"{"recordings":[{"title":"Hymn for the Weekend","length":259001,"artist-credit":[{"name":"Coldplay"}],"releases":[{"release-group":{"id":"compilation-1","secondary-types":["Compilation"]}},{"release-group":{"id":"compilation-2","secondary-types":["Compilation"]}},{"release-group":{"id":"compilation-3","secondary-types":["Compilation"]}},{"release-group":{"id":"27da3ef8-f3b0-47bf-898d-9bdf4af7fc04","secondary-types":[]}}]}]}"#
        case ("musicbrainz.org", "/ws/2/release"):
            let group = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "release-group" })?.value
            text = group == "27da3ef8-f3b0-47bf-898d-9bdf4af7fc04" ? #"{"releases":[{"relations":[{"url":{"resource":"https://open.spotify.com/album/3cfAM8b8KqJRoIzt3zLKqw"}}]}]}"# : #"{"releases":[]}"#
        case ("open.spotify.com", "/album/3cfAM8b8KqJRoIzt3zLKqw"):
            text = #"<meta property="og:title" content="A Head Full of Dreams"><a href="/track/3RiPr603aXAoi4GHyXx0uy">Hymn for the Weekend</a>"#
        case ("open.spotify.com", "/track/3RiPr603aXAoi4GHyXx0uy"):
            text = #"<meta property="og:title" content="Hymn for the Weekend"><meta property="og:description" content="Coldplay · A Head Full of Dreams · Song · 2015"><meta property="og:type" content="music.song">"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


extension SiteConfiguration {
    static var fixture: SiteConfiguration {
        SiteConfiguration(owner: "example", repository: "my-journal", branch: "main", website: "https://example.github.io/my-journal/", title: "My Journal", tagline: "日々の記録")
    }
}

final class SiteConfigurationTests: XCTestCase {
    func testContentsListingAndDeletionUseConfiguredRepositoryAndSlashBranch() async throws {
        var site = SiteConfiguration.fixture
        site.owner = "another-user"; site.repository = "journal"; site.branch = "publish/blog"
        DestinationFixture.reset()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [DestinationFixture.self]
        let publisher = GitHubPublisher(configuration: site, session: URLSession(configuration: session))
        var draft = Draft(kind: .diary)
        draft.title = "Title"; draft.description = "Description"; draft.pendingMarkdown = draft.markdown
        let result = try await publisher.publish(draft, token: "fixture")
        XCTAssertEqual(result.sha, "saved")
        let articles = try await publisher.publishedArticles(token: "fixture")
        XCTAssertTrue(articles.isEmpty)
        draft.remoteSHA = result.sha; draft.pendingMarkdown = nil; draft.pendingDeletionSHA = result.sha
        let deleted = try await publisher.deletePublished(draft, token: "fixture")
        XCTAssertEqual(deleted, "https://github.com/example/commit")
        XCTAssertEqual(DestinationFixture.count, 5)
    }
    func testMissingDestinationStopsBeforeSendingToken() async {
        DestinationFixture.reset()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [DestinationFixture.self]
        let publisher = GitHubPublisher(configuration: SiteConfiguration(), session: URLSession(configuration: session))
        var draft = Draft(kind: .diary); draft.pendingMarkdown = "draft"
        do { _ = try await publisher.publish(draft, token: "fixture"); XCTFail("Expected missing destination error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("公開先")) }
        XCTAssertEqual(DestinationFixture.count, 0)
    }
    func testProjectSiteKeepsRepositoryBasePathAndCustomDomainUsesRoot() throws {
        let image = "/images/diary/12345678-1234-1234-1234-123456789abc/" + String(repeating: "a", count: 64) + ".jpg"
        XCTAssertEqual(SiteConfiguration.fixture.publicAssetURL(for: image)?.absoluteString, "https://example.github.io/my-journal" + image)
        var custom = SiteConfiguration.fixture; custom.website = "https://journal.example.org/"
        XCTAssertEqual(custom.publicAssetURL(for: image)?.absoluteString, "https://journal.example.org" + image)
        XCTAssertNil(custom.publicAssetURL(for: "/images/diary/../../file.jpg"))
        var value = SiteConfiguration.fixture; value.website = " https://example.github.io/my-journal "
        XCTAssertEqual(try value.normalized().website, "https://example.github.io/my-journal/")
    }
    func testRejectsInvalidDestinations() {
        for owner in ["", "../other", "person@evil", "a/b"] {
            var value = SiteConfiguration.fixture; value.owner = owner
            XCTAssertThrowsError(try value.normalized())
        }
        for branch in ["", "../main", "main?evil", "a//b", "a.lock", "main."] {
            var value = SiteConfiguration.fixture; value.branch = branch
            XCTAssertThrowsError(try value.normalized())
        }
        for website in ["http://example.org", "https://user@example.org/", "https://example.org/?a=b", "https://example.org/#frag", "https://example.org/../else/"] {
            var value = SiteConfiguration.fixture; value.website = website
            XCTAssertThrowsError(try value.normalized())
        }
        var branch = SiteConfiguration.fixture; branch.branch = "publish/blog"
        XCTAssertNoThrow(try branch.normalized())
    }
    @MainActor func testSettingsPersistAndLockDestinationDuringRequestsAndForConnectedDrafts() throws {
        let name = "cocoWriterTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        // Populate connection preferences without touching a real Keychain token.
        defaults.set(try JSONEncoder().encode(SiteConfiguration.fixture), forKey: SiteConfiguration.defaultsKey)
        let store = DraftStore(url: root.appendingPathComponent("drafts.json"), preferences: defaults)
        var settings = SiteConfiguration.fixture; settings.title = "New title"
        try store.saveSiteConfiguration(settings)
        XCTAssertEqual(SiteConfiguration.load(from: defaults).title, "New title")
        var other = settings; other.repository = "another-blog"
        store.beginRemoteOperation()
        XCTAssertThrowsError(try store.saveSiteConfiguration(other))
        store.endRemoteOperation()
        var pending = Draft(kind: .diary); pending.pendingMarkdown = "pending"
        XCTAssertTrue(store.update(pending))
        XCTAssertThrowsError(try store.saveSiteConfiguration(other))
        pending.pendingMarkdown = nil; pending.remoteDestination = settings.destinationID
        XCTAssertTrue(store.update(pending))
        XCTAssertThrowsError(try store.saveSiteConfiguration(other))
        settings.website = "https://custom.example.org/"
        XCTAssertNoThrow(try store.saveSiteConfiguration(settings))
    }
    func testCrossDestinationPublishIsRejectedBeforeNetwork() async {
        var draft = Draft(kind: .diary); draft.remoteDestination = "other/blog@main"; draft.pendingMarkdown = "draft"
        do {
            _ = try await GitHubPublisher(configuration: .fixture).publish(draft, token: "fixture")
            XCTFail("Cross-destination publication should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("別の投稿先")) }
    }
}

private final class DestinationFixture: URLProtocol {
    private static let lock = NSLock()
    private static var saved = false
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); defer { lock.unlock() }; saved = false; requests = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.requests += 1
        let url = request.url!
        XCTAssertEqual(url.host, "api.github.com")
        XCTAssertTrue(url.path.hasPrefix("/repos/another-user/journal/"))
        var status = 200
        var payload: [String: Any] = [:]
        if url.path == "/repos/another-user/journal/git/trees/publish/blog" {
            XCTAssertTrue(url.absoluteString.contains("publish%2Fblog"))
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "1")
            payload = ["tree": [], "truncated": false]
        } else if request.httpMethod == "GET" {
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "publish/blog")
            status = Self.saved ? 200 : 404
            payload = ["sha": "saved"]
        } else {
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream, bytes.isEmpty {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            XCTAssertEqual(body["branch"] as? String, "publish/blog")
            if request.httpMethod == "PUT" {
                Self.saved = true; status = 201
                payload = ["content": ["sha": "saved"], "commit": ["html_url": "https://github.com/example/commit"]]
            } else {
                XCTAssertEqual(request.httpMethod, "DELETE"); XCTAssertEqual(body["sha"] as? String, "saved")
                payload = ["commit": ["html_url": "https://github.com/example/commit"]]
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MultiServiceMusicFixture: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [String: Int] = [:]
    static func count(for url: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests[url, default: 0] }
    static func songlink(provider: String, id: String, title: String = "Selfless", type: String = "song") -> String {
        "<script id=\"__NEXT_DATA__\">" + "{\"props\":{\"pageProps\":{\"pageData\":{\"entityData\":{\"provider\":\"\(provider)\",\"id\":\"\(id)\",\"type\":\"\(type)\",\"title\":\"\(title)\",\"artistName\":\"The Strokes\"},\"sections\":[{\"links\":[{\"platform\":\"spotify\",\"url\":\"https://open.spotify.com/track/0123456789ABCDEFGHIJKL\"},{\"platform\":\"spotify\",\"url\":\"https://open.spotify.com/album/0123456789ABCDEFGHIJKL\"}]}]}}}}" + "</script>"
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, host = url.host!, id = url.lastPathComponent
        Self.lock.lock(); Self.requests[url.absoluteString, default: 0] += 1; Self.lock.unlock()
        var final = url, status = 200, text = ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        if ["apple.co", "amzn.to"].contains(host) {
            switch id {
            case "good123": final = URL(string: "https://music.apple.com/us/song/1053934844")!
            case "cross123": final = URL(string: "https://music.amazon.com/tracks/B084KPC3Q7")!
            case "album123": final = URL(string: "https://music.amazon.com/albums/B084KP4NBH")!
            default: final = URL(string: "https://evil.example/song")!
            }
        } else if host == "song.link" {
            if ["1053934844", "B084KPC3Q7", "10539348440"].contains(id) {
                let provider = url.path.hasPrefix("/i/") ? "itunes" : url.path.hasPrefix("/y/") ? "youtube" : "amazon"
                text = Self.songlink(provider: provider, id: id, title: id == "10539348440" ? (provider == "youtube" ? "YouTube Song" : "Apple Song") : "Selfless")
            } else if id == "222" { text = Self.songlink(provider: "itunes", id: id, type: "album") }
            else { status = 503 }
        } else if host == "itunes.apple.com" {
            text = value("id") == "222" ? "{\"results\":[{\"kind\":\"song\",\"trackId\":222,\"trackName\":\"Lookup \(value("country").uppercased())\",\"artistName\":\"Artist\"}]}" : "{\"results\":[]}"
        } else if host == "music.apple.com" || SharedMusicLink.amazonHosts.contains(host) {
            if ["333", "B000PUBLIC"].contains(id) {
                text = "<script type='application/ld+json'>{\"@type\":\"MusicRecording\",\"url\":\"\(url.absoluteString)\",\"name\":\"Public Song\",\"byArtist\":{\"name\":\"Public Artist\"}}</script>"
            } else if id == "B000REDIR1" { final = URL(string: "https://music.amazon.com/tracks/B084KPC3Q7")! }
            else { text = "<html>Sign in</html>" }
        } else if host == "open.spotify.com" {
            text = #"<meta property="og:title" content="Selfless"><meta property="og:description" content="The Strokes · Album · Song · 2020"><meta property="og:type" content="music.song">"#
        } else if host == "musicbrainz.org" {
            text = url.path == "/ws/2/artist" ? "{\"artists\":[]}" : "{\"recordings\":[]}"
        } else { status = 503 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: final, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
