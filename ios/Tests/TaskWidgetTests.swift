import XCTest
@testable import cocoWriter

@MainActor final class TaskWidgetTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func task(_ title: String, due: Date? = nil, created: Date = Date()) -> PrivateNote {
        var note = PrivateNote(); note.body = title; note.date = created; note.task = NoteTask(dueDate: due)
        return note
    }
    func testOrderPlacesUndatedLastAndUsesStableCreationOrder() {
        let now = Date()
        let a = WidgetTask(id: UUID(), title: "期限なし", createdAt: now, updatedAt: now)
        let b = WidgetTask(id: UUID(), title: "明日", dueDate: now.addingTimeInterval(86400), createdAt: now.addingTimeInterval(1), updatedAt: now)
        let c = WidgetTask(id: UUID(), title: "今日", dueDate: now, createdAt: now.addingTimeInterval(2), updatedAt: now)
        XCTAssertEqual(WidgetTaskOrder.deadline.sorted([a,b,c]).map(\.id), [c.id,b.id,a.id])
        XCTAssertEqual(WidgetTaskOrder.oldest.sorted([a,b,c]).map(\.id), [a.id,b.id,c.id])
        XCTAssertEqual(WidgetTaskOrder.newest.sorted([a,b,c]).map(\.id), [c.id,b.id,a.id])
    }
    func testProjectionExcludesPrivateMemoCompletedTrashAndTags() throws {
        let root = try workspace(), shared = root.appendingPathComponent("widget")
        let url = root.appendingPathComponent("notes.json")
        var pending = task("買い物 #生活\n非表示にしたい本文")
        pending.title = ""
        var done = task("完了済み"); done.task?.completedAt = Date()
        var trash = task("ゴミ箱"); trash.deletedAt = Date()
        var memo = PrivateNote(); memo.body = "普通の秘密のメモ"
        try JSONEncoder().encode([pending, done, trash, memo]).write(to: url)
        let store = PrivateNoteStore(url: url, widgetDirectory: shared)
        XCTAssertTrue(store.loaded)
        let snapshot = try TaskWidgetData.read(from: shared)
        XCTAssertEqual(snapshot.tasks.map(\.id), [pending.id])
        XCTAssertEqual(snapshot.tasks.first?.title, "買い物")
        let data = try String(contentsOf: shared.appendingPathComponent("tasks.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("非表示")); XCTAssertFalse(data.contains("秘密")); XCTAssertFalse(data.contains("生活"))
    }
    func testCompletionSurvivesAppRestartAndRepeatedCheckDoesNotReopenTask() throws {
        let root = try workspace(), shared = root.appendingPathComponent("widget"), url = root.appendingPathComponent("notes.json")
        let store = PrivateNoteStore(url: url, widgetDirectory: shared)
        XCTAssertTrue(store.addEntry(body: "提出", task: NoteTask()))
        let value = try XCTUnwrap(TaskWidgetData.read(from: shared).tasks.first)
        try TaskWidgetData.complete(value, in: shared)
        try TaskWidgetData.complete(value, in: shared)
        XCTAssertTrue(try TaskWidgetData.read(from: shared).tasks.isEmpty)
        let reopened = PrivateNoteStore(url: url, widgetDirectory: shared)
        XCTAssertTrue(try XCTUnwrap(reopened.notes.first?.task).isCompleted)
        let completed = reopened.notes.first?.task?.completedAt
        reopened.synchronizeWidget()
        XCTAssertEqual(reopened.notes.first?.task?.completedAt, completed)
        XCTAssertTrue(try TaskWidgetData.completions(in: shared).isEmpty)
        XCTAssertTrue(try TaskWidgetData.read(from: shared).tasks.isEmpty)
    }
    func testStaleCompletionCannotCompleteEditedOrReopenedTask() throws {
        let root = try workspace(), shared = root.appendingPathComponent("widget"), url = root.appendingPathComponent("notes.json")
        let store = PrivateNoteStore(url: url, widgetDirectory: shared)
        XCTAssertTrue(store.addEntry(body: "旧タスク", task: NoteTask()))
        let old = try XCTUnwrap(TaskWidgetData.read(from: shared).tasks.first)
        var edited = try XCTUnwrap(store.notes.first); edited.body = "変更後"
        XCTAssertTrue(store.update(edited))
        try TaskWidgetData.complete(old, in: shared)
        store.synchronizeWidget()
        XCTAssertEqual(store.notes.first?.task?.isCompleted, false)
        XCTAssertEqual(try TaskWidgetData.read(from: shared).tasks.first?.title, "変更後")
        let current = try XCTUnwrap(TaskWidgetData.read(from: shared).tasks.first)
        XCTAssertTrue(store.toggleTask(current.id))
        XCTAssertTrue(store.toggleTask(current.id))
        try TaskWidgetData.complete(current, in: shared)
        store.synchronizeWidget()
        XCTAssertEqual(store.notes.first?.task?.isCompleted, false)
    }
    func testDeletedTaskIsNotRestoredByWidgetCommand() throws {
        let root = try workspace(), shared = root.appendingPathComponent("widget"), url = root.appendingPathComponent("notes.json")
        let store = PrivateNoteStore(url: url, widgetDirectory: shared)
        XCTAssertTrue(store.addEntry(body: "削除予定", task: NoteTask()))
        let value = try XCTUnwrap(TaskWidgetData.read(from: shared).tasks.first)
        XCTAssertTrue(store.moveToTrash([value.id]))
        try TaskWidgetData.complete(value, in: shared)
        store.synchronizeWidget()
        XCTAssertNotNil(store.notes.first?.deletedAt)
        XCTAssertEqual(store.notes.first?.task?.isCompleted, false)
        XCTAssertTrue(try TaskWidgetData.read(from: shared).tasks.isEmpty)
    }
    func testFailedSaveRetainsCompletionForRetry() throws {
        let root = try workspace(), shared = root.appendingPathComponent("widget"), url = root.appendingPathComponent("notes.json")
        let store = PrivateNoteStore(url: url, widgetDirectory: shared)
        XCTAssertTrue(store.addEntry(body: "提出", task: NoteTask()))
        let value = try XCTUnwrap(TaskWidgetData.read(from: shared).tasks.first)
        try TaskWidgetData.complete(value, in: shared)
        let original = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.synchronizeWidget()
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(store.notes.first?.task?.isCompleted, false)
        XCTAssertEqual(try TaskWidgetData.completions(in: shared).count, 1)
        try FileManager.default.removeItem(at: url)
        try original.write(to: url)
        XCTAssertTrue(store.persist())
        store.synchronizeWidget()
        XCTAssertEqual(store.notes.first?.task?.isCompleted, true)
        XCTAssertTrue(try TaskWidgetData.completions(in: shared).isEmpty)
    }
    func testUnchangedEditorSaveDoesNotInvalidatePendingWidgetCompletion() throws {
        let root = try workspace(), shared = root.appendingPathComponent("widget"), url = root.appendingPathComponent("notes.json")
        let store = PrivateNoteStore(url: url, widgetDirectory: shared)
        XCTAssertTrue(store.addEntry(body: "提出", task: NoteTask()))
        let editor = try XCTUnwrap(store.notes.first)
        let widget = try XCTUnwrap(TaskWidgetData.read(from: shared).tasks.first)
        try TaskWidgetData.complete(widget, in: shared)
        XCTAssertTrue(store.update(editor))
        XCTAssertEqual(store.notes.first?.updatedAt, editor.updatedAt)
        store.synchronizeWidget()
        XCTAssertEqual(store.notes.first?.task?.isCompleted, true)
    }
    func testOpenEditorMergesNewCompletionWithoutLosingTextOrDeadline() {
        var original = task("元の本文", due: Date())
        original.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        var editing = original; editing.body = "編集中の本文"
        var completed = original
        completed.task?.completedAt = Date(timeIntervalSinceReferenceDate: 200)
        completed.updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let merged = editing.synchronizingTaskCompletion(from: completed)
        XCTAssertEqual(merged.body, "編集中の本文")
        XCTAssertEqual(merged.task?.dueDate, editing.task?.dueDate)
        XCTAssertEqual(merged.task?.completedAt, completed.task?.completedAt)
        XCTAssertEqual(merged.synchronizingTaskCompletion(from: original), merged)
        var other = completed; other.id = UUID()
        XCTAssertEqual(editing.synchronizingTaskCompletion(from: other), editing)
    }
    func testCorruptOriginalNotesAreNeverReplacedByWidget() throws {
        let root = try workspace(), shared = root.appendingPathComponent("widget"), url = root.appendingPathComponent("notes.json")
        let original = Data("corrupt-original".utf8); try original.write(to: url)
        let store = PrivateNoteStore(url: url, widgetDirectory: shared)
        store.synchronizeWidget()
        XCTAssertFalse(store.loaded)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
    }
}
