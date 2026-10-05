import Foundation
import Combine

@MainActor final class MusicLibraryStore: ObservableObject {
    private struct Publication: Codable, Equatable {
        var articleID: UUID
        var remoteSHA: String?
        var stockIDs: [UUID]
    }
    private struct Archive: Codable {
        var items: [MusicItem] = []
        var migrated = false
        // Optional so stock archives from earlier versions still decode.
        var publications: [Publication]?
    }
    @Published private(set) var items: [MusicItem] = []
    @Published var storageError: String?
    private(set) var loaded = false
    private var migrated = false
    private var storedItems: [MusicItem] = []
    private var publications: [Publication] = []
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? AppConfiguration.current.storageURL("music-library.json")
        do {
            if url == nil, let error = AppConfiguration.configurationError { throw WriterError.message(error) }
            if FileManager.default.fileExists(atPath: self.url.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.url))
                storedItems = archive.items; migrated = archive.migrated
                publications = archive.publications ?? []
                refreshAvailableItems()
            }
            loaded = true
        } catch { storageError = "曲のストックを読み込めません。元ファイルを保護するため保存を停止しました。\(error.localizedDescription)" }
    }
    @discardableResult func update(_ item: MusicItem) -> Bool {
        guard loaded else { return false }
        var next = storedItems
        if let index = next.firstIndex(where: { $0.id == item.id }) { next[index] = item }
        else { next.insert(item, at: 0) }
        return commit(next)
    }
    @discardableResult func remove(_ id: UUID) -> Bool {
        // An editor opened before publication must not delete the recovery copy.
        guard !storedItems.contains(where: { $0.id == id }) || items.contains(where: { $0.id == id }) else { return false }
        return commit(storedItems.filter { $0.id != id })
    }
    @discardableResult func migrate(from drafts: [Draft]) -> Bool {
        guard loaded, !migrated else { return loaded }
        var next = storedItems
        for item in drafts.filter { $0.deletedAt == nil }.flatMap(\.music) {
            var stock = item; stock.id = item.sourceID ?? item.id; stock.sourceID = nil
            if !next.contains(where: { $0.id == stock.id }) { next.append(stock) }
        }
        return commit(next, migrated: true)
    }
    // Reconcile only durable article state. A pending upload with no confirmed
    // remote SHA stays available; pending edits/deletion keep the last reservation.
    @discardableResult func reconcile(from drafts: DraftStore) -> Bool {
        guard loaded, drafts.loaded, drafts.storageError == nil else { return false }
        var next = storedItems
        var reservations = publications
        for draft in drafts.drafts {
            let index = reservations.firstIndex { $0.articleID == draft.id }
            guard let sha = draft.remoteSHA else {
                if !draft.hasPendingOperation, let index { reservations[index].remoteSHA = nil }
                continue
            }
            if let index, reservations[index].remoteSHA == sha || draft.hasPendingOperation { continue }
            // Imported Markdown does not retain the original structured song
            // fields. Keep the association when loading a newer remote revision.
            if let index, draft.repositorySource != nil && draft.music.isEmpty {
                reservations[index].remoteSHA = sha
                continue
            }
            guard !draft.music.isEmpty || index != nil else { continue }
            var ids: [UUID] = draft.repositorySource != nil ? (index.map { reservations[$0].stockIDs } ?? []) : []
            for item in draft.music {
                let id = item.sourceID ?? item.id
                if !ids.contains(id) { ids.append(id) }
                if !next.contains(where: { ($0.sourceID ?? $0.id) == id }) {
                    var stock = item; stock.id = id; stock.sourceID = nil
                    next.append(stock)
                }
            }
            let reservation = Publication(articleID: draft.id, remoteSHA: sha, stockIDs: ids)
            if let index { reservations[index] = reservation }
            else if !ids.isEmpty { reservations.append(reservation) }
        }
        // An absent local article alone does not prove it was removed remotely.
        guard next != storedItems || reservations != publications else { return true }
        return commit(next, publications: reservations)
    }
    private func refreshAvailableItems() {
        let used = Set(publications.filter { $0.remoteSHA != nil }.flatMap(\.stockIDs))
        items = storedItems.filter { !used.contains($0.id) && !used.contains($0.sourceID ?? $0.id) }
    }
    private func commit(_ next: [MusicItem], migrated nextMigrated: Bool? = nil, publications nextPublications: [Publication]? = nil) -> Bool {
        guard loaded else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let archive = Archive(items: next, migrated: nextMigrated ?? migrated, publications: nextPublications ?? publications)
            try JSONEncoder().encode(archive).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            storedItems = next; migrated = archive.migrated; publications = archive.publications ?? []
            refreshAvailableItems(); storageError = nil
            return true
        } catch { storageError = "曲のストックを保存できません。\(error.localizedDescription)"; return false }
    }
    static func articleCopies(_ items: [MusicItem]) -> [MusicItem] {
        items.map { item in var copy = item; copy.id = UUID(); copy.sourceID = item.id; return copy }
    }
    // Each share is a separate atomic file. Never overwrite an inbox snapshot while
    // the extension is writing, and acknowledge only after both stores are durable.
    func importShares(from directory: URL, drafts: DraftStore) -> [Draft] {
        guard loaded, drafts.loaded else { return [] }
        if let error = drafts.categorySettingsError { storageError = error; return [] }
        var created: [Draft] = []
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "json" }.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
            for file in files {
                let request = try JSONDecoder().decode(SharedMusicRequest.self, from: Data(contentsOf: file))
                guard SharedMusicLink.parse(request.item.youtubeURL) != nil else {
                    storageError = "共有された曲のURLを読み取れません。共有データは保持しています。"; continue
                }
                var item = request.item; item.id = request.id
                if !storedItems.contains(where: { $0.id == item.id }), !update(item) { break }
                if request.createArticle {
                    if !drafts.drafts.contains(where: { $0.id == request.id }) {
                        var article = drafts.newDraft(kind: .music); article.id = request.id
                        article.title = request.articleTitle; article.body = request.introduction
                        article.tags = "曲紹介"; article.music = Self.articleCopies([item])
                        guard drafts.update(article) else { break }
                        created.append(article)
                    } else if drafts.storageError != nil, !drafts.persist() { break }
                }
                try FileManager.default.removeItem(at: file)
            }
        } catch { storageError = "共有した曲を取り込めません。共有データは保持しています。\(error.localizedDescription)" }
        return created
    }
}
