import Foundation

/// Bundled defaults and saved per-category article settings. Drafts keep a snapshot.
struct BlogProfile: Codable, Equatable {
    enum Format: String, Codable { case yaml, toml, json }
    enum DateStyle: String, Codable { case date, iso8601, jekyll }
    enum ImageReferenceStyle: String, Codable { case siteRelative = "site-relative", absolute }
    struct Fields: Codable, Equatable {
        var title = "title"
        var description: String? = "description"
        var date = "date"
        var tags: String? = "tags"
    }
    struct FrontMatter: Codable, Equatable {
        var format: Format = .yaml
        var fields = Fields()
        var requireDescription = true
        var dateStyle: DateStyle = .date
        var timeZone = "Asia/Tokyo"
        var extra: [String: Value] = [:]
    }
    enum Value: Codable, Equatable {
        case string(String), bool(Bool), number(Double), strings([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
            else { self = .strings(try c.decode([String].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .strings(let v): try c.encode(v)
            }
        }
        var literal: String {
            if case .string(let value) = self { return Draft.yaml(value) }
            if case .strings(let values) = self { return "[" + values.map(Draft.yaml).joined(separator: ", ") + "]" }
            return String(data: try! JSONEncoder().encode(self), encoding: .utf8)!
        }
    }
    var schemaVersion = 1
    var articleDirectory = "src/content/diary"
    var imageDirectory = "public/images/diary"
    /// Relative to the site's base URL, with a leading slash. No repository name here.
    var imagePublicPath = "/images/diary"
    var imageReferenceStyle: ImageReferenceStyle = .siteRelative
    var filenameTemplate = "ios-{id}.md"
    var articleExtensions = ["md", "markdown"]
    var excludedArticleNames = ["_index.md"]
    var frontMatter = FrontMatter()
    static let standard = BlogProfile()
    func hasSameFormat(as base: BlogProfile) -> Bool {
        var value = self
        value.articleDirectory = base.articleDirectory
        value.imageDirectory = base.imageDirectory
        value.imagePublicPath = base.imagePublicPath
        return value == base
    }
    private static let loaded: Result<BlogProfile, Error> = Result {
        guard let url = Bundle.main.url(forResource: "BlogProfile", withExtension: "json") else {
            throw WriterError.message("ビルド設定 BlogProfile.json が含まれていません。")
        }
        return try decode(Data(contentsOf: url))
    }
    static var current: BlogProfile { (try? loaded.get()) ?? standard }
    static var configurationError: String? {
        if case .failure(let error) = loaded { return "ブログのビルド設定が無効です。" + error.localizedDescription }
        return nil
    }
    static func decode(_ bytes: Data) throws -> BlogProfile {
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        return value
    }
    static func safePath(_ path: String, allowEmpty: Bool = false) -> Bool {
        if path.isEmpty { return allowEmpty }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
            }
        }
    }
    static func safeRepositoryPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    func validate() throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw WriterError.message(message) }
        }
        try require(schemaVersion == 1, "schemaVersion は 1 を指定してください。")
        try require(Self.safePath(articleDirectory, allowEmpty: true) && Self.safePath(imageDirectory, allowEmpty: true), "保存先はリポジトリ内の相対パスで指定してください。")
        try require(imagePublicPath.hasPrefix("/") && (imagePublicPath == "/" || Self.safePath(String(imagePublicPath.dropFirst()))), "画像公開パスは / から始まるサイト内パスで指定してください。")
        try require(!articleExtensions.isEmpty && Set(articleExtensions).count == articleExtensions.count && articleExtensions.allSatisfy { ["md", "markdown"].contains($0) }, "記事の拡張子は md、markdown に対応しています。")
        try require(excludedArticleNames.allSatisfy { Self.safePath($0) && !$0.contains("/") }, "除外する記事名を確認してください。")
        var sample = filenameTemplate
        for token in ["id", "date", "year", "month", "day"] { sample = sample.replacingOccurrences(of: "{\(token)}", with: token == "id" ? UUID().uuidString.lowercased() : "01") }
        try require(filenameTemplate.components(separatedBy: "{id}").count == 2 && Self.safePath(sample) && articleExtensions.contains((sample as NSString).pathExtension), "ファイル名には {id} を1つ含め、対応する拡張子を指定してください。")
        try require(TimeZone(identifier: frontMatter.timeZone) != nil, "日付のタイムゾーンを確認してください。")
        let keys = [frontMatter.fields.title, frontMatter.fields.date] + [frontMatter.fields.description, frontMatter.fields.tags].compactMap { $0 }
        try require(Set(keys).count == keys.count && (keys + Array(frontMatter.extra.keys)).allSatisfy {
            $0.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
        }, "Front Matter の項目名は重複のない英数字・_・-で指定してください。")
        try require(Set(keys).isDisjoint(with: frontMatter.extra.keys), "固定項目は編集項目と異なる名前で指定してください。")
        try require(!frontMatter.requireDescription || frontMatter.fields.description != nil, "説明文を必須にする場合は項目名も指定してください。")
        try require(frontMatter.extra.values.allSatisfy { if case .number(let v) = $0 { return v.isFinite && abs(v) <= 9007199254740991 }; return true }, "固定項目の数値が対応範囲を超えています。")
    }
    func articlePath(id: UUID, date: Date) -> String {
        var name = filenameTemplate.replacingOccurrences(of: "{id}", with: id.uuidString.lowercased())
        for (key, format) in [("date", "yyyy-MM-dd"), ("year", "yyyy"), ("month", "MM"), ("day", "dd")] {
            name = name.replacingOccurrences(of: "{\(key)}", with: formatter(format).string(from: date))
        }
        return join(articleDirectory, name)
    }
    func validArticlePath(_ path: String) -> Bool {
        Self.safeRepositoryPath(path) && (articleDirectory.isEmpty || path.hasPrefix(articleDirectory + "/")) &&
        articleExtensions.contains((path as NSString).pathExtension) && !excludedArticleNames.contains((path as NSString).lastPathComponent)
    }
    func imagePath(id: UUID, hash: String) -> String { join(imageDirectory, id.uuidString.lowercased() + "/" + hash + ".jpg") }
    func validImagePath(_ path: String) -> Bool {
        guard Self.safePath(path), imageDirectory.isEmpty || path.hasPrefix(imageDirectory + "/") else { return false }
        let suffix = imageDirectory.isEmpty ? path : String(path.dropFirst(imageDirectory.count + 1))
        let parts = suffix.split(separator: "/")
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && parts[1].hasSuffix(".jpg") &&
        parts[1].dropLast(4).count == 64 && parts[1].dropLast(4).allSatisfy { "0123456789abcdef".contains($0) }
    }
    func publicPath(for repositoryPath: String) -> String? {
        guard validImagePath(repositoryPath) else { return nil }
        let suffix = imageDirectory.isEmpty ? repositoryPath : String(repositoryPath.dropFirst(imageDirectory.count + 1))
        return (imagePublicPath == "/" ? "" : imagePublicPath) + "/" + suffix
    }
    func repositoryImagePath(for publicPath: String) -> String? {
        let prefix = (imagePublicPath == "/" ? "" : imagePublicPath) + "/"
        guard publicPath.hasPrefix(prefix) else { return nil }
        let result = join(imageDirectory, String(publicPath.dropFirst(prefix.count)))
        return validImagePath(result) ? result : nil
    }
    func imageReference(for path: String, configuration: SiteConfiguration) -> String? {
        guard let publicPath = publicPath(for: path) else { return nil }
        if imageReferenceStyle == .siteRelative { return publicPath }
        return configuration.websiteURL?.appendingPathComponent(String(publicPath.dropFirst())).absoluteString
    }
    func repositoryImageReference(_ reference: String, configuration: SiteConfiguration) -> String? {
        if imageReferenceStyle == .siteRelative { return repositoryImagePath(for: reference) }
        guard let base = configuration.websiteURL else { return nil }
        var prefix = imagePublicPath == "/" ? base.absoluteString : base.appendingPathComponent(String(imagePublicPath.dropFirst())).absoluteString
        if !prefix.hasSuffix("/") { prefix += "/" }
        guard reference.hasPrefix(prefix) else { return nil }
        let suffix = String(reference.dropFirst(prefix.count))
        let result = join(imageDirectory, suffix)
        return validImagePath(result) ? result : nil
    }
    func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: frontMatter.timeZone); f.dateFormat = format; f.isLenient = false
        return f
    }
    var dateFormat: String {
        switch frontMatter.dateStyle { case .date: return "yyyy-MM-dd"; case .iso8601: return "yyyy-MM-dd'T'HH:mm:ssXXXXX"; case .jekyll: return "yyyy-MM-dd HH:mm:ss Z" }
    }
    func dateText(_ date: Date) -> String { formatter(dateFormat).string(from: date) }
    func parseDate(_ text: String) -> Date? {
        for format in [dateFormat, "yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd HH:mm:ss Z"] {
            let f = formatter(format)
            if let d = f.date(from: text), f.string(from: d) == text || text.hasSuffix("Z") && format.contains("XXXXX") { return d }
        }
        return nil
    }
    private func join(_ directory: String, _ name: String) -> String { directory.isEmpty ? name : directory + "/" + name }
}
