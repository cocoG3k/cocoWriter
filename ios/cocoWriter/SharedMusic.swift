import Foundation

struct MusicItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var artist = ""
    var comment = ""
    // Legacy JSON key retained for drafts, stock and the share inbox. It stores any supported source URL.
    var youtubeURL = ""
    var spotifyURL = ""
    var confirmed = false
    var sourceID: UUID?
}
enum MusicService: String {
    case youtube, apple, amazon
    var name: String {
        switch self { case .youtube: return "YouTube Music"; case .apple: return "Apple Music"; case .amazon: return "Amazon Music" }
    }
}

struct MusicSourceLink: Equatable {
    let service: MusicService
    let url: URL
    let trackID: String?
    var country: String? = nil
    var isShort = false
    var cacheKey: String { url.absoluteString }
    var issue: String? {
        trackID == nil && !isShort ? "曲を特定できないURLです。アルバム全曲・プレイリストの変換には対応していません。曲の共有URLを使うか、曲名・アーティストを手入力し、Spotify検索・URL貼り付けで続けてください。" : nil
    }
}

enum SharedMusicLink {
    // Explicit regional hosts; never accept a suffix match on an arbitrary host.
    static let amazonHosts: Set<String> = Set(["com", "co.jp", "co.uk", "de", "fr", "it", "es", "ca", "com.au", "com.br", "com.mx", "in"].map { "music.amazon." + $0 })
    static func safeComponents(_ text: String) -> URLComponents? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.port == nil else { return nil }
        return c
    }
    private static func token(_ text: String, length: ClosedRange<Int>) -> Bool {
        length.contains(text.count) && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }
    }
    private static func number(_ text: String) -> Bool { (1...20).contains(text.count) && text.utf8.allSatisfy { (48...57).contains($0) } && text.contains(where: { $0 != "0" }) }
    private static func asin(_ text: String) -> Bool { text.count == 10 && text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) } }
    static func parse(_ text: String) -> MusicSourceLink? {
        guard var c = safeComponents(text), let host = c.host?.lowercased() else { return nil }
        c.host = host; c.fragment = nil
        let parts = c.path.split(separator: "/").map(String.init)
        // Repeated identity parameters are ambiguous, even when a provider happens to use the first one.
        func query(_ key: String) -> String? { let values = (c.queryItems ?? []).filter { $0.name == key }; return values.count == 1 ? values[0].value : nil }
        if ["apple.co", "amzn.to", "a.co"].contains(host) {
            guard (parts.count == 1 && token(parts[0], length: 3...64)) || (host == "a.co" && parts.count == 2 && parts[0] == "d" && token(parts[1], length: 3...64)) else { return nil }
            c.queryItems = nil
            return c.url.map { MusicSourceLink(service: host == "apple.co" ? .apple : .amazon, url: $0, trackID: nil, isShort: true) }
        }
        if host == "youtu.be" {
            guard parts.count == 1, token(parts[0], length: 11...11) else { return nil }
            return MusicSourceLink(service: .youtube, url: URL(string: "https://music.youtube.com/watch?v=" + parts[0])!, trackID: parts[0])
        }
        if ["music.youtube.com", "www.youtube.com", "youtube.com"].contains(host) {
            guard ["/watch", "/playlist"].contains(c.path) else { return nil }
            let key = c.path == "/watch" ? "v" : "list"
            guard let id = query(key), token(id, length: key == "v" ? 11...11 : 10...150) else { return nil }
            c.host = "music.youtube.com"; c.queryItems = [.init(name: key, value: id)]
            return c.url.map { MusicSourceLink(service: .youtube, url: $0, trackID: key == "v" ? id : nil) }
        }
        if host == "music.apple.com" {
            guard (3...4).contains(parts.count), parts[0].count == 2, parts[0].utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) }), ["song", "album", "playlist"].contains(parts[1]) else { return nil }
            let id: String?
            if parts[1] == "song" {
                guard number(parts.last!) else { return nil }
                if (c.queryItems ?? []).contains(where: { $0.name == "i" }), query("i") != parts.last! { return nil }
                id = parts.last!
            }
            else if parts[1] == "album" {
                guard number(parts.last!) else { return nil }
                if (c.queryItems ?? []).contains(where: { $0.name == "i" }) { guard let value = query("i"), number(value) else { return nil }; id = value } else { id = nil }
            } else { id = nil }
            let country = parts[0].lowercased()
            if let id { c.path = "/" + country + "/song/" + id } else { c.path = "/" + parts.joined(separator: "/") }
            c.queryItems = nil
            return c.url.map { MusicSourceLink(service: .apple, url: $0, trackID: id, country: country) }
        }
        if amazonHosts.contains(host) {
            guard parts.count == 2, ["tracks", "albums", "playlists"].contains(parts[0]) else { return nil }
            if parts[0] != "playlists", !asin(parts[1]) { return nil }
            let id: String?
            if parts[0] == "tracks" {
                if (c.queryItems ?? []).contains(where: { $0.name == "trackAsin" }), query("trackAsin") != parts[1] { return nil }
                id = parts[1]
            }
            else if parts[0] == "albums", (c.queryItems ?? []).contains(where: { $0.name == "trackAsin" }) {
                guard let value = query("trackAsin"), asin(value) else { return nil }; id = value
            } else { id = nil }
            c.path = id.map { "/tracks/" + $0 } ?? ("/" + parts.joined(separator: "/")); c.queryItems = nil
            return c.url.map { MusicSourceLink(service: .amazon, url: $0, trackID: id) }
        }
        return nil
    }
    // Kept for callers that specifically need a YouTube URL and old saved playlist links.
    static func youtube(_ text: String) -> URL? { guard let link = parse(text), link.service == .youtube else { return nil }; return link.url }
    static func extract(_ text: String) -> URL? {
        if let link = parse(text) { return link.url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let raw = match.url?.absoluteString, let link = parse(raw) { return link.url }
        }
        return nil
    }
}

struct SharedMusicRequest: Codable, Identifiable {
    var id = UUID()
    var item: MusicItem
    var createArticle = false
    var articleTitle = ""
    var introduction = ""
}

enum MusicShareInbox {
    static var groupID: String { AppConfiguration.current.appGroupIdentifier }
    static func directory(bundle: Bundle = .main) -> URL? {
        guard AppConfiguration.configurationError == nil else { return nil }
        // AltStore rewrites App Group identifiers and records them in ALTAppGroups.
        let rewritten = (bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? [])
            .filter { $0 == groupID || $0.hasPrefix(groupID + ".") }
        for id in rewritten + [groupID] {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return url.appendingPathComponent("MusicInbox", isDirectory: true)
            }
        }
        return nil
    }
    static func save(_ request: SharedMusicRequest, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent(request.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
