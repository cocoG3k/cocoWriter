import Foundation
import Combine

@MainActor final class DraftStore: ObservableObject {
    @Published private(set) var drafts: [Draft] = []
    @Published var storageError: String?
    private(set) var loaded = false
    @Published private(set) var site: SiteConfiguration
    @Published private(set) var categories: [ArticleCategory]
    @Published private(set) var categorySettingsError: String?
    @Published private(set) var tagSuggestions: [String]
    func saveTagSuggestions(_ values: [String]) throws {
        let tags = try ArticleTags.normalized(values)
        preferences.set(try JSONEncoder().encode(tags), forKey: ArticleTags.defaultsKey)
        tagSuggestions = tags
    }
    var enabledCategories: [ArticleCategory] { categories.filter(\.isEnabled) }
    func categoryID(for draft: Draft) -> String {
        categories.sorted { $0.id.count > $1.id.count }.first { $0.containsDirectory(of: draft.path) }?.id ?? draft.profile.articleDirectory
    }
    func categoryLabel(for draft: Draft) -> String {
        categories.first { $0.id == categoryID(for: draft) }?.name ?? draft.categoryName ?? ArticleCategory.suggestedName(for: draft.profile.articleDirectory)
    }
    func newDraft(kind: PostKind = .diary) -> Draft {
        var draft = Draft(kind: kind)
        if let category = enabledCategories.first { try? draft.selectCategory(category, configuration: site) }
        return draft
    }
    func saveCategories(_ values: [ArticleCategory]) throws {
        guard loaded, storageError == nil, remoteOperations == 0 else { throw WriterError.message("記事の保存・読み込みが終わってから設定してください。") }
        var normalized = values
        for index in normalized.indices { normalized[index].name = normalized[index].name.trimmingCharacters(in: .whitespacesAndNewlines) }
        try ArticleCategory.validate(normalized)
        // Settings affect future drafts. Existing articles keep their full profile snapshot.
        preferences.set(try JSONEncoder().encode(normalized), forKey: ArticleCategory.defaultsKey)
        categories = normalized; categorySettingsError = nil
    }
    @Published private(set) var remoteOperations = 0
    func beginRemoteOperation() { remoteOperations += 1 }
    func endRemoteOperation() { remoteOperations = max(0, remoteOperations - 1) }
    private let preferences: UserDefaults
    // Remote paths, pending sends and image history must remain bound to their destination.
    var hasConnectedArticles: Bool {
        drafts.contains { $0.remoteDestination != nil || $0.remoteSHA != nil || $0.hasPendingOperation || $0.repositoryPath != nil || $0.imageCommitSHA != nil || $0.commitURL != nil }
    }
    func saveSiteConfiguration(_ value: SiteConfiguration) throws {
        guard loaded, storageError == nil else { throw WriterError.message("端末の保存状態を確認してから設定してください。") }
        let normalized = try value.normalized()
        guard (!hasConnectedArticles && remoteOperations == 0) || normalized.destinationID == site.destinationID else {
            throw WriterError.message("この端末に投稿済み・確認待ちの記事があるため、投稿先を変更できません。記事を書き出して保管し、接続済みの記事を端末から整理してから変更してください。")
        }
        // Clear the previous destination's token before saving a different destination.
        if normalized.destinationID != site.destinationID { try TokenVault.save("") }
        preferences.set(try JSONEncoder().encode(normalized), forKey: SiteConfiguration.defaultsKey)
        if normalized.destinationID != site.destinationID {
            preferences.removeObject(forKey: ArticleCategory.defaultsKey)
            categories = ArticleCategory.initial; categorySettingsError = nil
        }
        site = normalized
    }
    private let url: URL
    var imageFiles: ArticleImageFiles { ArticleImageFiles(root: url.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)) }
    init(url: URL? = nil, preferences: UserDefaults = .standard, configuration: AppConfiguration = .current) {
        self.preferences = preferences
        self.site = SiteConfiguration.load(from: preferences, fallback: .configuredDefault(configuration))
        self.categories = ArticleCategory.initial
        self.tagSuggestions = (preferences.data(forKey: ArticleTags.defaultsKey).flatMap { try? JSONDecoder().decode([String].self, from: $0) }).flatMap { try? ArticleTags.normalized($0) } ?? ArticleTags.initial
        if let bytes = preferences.data(forKey: ArticleCategory.defaultsKey) {
            do {
                let saved = try JSONDecoder().decode([ArticleCategory].self, from: bytes)
                try ArticleCategory.validate(saved); self.categories = saved
            } catch { self.categorySettingsError = "カテゴリ設定を読み込めません。設定画面で確認してください。\(error.localizedDescription)" }
        }
        self.url = url ?? configuration.storageURL("drafts.json")
        do {
            if url == nil, let error = AppConfiguration.configurationError { throw WriterError.message(error) }
            if FileManager.default.fileExists(atPath: self.url.path) {
                drafts = try JSONDecoder().decode([Draft].self, from: Data(contentsOf: self.url))
            }
            if let destination = configuration.legacyDestinationID {
                for index in drafts.indices where drafts[index].blogProfile == nil && drafts[index].remoteDestination == nil {
                    let draft = drafts[index]
                    if draft.remoteSHA != nil || draft.hasPendingOperation || draft.repositoryPath != nil || draft.imageCommitSHA != nil || draft.commitURL != nil {
                        drafts[index].remoteDestination = destination
                    }
                }
            }
            loaded = true
        } catch { storageError = "下書きを読み込めません。元ファイルを保護するため保存を停止しました。\(error.localizedDescription)" }
    }
    @discardableResult func update(_ draft: Draft) -> Bool {
        guard loaded else { return false }
        var next = drafts
        var updated = draft; updated.updatedAt = Date()
        if let index = next.firstIndex(where: { $0.id == draft.id }) { next[index] = updated } else { next.insert(updated, at: 0) }
        // Keep latest edits in memory even when disk is full; block publish/export
        // and expose failure rather than showing a false "saved" state.
        drafts = next
        return persist()
    }
    @discardableResult func persist() -> Bool {
        guard loaded else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(drafts).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            storageError = nil
            return true
        } catch { storageError = "端末に保存できません。アプリを閉じず、容量などを確認して再保存してください。\(error.localizedDescription)"; return false }
    }
    @discardableResult func moveToTrash(_ ids: Set<UUID>) -> Bool {
        guard loaded, !ids.isEmpty else { return false }
        let matching = drafts.filter { ids.contains($0.id) }
        guard matching.count == ids.count, matching.allSatisfy({ !$0.hasPendingOperation && $0.deletedAt == nil }) else { return false }
        var next = drafts
        for index in next.indices where ids.contains(next[index].id) { next[index].deletedAt = Date() }
        return commitManagement(next)
    }
    @discardableResult func restore(_ id: UUID) -> Bool {
        guard loaded, let index = drafts.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { return false }
        var next = drafts; next[index].deletedAt = nil
        return commitManagement(next)
    }
    @discardableResult func deletePermanently(_ id: UUID) -> Bool {
        guard loaded, drafts.contains(where: { $0.id == id && $0.deletedAt != nil && !$0.hasPendingOperation }) else { return false }
        guard commitManagement(drafts.filter { $0.id != id }) else { return false }
        removeUnreferencedImageFiles()
        return true
    }
    @discardableResult func togglePin(_ id: UUID) -> Bool {
        guard loaded, let index = drafts.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        var next = drafts; next[index].pinnedAt = next[index].pinnedAt == nil ? Date() : nil
        return commitManagement(next)
    }
    func duplicate(_ id: UUID) -> Draft? {
        guard loaded, var copy = drafts.first(where: { $0.id == id && $0.deletedAt == nil && !$0.hasPendingOperation }) else { return nil }
        copy.id = UUID(); copy.title = copy.displayTitle + "（コピー）"
        copy.repositoryPath = nil; copy.remoteDestination = nil; copy.remoteChanged = nil
        copy.uploadedImagePaths = nil; copy.imageCommitSHA = nil
        copy.publishedMarkdown = nil
        copy.remoteSHA = nil; copy.commitURL = nil; copy.pendingMarkdown = nil; copy.pinnedAt = nil; copy.deletedAt = nil
        copy.music = copy.music.map { item in var value = item; value.id = UUID(); return value }
        return update(copy) ? copy : nil
    }
    // Persist the exact published version before any destructive network request.
    func beginRemoteDeletion(_ id: UUID) -> Draft? {
        guard loaded, storageError == nil, let index = drafts.firstIndex(where: { $0.id == id }),
              drafts[index].deletedAt == nil, drafts[index].isPublished,
              let sha = drafts[index].remoteSHA else { return nil }
        if drafts[index].pendingDeletionSHA != nil { return drafts[index] }
        var next = drafts; next[index].pendingDeletionSHA = sha
        return commitManagement(next) ? drafts[index] : nil
    }
    @discardableResult func finishRemoteDeletion(_ id: UUID, expectedSHA: String, commitURL: String?) -> Bool {
        guard loaded, let index = drafts.firstIndex(where: { $0.id == id }),
              drafts[index].pendingDeletionSHA == expectedSHA else { return false }
        var next = drafts
        next[index].remoteSHA = nil
        next[index].pendingDeletionSHA = nil
        next[index].remoteChanged = nil
        next[index].commitURL = commitURL
        next[index].updatedAt = Date()
        // Publish one complete result; list updates must not observe intermediate shelves.
        drafts = next
        // Keep the confirmed remote result in memory even if local saving fails.
        // The persisted pending state will reconcile against GitHub on restart.
        return persist()
    }
    @discardableResult func cancelRemoteDeletion(_ id: UUID, remoteChanged: Bool = false) -> Bool {
        guard loaded, let index = drafts.firstIndex(where: { $0.id == id }), drafts[index].pendingDeletionSHA != nil else { return false }
        var next = drafts; next[index].pendingDeletionSHA = nil
        if remoteChanged { next[index].remoteChanged = true }
        return commitManagement(next)
    }
    @discardableResult func mergePublishedArticles(_ remote: [Draft], scannedProfiles: [BlogProfile] = [.current], scannedCategories: [ArticleCategory]? = nil) -> Bool {
        guard loaded, storageError == nil else { return false }
        var next = drafts
        let paths = Set(remote.map(\.path))
        for article in remote {
            if let index = next.firstIndex(where: {
                $0.path == article.path && ($0.profile == article.profile || ($0.supportsCurrentProfile && article.supportsCurrentProfile))
            }) {
                guard !next[index].hasPendingOperation else { continue }
                if next[index].remoteSHA == nil {
                    if next[index].markdown == article.markdown {
                        next[index].remoteSHA = article.remoteSHA; next[index].deletedAt = nil; next[index].remoteChanged = nil
                        next[index].publishedMarkdown = article.markdown
                    } else {
                        // A matching file may have been published elsewhere.
                        // Show it in Published and keep the local text separately.
                        var copy = next[index]; copy.id = UUID(); copy.title = copy.displayTitle + "（編集の控え）"
                        copy.repositoryPath = nil; copy.commitURL = nil; copy.remoteChanged = nil; copy.deletedAt = nil; copy.pinnedAt = nil
                        var published = article; published.id = next[index].id; published.pinnedAt = next[index].pinnedAt
                        next[index] = published; next.append(copy)
                    }
                    continue
                }
                if next[index].remoteSHA == article.remoteSHA {
                    if next[index].remoteSHA != nil { next[index].deletedAt = nil }
                    continue
                }
                // Never replace local edits or infer that a pending local draft
                // has been published just because a file at its path exists.
                if next[index].hasUnpublishedEdits || next[index].repositorySource == nil {
                    next[index].remoteChanged = true
                    continue
                }
                var updated = article
                updated.id = next[index].id; updated.pinnedAt = next[index].pinnedAt
                // Adding a more specific category must not redirect existing photo storage.
                updated.blogProfile = next[index].blogProfile
                updated.categoryBaseProfile = next[index].categoryBaseProfile
                updated.categoryName = next[index].categoryName
                updated.articleSettingsVersion = next[index].articleSettingsVersion
                carryImages(from: next[index], to: &updated)
                next[index] = updated
            } else { next.append(article) }
        }
        let targets = scannedCategories?.sorted { $0.id.count > $1.id.count }
        for index in next.indices where next[index].isPublished && !next[index].hasPendingOperation && !paths.contains(next[index].path) {
            if let targets {
                guard next[index].supportsCurrentProfile,
                      targets.first(where: { $0.containsDirectory(of: next[index].path) })?.isEnabled == true else { continue }
            } else if !scannedProfiles.contains(next[index].profile) { continue }
            next[index].remoteSHA = nil; next[index].remoteChanged = nil; next[index].deletedAt = nil
        }
        return commitManagement(next)
    }
    func keepEditsAndLoadLatest(_ article: Draft) -> Draft? {
        guard loaded, storageError == nil, let index = drafts.firstIndex(where: { $0.path == article.path }),
              drafts[index].pendingDeletionSHA == nil else { return nil }
        var next = drafts
        var copy = next[index]
        copy.id = UUID(); copy.title = copy.displayTitle + "（編集の控え）"
        copy.repositoryPath = nil; copy.remoteSHA = nil; copy.pendingMarkdown = nil
        copy.commitURL = nil; copy.remoteChanged = nil; copy.pinnedAt = nil; copy.deletedAt = nil
        var latest = article; latest.id = next[index].id; latest.pinnedAt = next[index].pinnedAt
        carryImages(from: next[index], to: &latest)
        next[index] = latest; next.append(copy)
        return commitManagement(next) ? latest : nil
    }
    private func commitManagement(_ next: [Draft]) -> Bool {
        let previous = drafts; drafts = next
        if persist() { return true }
        drafts = previous // Failed deletions must not make data disappear from memory.
        return false
    }
    private func carryImages(from previous: Draft, to next: inout Draft) {
        let known = Dictionary(uniqueKeysWithValues: previous.attachedImages.map { ($0.id, $0) })
        next.images = ArticleImageReferences.imported(from: next.markdown, profile: next.profile, configuration: site).map { known[$0.id] ?? $0 }
        next.uploadedImagePaths = previous.uploadedImagePaths
        next.imageCommitSHA = previous.imageCommitSHA
    }
    func clearPublishedImageCopies() throws -> Int {
        guard loaded, storageError == nil else { throw WriterError.message("下書きの保存状態を先に確認してください。") }
        let groups = Dictionary(grouping: drafts.flatMap { draft in draft.attachedImages.map { (draft, $0) } }, by: { $0.1.hash })
        var count = 0
        for references in groups.values {
            guard references.allSatisfy({ draft, image in
                draft.isPublished && !draft.hasPendingOperation && !draft.hasUnpublishedEdits && draft.imageCommitSHA != nil &&
                (draft.uploadedImagePaths ?? []).contains(image.repositoryPath)
            }), let image = references.first?.1 else { continue }
            let file = try imageFiles.url(for: image)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file); count += 1 }
        }
        return count
    }
    private func removeUnreferencedImageFiles() {
        let retained = Set(drafts.flatMap { $0.attachedImages.map { $0.hash + ".jpg" } })
        guard let files = try? FileManager.default.contentsOfDirectory(at: imageFiles.root, includingPropertiesForKeys: nil) else { return }
        for file in files where !retained.contains(file.lastPathComponent) {
            let name = file.lastPathComponent
            if name.hasSuffix(".jpg"), name.count == 68, name.dropLast(4).allSatisfy({ "0123456789abcdef".contains($0) }) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
