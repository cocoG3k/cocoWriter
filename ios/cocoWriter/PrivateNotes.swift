import Foundation
import Combine

enum NoteKind: String, Codable, CaseIterable, Identifiable {
    case memo, journal
    var id: String { rawValue }
    var label: String { self == .memo ? "メモ" : "自分の日記" }
    var symbol: String { self == .memo ? "note.text" : "book.closed" }
}
struct PrivateNote: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: NoteKind = .memo
    var title = ""
    var body = ""
    var date = Date()
    var updatedAt = Date()
    var pinnedAt: Date?
    var deletedAt: Date?
    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return body.split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) } ?? "空のメモ"
    }
    var tags: [String] { NoteTags.extract(from: body) }
    var displayBody: String { NoteTags.removing(from: body) }
}

// Tags stay in the text, so existing saved notes need no schema migration.
enum NoteTags {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}_/#＃])[#＃]([\p{L}\p{M}\p{N}_\p{So}\p{Sk}\x{200D}\x{FE0F}]+)"#)

    static func key(_ tag: String) -> String { tag.precomposedStringWithCanonicalMapping.lowercased() }

    static func extract(from text: String) -> [String] {
        let source = text as NSString
        var seen = Set<String>()
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            let tag = source.substring(with: $0.range(at: 1))
            return seen.insert(key(tag)).inserted ? tag : nil
        }
    }

    static func removing(from text: String) -> String {
        text.components(separatedBy: "\n").compactMap { line -> String? in
            let source = line as NSString
            let matches = expression.matches(in: line, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { return line }
            let result = NSMutableString(string: line)
            for match in matches.reversed() {
                var start = match.range.location, end = NSMaxRange(match.range)
                while start > 0, result.substring(with: NSRange(location: start - 1, length: 1)).rangeOfCharacter(from: .whitespaces) != nil { start -= 1 }
                while end < result.length, result.substring(with: NSRange(location: end, length: 1)).rangeOfCharacter(from: .whitespaces) != nil { end += 1 }
                if start == 0 || end == result.length {
                    result.replaceCharacters(in: NSRange(location: start, length: end - start), with: "")
                } else if start < match.range.location && end > NSMaxRange(match.range) {
                    result.replaceCharacters(in: NSRange(location: start, length: end - start), with: " ")
                } else {
                    result.replaceCharacters(in: match.range, with: "")
                }
            }
            let cleaned = result as String
            return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cleaned
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appending(_ tag: String, to text: String) -> String {
        guard !extract(from: text).contains(where: { key($0) == key(tag) }) else { return text }
        if let last = text.last, last == "#" || last == "＃",
           text.count == 1 || text.dropLast().last?.isWhitespace == true { return text + tag + " " }
        return text + (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + "#" + tag + " "
    }

    static func insertingMarker(in text: String, at selection: NSRange) -> (text: String, selection: NSRange) {
        let range = Range(selection, in: text) ?? text.endIndex..<text.endIndex
        let before = text[..<range.lowerBound]
        let marker = before.isEmpty || before.last?.isWhitespace == true ? "#" : " #"
        let location = before.utf16.count + marker.utf16.count
        return (String(before) + marker + text[range.upperBound...], NSRange(location: location, length: 0))
    }

    static func selectionRange(_ selection: Range<String.Index>, in text: String) -> NSRange {
        // TextField may report selection indices from its previous text after focus/save.
        // Map them to actual character boundaries before Foundation dereferences them.
        let boundaries = Array(text.indices) + [text.endIndex]
        guard let lower = boundaries.first(where: { $0 == selection.lowerBound }),
              let upper = boundaries.first(where: { $0 == selection.upperBound }), lower <= upper else {
            return NSRange(location: text.utf16.count, length: 0)
        }
        return NSRange(lower..<upper, in: text)
    }
}

// This catalog controls navigation and suggestions only; tags in saved bodies stay intact.
struct NoteTagCatalog: Codable, Equatable {
    var order: [String] = []
    var hidden: [String] = []

    func visible(in notes: [PrivateNote]) -> [String] {
        let usedTags = PrivateNoteTimeline.tags(in: notes)
        let usedKeys = Set(usedTags.map(NoteTags.key))
        let hiddenKeys = Set(hidden.map(NoteTags.key))
        var seen = Set<String>()
        return (order + usedTags).filter {
            usedKeys.contains(NoteTags.key($0)) && !hiddenKeys.contains(NoteTags.key($0))
                && seen.insert(NoteTags.key($0)).inserted
        }
    }

    mutating func removeUnused(in notes: [PrivateNote]) {
        // Keep settings for trashed notes so restoring them preserves order and hiding.
        let usedKeys = Set(notes.flatMap(\.tags).map(NoteTags.key))
        order.removeAll { !usedKeys.contains(NoteTags.key($0)) }
        hidden.removeAll { !usedKeys.contains(NoteTags.key($0)) }
    }

    mutating func register(_ tags: [String]) {
        let keys = Set(tags.map(NoteTags.key))
        hidden.removeAll { keys.contains(NoteTags.key($0)) }
        var seen = Set(order.map(NoteTags.key))
        order += tags.filter { seen.insert(NoteTags.key($0)).inserted }
    }
}

enum PrivateNoteTimeline {
    // A day's timeline reads morning to night; browsing tags reads newest first.
    static func entries(_ notes: [PrivateNote], day: Date? = nil, calendar: Calendar = .current,
                        kind: NoteKind? = nil, tag: String? = nil, query: String = "") -> [PrivateNote] {
        items(notes, kind: kind, tag: tag, query: query).filter { note in
            day.map { calendar.isDate(note.date, inSameDayAs: $0) } ?? true
        }.sorted {
            if $0.date != $1.date { return day == nil ? $0.date > $1.date : $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func week(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: day) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    static func items(_ notes: [PrivateNote], kind: NoteKind? = nil, tag: String? = nil, query: String = "") -> [PrivateNote] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter { note in
            note.deletedAt == nil && (kind == nil || note.kind == kind)
                && (tag == nil || note.tags.contains { NoteTags.key($0) == NoteTags.key(tag!) })
                && (query.isEmpty || (note.title + "\n" + note.body).localizedStandardContains(query))
        }.sorted {
            if ($0.pinnedAt != nil) != ($1.pinnedAt != nil) { return $0.pinnedAt != nil }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func tags(in notes: [PrivateNote]) -> [String] {
        var seen = Set<String>()
        return items(notes).flatMap(\.tags).filter { seen.insert(NoteTags.key($0)).inserted }
    }
}

@MainActor final class PrivateNoteStore: ObservableObject {
    @Published private(set) var notes: [PrivateNote] = []
    @Published private(set) var storageError: String?
    @Published private(set) var tagCatalog = NoteTagCatalog()
    @Published private(set) var tagStorageError: String?
    private(set) var loaded = false
    private(set) var tagsLoaded = false
    private let url: URL
    private let tagURL: URL
    init(url: URL? = nil, tagURL: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("cocoWriter/private-notes.json")
        self.tagURL = tagURL ?? self.url.deletingLastPathComponent().appendingPathComponent("private-note-tags.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) { notes = try JSONDecoder().decode([PrivateNote].self, from: Data(contentsOf: self.url)) }
            loaded = true
        } catch { storageError = "メモを読み込めません。元ファイルを保護するため保存を停止しました。\(error.localizedDescription)" }
        do {
            if FileManager.default.fileExists(atPath: self.tagURL.path) { tagCatalog = try JSONDecoder().decode(NoteTagCatalog.self, from: Data(contentsOf: self.tagURL)) }
            tagsLoaded = true
        } catch { tagStorageError = "タグの設定を読み込めません。元ファイルを保護するため変更を停止しました。\(error.localizedDescription)" }
        removeUnusedTags()
    }
    var active: [PrivateNote] {
        notes.filter { $0.deletedAt == nil }.sorted {
            if ($0.pinnedAt != nil) != ($1.pinnedAt != nil) { return $0.pinnedAt != nil }
            return $0.updatedAt > $1.updatedAt
        }
    }
    var trash: [PrivateNote] { notes.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! } }
    var tags: [String] { tagCatalog.visible(in: active) }

    @discardableResult func hideTag(_ tag: String) -> Bool {
        guard loaded, tagsLoaded, tags.contains(where: { NoteTags.key($0) == NoteTags.key(tag) }) else { return false }
        var next = tagCatalog
        next.order = tags.filter { NoteTags.key($0) != NoteTags.key(tag) }
        next.hidden.append(tag)
        return commitTags(next)
    }

    @discardableResult func restoreTag(_ tag: String) -> Bool {
        guard loaded, tagsLoaded else { return false }
        var next = tagCatalog; next.order = tags; next.register([tag])
        return commitTags(next)
    }

    @discardableResult func moveTags(from offsets: IndexSet, to destination: Int) -> Bool {
        guard loaded, tagsLoaded else { return false }
        var order = tags
        guard !offsets.isEmpty, offsets.allSatisfy({ order.indices.contains($0) }), (0...order.count).contains(destination) else { return false }
        let moving = offsets.sorted().map { order[$0] }
        for offset in offsets.sorted(by: >) { order.remove(at: offset) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        order.insert(contentsOf: moving, at: insertion)
        var next = tagCatalog; next.order = order
        return commitTags(next)
    }

    private func registerTags(_ tags: [String]) {
        guard tagsLoaded, !tags.isEmpty else { return }
        var next = tagCatalog; next.order = self.tags; next.register(tags)
        if next != tagCatalog { _ = commitTags(next) }
    }

    private func removeUnusedTags() {
        guard loaded, tagsLoaded else { return }
        var next = tagCatalog
        next.removeUnused(in: notes)
        if next != tagCatalog { _ = commitTags(next) }
    }

    private func commitTags(_ next: NoteTagCatalog) -> Bool {
        guard loaded, tagsLoaded else { return false }
        do {
            try FileManager.default.createDirectory(at: tagURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: tagURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            tagCatalog = next; tagStorageError = nil; return true
        } catch { tagStorageError = "タグの設定を保存できませんでした。\(error.localizedDescription)"; return false }
    }
    @discardableResult func addEntry(body: String, date: Date = Date()) -> Bool {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !body.isEmpty else { return false }
        var note = PrivateNote(); note.body = body; note.date = date
        guard commit([note] + notes) else { return false }
        registerTags(note.tags)
        return true
    }
    @discardableResult func update(_ note: PrivateNote) -> Bool {
        guard loaded else { return false }
        let previousTags = Set(notes.first(where: { $0.id == note.id })?.tags.map(NoteTags.key) ?? [])
        var value = note; value.updatedAt = Date()
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = value } else { notes.insert(value, at: 0) }
        guard persist() else { return false }
        registerTags(value.tags.filter { !previousTags.contains(NoteTags.key($0)) })
        return true
    }
    @discardableResult func persist() -> Bool {
        guard loaded else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(notes).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            storageError = nil
            removeUnusedTags()
            return true
        } catch { storageError = "メモを保存できません。アプリを閉じず、容量などを確認して再保存してください。\(error.localizedDescription)"; return false }
    }
    @discardableResult func moveToTrash(_ ids: Set<UUID>) -> Bool {
        guard loaded, !ids.isEmpty, notes.filter({ ids.contains($0.id) && $0.deletedAt == nil }).count == ids.count else { return false }
        var next = notes; for index in next.indices where ids.contains(next[index].id) { next[index].deletedAt = Date() }
        return commit(next)
    }
    @discardableResult func restore(_ id: UUID) -> Bool {
        guard loaded, let index = notes.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { return false }
        var next = notes; next[index].deletedAt = nil; return commit(next)
    }
    @discardableResult func deletePermanently(_ id: UUID) -> Bool {
        guard loaded, notes.contains(where: { $0.id == id && $0.deletedAt != nil }) else { return false }
        return commit(notes.filter { $0.id != id })
    }
    @discardableResult func togglePin(_ id: UUID) -> Bool {
        guard loaded, let index = notes.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        var next = notes; next[index].pinnedAt = next[index].pinnedAt == nil ? Date() : nil; return commit(next)
    }
    private func commit(_ next: [PrivateNote]) -> Bool {
        let previous = notes; notes = next
        if persist() { return true }; notes = previous; return false
    }
}
