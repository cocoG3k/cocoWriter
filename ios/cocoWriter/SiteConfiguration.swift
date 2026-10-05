import Foundation

enum ArticleTags {
    static let defaultsKey = "cocoWriter.article-tags.v1"
    static let initial = ["日常", "旅行", "音楽"]
    static func normalized(_ values: [String]) throws -> [String] {
        var result: [String] = []
        for value in values {
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, !tag.contains(","), !tag.contains("、"), !tag.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw WriterError.message("タグは一つずつ入力してください。カンマや改行は使えません。")
            }
            if !result.contains(tag) { result.append(tag) }
        }
        return result
    }
    static func toggling(_ tag: String, in text: String) -> String {
        var tags = RepositoryArticleMarkdown.tagValues(text)
        if tags.contains(tag) { tags.removeAll { $0 == tag } } else { tags.append(tag) }
        return tags.joined(separator: ", ")
    }
}

struct ArticleCategory: Codable, Equatable, Identifiable {
    var name: String
    var profile: BlogProfile
    var isEnabled = true
    var id: String { profile.articleDirectory }
    func containsDirectory(of path: String) -> Bool {
        BlogProfile.safeRepositoryPath(path) && (id.isEmpty || path.hasPrefix(id + "/"))
    }
    static let defaultsKey = "cocoWriter.article-categories.v1"
    static var initial: [ArticleCategory] { [Self(name: suggestedName(for: BlogProfile.current.articleDirectory), profile: .current)] }
    static func suggestedName(for directory: String) -> String {
        let component = (directory as NSString).lastPathComponent
        switch component {
        case "diary": return "日記"
        case "journey", "travel": return "旅"
        case "tech": return "技術"
        case "life": return "暮らし"
        case "music": return "音楽"
        default: return component.isEmpty ? "記事" : component
        }
    }
    static func validate(_ categories: [ArticleCategory]) throws {
        guard categories.contains(where: \.isEnabled) else { throw WriterError.message("少なくとも一つのカテゴリを有効にしてください。") }
        guard Set(categories.map(\.id)).count == categories.count else { throw WriterError.message("同じ記事保存先を重複して登録できません。") }
        for category in categories {
            guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WriterError.message("カテゴリ名を入力してください。") }
            try category.profile.validate()
        }
    }
}

/// Connection data only. Personal access tokens are kept separately in Keychain.
struct SiteConfiguration: Codable, Equatable {
    var owner = ""
    var repository = ""
    var branch = "main"
    var website = ""
    var title = "My Journal"
    var tagline = "日々の記録と好きな音楽"

    static let defaultsKey = "cocoWriter.site.v1"
    static var current: SiteConfiguration { load(from: .standard) }
    static func configuredDefault(_ app: AppConfiguration = .current) -> SiteConfiguration {
        let site = app.defaultSite
        return Self(owner: site.owner, repository: site.repository, branch: site.branch, website: site.website, title: site.title, tagline: site.tagline)
    }
    static func load(from defaults: UserDefaults, fallback: SiteConfiguration? = nil) -> SiteConfiguration {
        guard let bytes = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: bytes) else { return fallback ?? configuredDefault() }
        return value
    }
    var repositorySlug: String { owner + "/" + repository }
    var destinationID: String { repositorySlug.lowercased() + "@" + branch }
    var websiteURL: URL? {
        guard let c = URLComponents(string: website), c.scheme == "https", c.host != nil,
              c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil else { return nil }
        return c.url
    }
    var actionsURL: URL? {
        guard connectionError == nil else { return nil }
        return URL(string: "https://github.com/" + repositorySlug + "/actions")
    }
    /// Append to the site's base path, including /repository/ on project Pages.
    func publicAssetURL(for path: String, profile: BlogProfile = .current) -> URL? {
        guard profile.repositoryImageReference(path, configuration: self) != nil, let base = websiteURL else { return nil }
        if profile.imageReferenceStyle == .absolute { return URL(string: path) }
        return base.appendingPathComponent(String(path.dropFirst()))
    }
    /// Existing site images can be previewed without treating them as managed uploads.
    func previewAssetURL(for reference: String, profile: BlogProfile = .current) -> URL? {
        if let managed = publicAssetURL(for: reference, profile: profile) { return managed }
        guard !reference.contains("\\"), !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: reference), parts.user == nil, parts.password == nil else { return nil }
        if parts.scheme == "https", parts.host != nil { return parts.url }
        guard reference.hasPrefix("/"), !reference.hasPrefix("//"), parts.scheme == nil, parts.host == nil,
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), let base = websiteURL else { return nil }
        // Ordinary /images/... Markdown uses the origin root, as it does on the site.
        return URL(string: reference, relativeTo: base)?.absoluteURL
    }
    var connectionError: String? {
        if let error = BlogProfile.configurationError { return error }
        guard owner.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#, options: .regularExpression) != nil else {
            return "GitHubのユーザー名・組織名を入力してください。"
        }
        guard repository.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil,
              repository != ".", repository != ".." else { return "リポジトリ名を確認してください。" }
        let parts = branch.split(separator: "/", omittingEmptySubsequences: false)
        guard !branch.isEmpty, branch.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil,
              !branch.contains(".."), parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock") }) else {
            return "ブランチ名を確認してください（例: main、publish/blog）。"
        }
        return nil
    }
    func normalized() throws -> SiteConfiguration {
        var value = self
        value.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        value.repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        value.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        value.website = website.trimmingCharacters(in: .whitespacesAndNewlines)
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.tagline = tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = value.connectionError { throw WriterError.message(message) }
        guard let url = value.websiteURL, let host = url.host, !host.isEmpty,
              !url.path.contains("\\"), !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw WriterError.message("公開サイトのHTTPS URLを入力してください。プロジェクトサイトは末尾に /リポジトリ名/ を含めます。")
        }
        if !value.website.hasSuffix("/") { value.website += "/" }
        guard !value.title.isEmpty else { throw WriterError.message("サイト名を入力してください。") }
        return value
    }
}
