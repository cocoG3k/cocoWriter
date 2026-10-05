import Foundation

struct MusicItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var artist = ""
    var comment = ""
    var youtubeURL = ""
    var spotifyURL = ""
    var confirmed = false
    var sourceID: UUID?
}
enum SharedMusicLink {
    static func youtube(_ text: String) -> URL? {
        guard var url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host?.lowercased() == "music.youtube.com", url.user == nil, url.password == nil, url.port == nil, ["/watch", "/playlist"].contains(url.path) else { return nil }
        let key = url.path == "/watch" ? "v" : "list"
        guard let id = url.queryItems?.first(where: { $0.name == key })?.value, (key == "v" ? id.count == 11 : (10...150).contains(id.count)), id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }) else { return nil }
        url.queryItems = [URLQueryItem(name: key, value: id)]; url.fragment = nil
        return url.url
    }
    // Share providers can send either a URL or a title followed by a URL.
    static func extract(_ text: String) -> URL? {
        if let url = youtube(text) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let raw = match.url?.absoluteString, let url = youtube(raw) { return url }
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
    static let groupID = "group.org.example.cocoWriter"
    static func directory(bundle: Bundle = .main) -> URL? {
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
