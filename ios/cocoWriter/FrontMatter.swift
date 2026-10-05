import Foundation
import CryptoKit

enum RepositoryArticleMarkdown {
    private struct Parts {
        var format: BlogProfile.Format
        var header: String
        var body: String
        var newline: String
        var prefix: String
        var object: [String: Any]?
    }
    static func validPath(_ path: String, profile: BlogProfile = .current) -> Bool { profile.validArticlePath(path) }
    private static func parts(_ markdown: String) throws -> Parts {
        for (delimiter, format) in [("---", BlogProfile.Format.yaml), ("+++", .toml)] {
            let newline = markdown.hasPrefix(delimiter + "\r\n") ? "\r\n" : "\n"
            if markdown.hasPrefix(delimiter + newline) {
                let lines = markdown.components(separatedBy: newline)
                guard let close = lines.indices.dropFirst().first(where: { lines[$0] == delimiter }) else { break }
                let header = lines[1..<close].joined(separator: newline)
                let prefix = lines[0...close].joined(separator: newline) + (close + 1 < lines.count ? newline : "")
                return Parts(format: format, header: header, body: String(markdown.dropFirst(prefix.count)), newline: newline, prefix: prefix)
            }
        }
        // Hugo JSON has no closing delimiter. Find the end of its first object,
        // respecting quoted braces and escapes, before decoding the header.
        if markdown.hasPrefix("{") {
            var depth = 0, quoted = false, escaped = false
            for index in markdown.indices {
                let c = markdown[index]
                if quoted {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { quoted = false }
                } else if c == "\"" { quoted = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = markdown.index(after: index)
                        let header = String(markdown[..<end])
                        guard let object = try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any] else { break }
                        let newline = markdown.contains("\r\n") ? "\r\n" : "\n"
                        let prefix = header + (markdown[end...].hasPrefix(newline) ? newline : "")
                        return Parts(format: .json, header: header, body: String(markdown.dropFirst(prefix.count)), newline: newline, prefix: prefix, object: object)
                    }
                }
            }
        }
        throw WriterError.message("Front Matter を読み取れません。YAML・TOML・JSON のヘッダーを確認してください。元ファイルは変更していません。")
    }
    private static func field(_ key: String, lines: [String], format: BlogProfile.Format) throws -> Range<Int>? {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: key) + (format == .toml ? #"\s*="# : ":")
        // TOML editable fields must be at the root, before the first table.
        let limit = format == .toml ? (lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count) : lines.count
        let matches = (0..<limit).filter { lines[$0].range(of: pattern, options: .regularExpression) != nil }
        guard matches.count <= 1 else { throw WriterError.message("Front Matter の項目「\(key)」が重複しています。") }
        guard let start = matches.first else { return nil }
        var end = start + 1
        if format == .yaml {
            while end < lines.count && (lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") || lines[end].hasPrefix("- ") || lines[end].isEmpty) { end += 1 }
        }
        return start..<end
    }
    private static func withoutComment(_ raw: String) -> String {
        var quoted: Character?, escaped = false, result = ""
        for c in raw {
            if escaped { escaped = false; result.append(c); continue }
            if quoted == "\"" && c == "\\" { escaped = true }
            else if c == quoted { quoted = nil }
            else if quoted == nil && (c == "\"" || c == "'") { quoted = c }
            else if quoted == nil && c == "#" && (result.isEmpty || result.last?.isWhitespace == true) { break }
            result.append(c)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
    private static func scalar(_ raw: String, format: BlogProfile.Format) throws -> String {
        let value = withoutComment(raw)
        if format == .toml && (value.hasPrefix("'''") || value.hasPrefix("\"\"\"")) {
            throw WriterError.message("編集対象のTOML文字列は1行の通常の引用符で指定してください。")
        }
        if value.hasPrefix("\"") { return try JSONDecoder().decode(String.self, from: Data(value.utf8)) }
        if value.hasPrefix("'"), value.hasSuffix("'") { return format == .yaml ? String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") : String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, !["{", "[", "!", "&", "*", "|", ">"].contains(where: value.hasPrefix) else {
            throw WriterError.message("編集対象のヘッダーは文字列・日付・文字列配列で指定してください。")
        }
        // TOML accepts bare datetime, but not unquoted arbitrary strings.
        if format == .toml && value.range(of: #"^\d{4}-\d{2}-\d{2}(?:[Tt ].*)?$"#, options: .regularExpression) == nil {
            throw WriterError.message("TOML の文字列には引用符を付けてください。")
        }
        return value
    }
    private static func rawValue(_ key: String, parts: Parts) throws -> (String, [String])? {
        let lines = parts.header.components(separatedBy: parts.newline)
        guard let range = try field(key, lines: lines, format: parts.format) else { return nil }
        let line = lines[range.lowerBound]
        let separator: Character = parts.format == .toml ? "=" : ":"
        guard let index = line.firstIndex(of: separator) else { return nil }
        return (String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces), Array(lines[(range.lowerBound + 1)..<range.upperBound]))
    }
    private static func value(_ key: String, parts: Parts) throws -> String {
        if let object = parts.object {
            guard let raw = object[key] else { return "" }
            guard let text = raw as? String else { throw WriterError.message("JSON の項目「\(key)」は文字列で指定してください。") }
            return text
        }
        guard let (raw, following) = try rawValue(key, parts: parts) else { return "" }
        if parts.format == .yaml && (raw.hasPrefix("|") || raw.hasPrefix(">")) {
            return following.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: raw.hasPrefix(">") ? " " : "\n").trimmingCharacters(in: .newlines)
        }
        return try scalar(raw, format: parts.format)
    }
    private static func tags(_ key: String?, parts: Parts) throws -> [String] {
        guard let key else { return [] }
        if let object = parts.object {
            guard let raw = object[key] else { return [] }
            guard let strings = raw as? [String] else { throw WriterError.message("タグは文字列配列で指定してください。") }
            return strings
        }
        guard let (raw, following) = try rawValue(key, parts: parts) else { return [] }
        let text = withoutComment(raw)
        if text.hasPrefix("[") {
            if let result = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) { return result }
            guard text.hasSuffix("]") else { throw WriterError.message("タグの配列を読み取れません。1行の配列で指定してください。") }
            var tokens: [String] = [], current = "", quoted: Character?, escaped = false
            for c in text.dropFirst().dropLast() {
                if c == ",", quoted == nil { tokens.append(current); current = ""; continue }
                current.append(c)
                if escaped { escaped = false }
                else if c == "\\", quoted == "\"" { escaped = true }
                else if c == quoted { quoted = nil }
                else if quoted == nil && (c == "'" || c == "\"") { quoted = c }
            }
            guard quoted == nil else { throw WriterError.message("タグの引用符を確認してください。") }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { tokens.append(current) }
            return try tokens.map { try scalar($0, format: parts.format) }
        }
        if parts.format == .yaml && text.isEmpty {
            return try following.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { throw WriterError.message("タグは文字列配列で指定してください。") }
                return try scalar(String(trimmed.dropFirst(2)), format: .yaml)
            }
        }
        throw WriterError.message("タグは文字列配列で指定してください。")
    }
    static func decode(path: String, sha: String, markdown: String, profile: BlogProfile = .current, configuration: SiteConfiguration = .current) throws -> Draft {
        try profile.validate()
        guard validPath(path, profile: profile) else { throw WriterError.message("記事の保存先がビルド設定と一致しません。") }
        let parsed = try parts(markdown), fields = profile.frontMatter.fields
        let title = try value(fields.title, parts: parsed)
        let description = try fields.description.map { try value($0, parts: parsed) } ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.frontMatter.requireDescription || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let date = profile.parseDate(try value(fields.date, parts: parsed)) else { throw WriterError.message("記事「\(path)」のタイトル・説明文・日付を読み取れません。") }
        let tags = try tags(fields.tags, parts: parsed).joined(separator: ", ")
        var draft = Draft(kind: tags.contains("曲紹介") || parsed.body.contains("open.spotify.com/embed/") ? .music : .diary)
        draft.blogProfile = profile
        let filename = (path as NSString).lastPathComponent
        if let range = filename.range(of: #"ios-([0-9a-fA-F-]{36})\.(?:md|markdown)$"#, options: .regularExpression), let id = UUID(uuidString: String(filename[range].dropFirst(4).split(separator: ".")[0])) { draft.id = id }
        else {
            let hash = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
            draft.id = UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
        }
        draft.title = title; draft.description = description; draft.date = date; draft.tags = tags; draft.body = parsed.body
        draft.updatedAt = date; draft.repositoryPath = path; draft.remoteSHA = sha
        draft.repositorySource = RepositorySource(markdown: markdown, title: title, description: description, date: date, tags: tags)
        let images = ArticleImageReferences.imported(from: markdown, profile: profile, configuration: configuration)
        if !images.isEmpty { draft.images = images }
        return draft
    }
    static func tagValues(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",、\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    // Expose supported root values without interpreting or rewriting unknown metadata.
    static func extraFields(_ markdown: String, profile: BlogProfile) -> [String: BlogProfile.Value] {
        guard let parsed = try? parts(markdown) else { return [:] }
        let fields = profile.frontMatter.fields
        let reserved = Set([fields.title, fields.date] + [fields.description, fields.tags].compactMap { $0 })
        let keys: [String]
        if let object = parsed.object { keys = Array(object.keys) }
        else {
            var lines = parsed.header.components(separatedBy: parsed.newline)
            if parsed.format == .toml, let table = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
                lines = Array(lines[..<table])
            }
            let pattern = parsed.format == .toml ? #"^[A-Za-z_][A-Za-z0-9_-]*(?=\s*=)"# : #"^[A-Za-z_][A-Za-z0-9_-]*(?=:)"#
            keys = lines.compactMap { line in
                line.range(of: pattern, options: .regularExpression).map { String(line[$0]) }
            }
        }
        var result: [String: BlogProfile.Value] = [:]
        for key in keys where !reserved.contains(key) && key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil {
            if let object = parsed.object {
                guard let raw = object[key], let bytes = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed),
                      let value = try? JSONDecoder().decode(BlogProfile.Value.self, from: bytes) else { continue }
                result[key] = value
            } else if let (raw, following) = try? rawValue(key, parts: parsed) {
                let text = withoutComment(raw)
                if text == "true" || text == "false" { result[key] = .bool(text == "true") }
                else if let number = Double(text), number.isFinite, abs(number) <= 9007199254740991 { result[key] = .number(number) }
                else if text.hasPrefix("[") || text.isEmpty && following.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }) {
                    if let list = try? tags(key, parts: parsed) { result[key] = .strings(list) }
                } else if text != "null" && text != "~", let value = try? value(key, parts: parsed) {
                    result[key] = .string(value)
                }
            }
        }
        return result
    }
    private static func values(_ draft: Draft) -> [(String, BlogProfile.Value)] {
        let profile = draft.profile, fields = profile.frontMatter.fields
        var result: [(String, BlogProfile.Value)] = [(fields.title, .string(draft.title))]
        if let key = fields.description { result.append((key, .string(draft.description))) }
        result.append((fields.date, .string(profile.dateText(draft.date))))
        if let key = fields.tags { result.append((key, .strings(tagValues(draft.tags)))) }
        return result
    }
    private static func line(_ key: String, _ value: BlogProfile.Value, format: BlogProfile.Format) -> String {
        // Quoted dates work in YAML, TOML, and JSON; keys are validated identifiers.
        key + (format == .toml ? " = " : ": ") + value.literal
    }
    static func newHeader(_ draft: Draft) -> String {
        let profile = draft.profile
        let fields = values(draft) + draft.extraHeaderFields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if profile.frontMatter.format == .json {
            return "{\n" + fields.map { "  " + Draft.yaml($0.0) + ": " + $0.1.literal }.joined(separator: ",\n") + "\n}\n"
        }
        let delimiter = profile.frontMatter.format == .toml ? "+++" : "---"
        return delimiter + "\n" + fields.map { line($0.0, $0.1, format: profile.frontMatter.format) }.joined(separator: "\n") + "\n" + delimiter + "\n"
    }
    static func render(_ draft: Draft, source: RepositorySource) -> String {
        guard let parsed = try? parts(source.markdown) else { return source.markdown }
        let fields = draft.profile.frontMatter.fields
        let changed = Set([
            draft.title != source.title ? fields.title : nil,
            draft.description != source.description ? fields.description : nil,
            draft.date != source.date ? fields.date : nil,
            draft.tags != source.tags ? fields.tags : nil
        ].compactMap { $0 })
        let originals = extraFields(source.markdown, profile: draft.profile)
        let extras = (draft.extraHeaderEdits ?? [:]).filter { originals[$0.key] != $0.value }.sorted { $0.key < $1.key }
        if changed.isEmpty && extras.isEmpty { return parsed.prefix + draft.body }
        let updates = values(draft).filter { changed.contains($0.0) } + extras.map { ($0.key, $0.value) }
        if var object = parsed.object {
            for (key, value) in updates { object[key] = try? JSONSerialization.jsonObject(with: Data(value.literal.utf8), options: .fragmentsAllowed) }
            guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), let header = String(data: bytes, encoding: .utf8) else { return source.markdown }
            return header.replacingOccurrences(of: "\n", with: parsed.newline) + parsed.newline + draft.body
        }
        var lines = parsed.header.components(separatedBy: parsed.newline)
        for (key, value) in updates {
            guard let existing = try? field(key, lines: lines, format: parsed.format) else {
                // Insert before the first TOML table, so it remains a root field.
                let index = parsed.format == .toml ? (lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count) : lines.count
                lines.insert(line(key, value, format: parsed.format), at: index)
                continue
            }
            lines.replaceSubrange(existing, with: [line(key, value, format: parsed.format)])
        }
        let delimiter = parsed.format == .toml ? "+++" : "---"
        return delimiter + parsed.newline + lines.joined(separator: parsed.newline) + parsed.newline + delimiter + parsed.newline + draft.body
    }
}
