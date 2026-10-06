import Foundation
import CryptoKit

enum PostKind: String, Codable, CaseIterable, Identifiable {
    case diary, music
    var id: String { rawValue }
    var label: String { self == .diary ? "記事" : "曲紹介" }
    var symbol: String { self == .diary ? "square.and.pencil" : "music.note" }
}
struct Draft: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: PostKind
    var blogProfile: BlogProfile? = .current
    // Runtime categories retain both their paths and the build format they extend.
    // Optional fields keep existing drafts readable without rewriting them.
    var categoryBaseProfile: BlogProfile?
    var categoryName: String?
    var articleSettingsVersion: Int?
    var profile: BlogProfile { blogProfile ?? .standard }
    var supportsCurrentProfile: Bool {
        if let version = articleSettingsVersion { return version == 1 && (try? profile.validate()) != nil }
        return profile == .current || (categoryBaseProfile == .current && profile.hasSameFormat(as: .current))
    }
    var publicationProfile: BlogProfile { supportsCurrentProfile ? profile : .current }
    var containsMusic: Bool { kind == .music || !music.isEmpty || body.contains("open.spotify.com/embed/") }
    var canChangeCategory: Bool {
        supportsCurrentProfile && remoteDestination == nil && remoteSHA == nil && repositoryPath == nil && !hasPendingOperation && imageCommitSHA == nil && commitURL == nil
    }
    mutating func selectCategory(_ category: ArticleCategory, configuration: SiteConfiguration) throws {
        guard canChangeCategory else { throw WriterError.message("公開済み・確認待ちの記事のカテゴリは変更できません。複製して下書きにしてください。") }
        try category.profile.validate()
        guard category.isEnabled else { throw WriterError.message("設定で有効なカテゴリを選んでください。") }
        guard repositorySource == nil || profile.frontMatter == category.profile.frontMatter else {
            throw WriterError.message("読み込んだ記事のヘッダーは元の形式を保ちます。異なる記事形式を使う場合は、新しい記事を作成してください。")
        }
        var next = self
        // Photos use the same local bytes; only this unpublished draft's paths change.
        next.images = try attachedImages.map { image in
            let path = category.profile.imagePath(id: id, hash: image.hash)
            guard let reference = category.profile.imageReference(for: path, configuration: configuration) else {
                throw WriterError.message("カテゴリの写真保存先を確認してください。")
            }
            next.body = next.body.replacingOccurrences(of: image.publicPath, with: reference)
            next.music = next.music.map { item in
                var copy = item; copy.comment = copy.comment.replacingOccurrences(of: image.publicPath, with: reference); return copy
            }
            return ArticleImage(hash: image.hash, repositoryPath: path, width: image.width, height: image.height, byteCount: image.byteCount, publishedPath: reference)
        }
        next.blogProfile = category.profile; next.categoryBaseProfile = .current; next.categoryName = category.name
        next.articleSettingsVersion = 1
        self = next
    }
    var title = ""
    var description = ""
    var date = Date()
    var tags = ""
    var body = ""
    var music: [MusicItem] = []
    // Optional so pre-image drafts continue to decode without migration.
    var images: [ArticleImage]?
    var uploadedImagePaths: [String]?
    var imageCommitSHA: String?
    var publishedMarkdown: String?
    var updatedAt = Date()
    var remoteDestination: String?
    var remoteSHA: String?
    var commitURL: String?
    var pendingMarkdown: String?
    var pendingDeletionSHA: String?
    var repositoryPath: String?
    var repositorySource: RepositorySource?
    var remoteChanged: Bool?
    var pinnedAt: Date?
    var deletedAt: Date?
    var isPublished: Bool { remoteSHA != nil && pendingMarkdown == nil }
    var hasPendingOperation: Bool { pendingMarkdown != nil || pendingDeletionSHA != nil }
    var attachedImages: [ArticleImage] { images ?? [] }
    var referencedImages: [ArticleImage] {
        let text = pendingMarkdown ?? markdown
        let paths = ArticleImageReferences.paths(in: text)
        return attachedImages.filter { paths.contains($0.publicPath) }
    }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "無題の\(kind.label)" : title }
    var isEmptyUnpublishedDraft: Bool {
        remoteDestination == nil && remoteSHA == nil && repositoryPath == nil && repositorySource == nil &&
        pendingMarkdown == nil && pendingDeletionSHA == nil && commitURL == nil && imageCommitSHA == nil &&
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && music.isEmpty && attachedImages.isEmpty
    }
    // Independent of editable title/date, and unchanged for this draft's lifetime.
    var filename: String { (path as NSString).lastPathComponent }
    var path: String { repositoryPath ?? profile.articlePath(id: id, date: date) }
    var hasUnpublishedEdits: Bool { (repositorySource?.markdown ?? publishedMarkdown).map { markdown != $0 } ?? false }
    var validation: String? {
        if let error = BlogProfile.configurationError { return error }
        if !supportsCurrentProfile { return "この記事は以前のビルド設定で作成されています。元の設定で書き出し・公開してください。" }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "タイトルを入力してください。" }
        if profile.frontMatter.requireDescription && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "説明文を入力してください。" }
        if !music.isEmpty {
            for item in music {
                if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "各曲・アルバムのタイトルを入力してください。" }
                if SpotifyLink(item.spotifyURL) == nil { return "Spotify の曲・アルバムの共有 URL を入力してください。" }
                if !item.confirmed { return "各 Spotify リンクの曲・バージョンを確認してください。" }
                // The optional source URL is provenance only. Manual Spotify confirmation can complete an unavailable source.
            }
        }
        return nil
    }
    var markdown: String {
        var text = repositorySource.map { RepositoryArticleMarkdown.render(self, source: $0) }
            ?? (RepositoryArticleMarkdown.newHeader(self) + "\n" + body + "\n")
        if !music.isEmpty {
            for item in music {
                let heading = [item.artist, item.title].filter { !$0.isEmpty }.joined(separator: " - ")
                text += "\n### \(Self.heading(heading))\n\n"
                if let link = SpotifyLink(item.spotifyURL), item.confirmed {
                    text += "<iframe style=\"border-radius:12px\" src=\"\(link.embedURL.absoluteString)\" width=\"100%\" height=\"352\" frameBorder=\"0\" allowfullscreen=\"\" allow=\"autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture\" loading=\"lazy\"></iframe>\n\n"
                }
                text += item.comment + "\n"
            }
        }
        return text
    }
    // JSON double-quoted strings are YAML 1.2 scalars, including control characters.
    static func yaml(_ value: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }
    static func heading(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").map { "\\`*_{}[]<>#!|".contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}

enum TrashRetentionPeriod: String, CaseIterable, Identifiable {
    case sevenDays, thirtyDays, ninetyDays, never
    static let defaultsKey = "trash-retention-period"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sevenDays: return "1週間"
        case .thirtyDays: return "30日"
        case .ninetyDays: return "90日"
        case .never: return "自動削除しない"
        }
    }
    var days: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .never: return nil
        }
    }
    static func load(from preferences: UserDefaults) -> Self {
        preferences.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .sevenDays
    }
    func isExpired(_ deletedAt: Date, now: Date) -> Bool {
        days.map { deletedAt <= now.addingTimeInterval(-Double($0) * 24 * 60 * 60) } ?? false
    }
}
struct RepositorySource: Codable, Equatable {
    var markdown: String
    var title: String
    var description: String
    var date: Date
    var tags: String
}
enum ArticleShelf: String, CaseIterable, Identifiable {
    case drafts, published
    var id: String { rawValue }
    var label: String { self == .drafts ? "下書き" : "投稿済み" }
}
enum ArticleFilter: String, CaseIterable, Identifiable {
    case all, diary, music
    var id: String { rawValue }
    var label: String { switch self { case .all: return "全て"; case .diary: return "文章"; case .music: return "曲あり" } }
    func includes(_ draft: Draft) -> Bool { self == .all || (self == .diary ? !draft.containsMusic : draft.containsMusic) }
}
enum ArticleLibrary {
    static func items(_ drafts: [Draft], shelf: ArticleShelf, filter: ArticleFilter = .all, publishedSort: PublishedArticleSort = .newest) -> [Draft] {
        drafts.filter { $0.deletedAt == nil && $0.isPublished == (shelf == .published) && filter.includes($0) }
            .sorted { shelf == .published ? publishedSort.precedes($0, $1) : order($0, $1) }
    }
    static func order(_ left: Draft, _ right: Draft) -> Bool {
        if (left.pinnedAt != nil) != (right.pinnedAt != nil) { return left.pinnedAt != nil }
        if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
        return left.id.uuidString < right.id.uuidString
    }
}
enum PublishedArticleSort: String, CaseIterable, Identifiable {
    case newest, oldest, recentlyEdited, title, pinned
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return "記事の日付が新しい順"
        case .oldest: return "記事の日付が古い順"
        case .recentlyEdited: return "最近編集した順"
        case .title: return "タイトル順"
        case .pinned: return "ピン留め優先"
        }
    }
    func precedes(_ lhs: Draft, _ rhs: Draft) -> Bool {
        switch self {
        case .newest:
            if lhs.date != rhs.date { return lhs.date > rhs.date }
        case .oldest:
            if lhs.date != rhs.date { return lhs.date < rhs.date }
        case .recentlyEdited:
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        case .title:
            let comparison = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .pinned:
            if (lhs.pinnedAt != nil) != (rhs.pinnedAt != nil) { return lhs.pinnedAt != nil }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
        }
        // Editing/opening a same-day article must not move it in date sorting.
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
struct SpotifyLink: Equatable {
    let kind: String
    let id: String
    init?(_ text: String) {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host?.lowercased() == "open.spotify.com", url.user == nil, url.password == nil, url.port == nil else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.first?.hasPrefix("intl-") == true { parts.removeFirst() }
        if parts.first == "embed" { parts.removeFirst() }
        guard parts.count == 2, ["track", "album"].contains(parts[0]), parts[1].count == 22, parts[1].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789").contains($0) }) else { return nil }
        kind = parts[0]; id = parts[1]
    }
    var url: URL { URL(string: "https://open.spotify.com/\(kind)/\(id)")! }
    var embedURL: URL { URL(string: "https://open.spotify.com/embed/\(kind)/\(id)")! }
}
