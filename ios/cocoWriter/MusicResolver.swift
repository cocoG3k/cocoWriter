import Foundation

struct MusicCandidate: Identifiable, Equatable {
    let spotify: SpotifyLink
    let title: String
    let artist: String
    let album: String
    var matchNote: String? = nil
    var artworkURL: URL? = nil
    var id: String { spotify.url.absoluteString }
}
struct MusicMetadata: Equatable {
    var title: String
    var artist: String
    var duration: Int?
}
struct MusicResolution {
    let metadata: MusicMetadata
    let candidates: [MusicCandidate]
    let notice: String?
}

enum MusicLink {
    static func youtube(_ text: String) -> URL? { SharedMusicLink.youtube(text) }
    static func videoID(_ url: URL) -> String? {
        guard url.path == "/watch" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
    }
    static func search(title: String, artist: String) -> URL? {
        let query = searchQuery(title: title, artist: artist)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://open.spotify.com/search")!
        let segment = query.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
        components.percentEncodedPath += "/" + segment
        return components.url
    }
    static func searchQuery(title: String, artist: String) -> String {
        [MusicPageParser.searchTitle(title), MusicPageParser.searchArtist(artist)].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// Reads public metadata only. No Spotify tokens, retired Odesli API, or private web APIs.
actor PublicMusicResolver {
    static let shared = PublicMusicResolver()
    private let session: URLSession
    private var nextMusicBrainzRequest = Date.distantPast
    private var nextAppleRequest = Date.distantPast
    private var cache: [String: (Date, MusicResolution)] = [:]
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: config)
    }
    func resolve(_ url: URL) async throws -> MusicResolution {
        guard MusicLink.youtube(url.absoluteString) != nil, let id = MusicLink.videoID(url) else {
            throw WriterError.message("曲の watch?v=… のURLを入力してください。プレイリストの一括変換には対応していません。")
        }
        if let cached = cache[id], Date().timeIntervalSince(cached.0) < 600 { return cached.1 }
        var metadata: MusicMetadata?
        var directLinks: [SpotifyLink] = []
        // Songlink's public page may contain a service mapping; its discontinued API is not used.
        do {
            let html = try await page(URL(string: "https://song.link/y/\(id)")!)
            let parsed = try MusicPageParser.songlink(html, videoID: id)
            metadata = parsed.0; directLinks = parsed.1
        } catch { try Task.checkCancellation() }
        if metadata == nil {
            var endpoint = URLComponents(string: "https://www.youtube.com/oembed")!
            endpoint.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"), URLQueryItem(name: "format", value: "json")]
            do { metadata = try MusicPageParser.oembed(await data(endpoint.url!)) }
            catch { try Task.checkCancellation(); throw WriterError.message("曲情報を取得できませんでした。通信や公開状態を確認し、再取得するか手入力してください。") }
        }
        let info = metadata!
        var candidates: [MusicCandidate] = []
        let notice: String?
        var plan = MusicSearchPlan(info)
        for link in directLinks.prefix(3) where link.kind == "track" {
            do {
                // The service mapping is useful even when the two stores localize names differently.
                if let candidate = try await verifiedTrack(link, plan: plan, album: "", mapped: true) { candidates.append(candidate) }
            } catch { try Task.checkCancellation() }
        }
        if candidates.isEmpty {
            candidates = try await musicBrainzCandidates(info, plan: plan)
        }
        if candidates.isEmpty {
            // The same Apple track ID connects Japanese and English catalog names without guessing a translation.
            plan = try await catalogAliases(for: info, plan: plan)
            if plan != MusicSearchPlan(info) { candidates = try await musicBrainzCandidates(info, plan: plan) }
        }
        notice = candidates.isEmpty ? "別表記でも検索しましたが、公開情報からSpotify候補を取得できませんでした。再取得するか、Spotifyで検索して共有URLを貼り付けてください。" : nil
        let result = MusicResolution(metadata: info, candidates: candidates, notice: notice)
        cache[id] = (Date(), result)
        return result
    }
    func refresh(_ url: URL) async throws -> MusicResolution {
        if let id = MusicLink.videoID(url) { cache[id] = nil }
        return try await resolve(url)
    }
    private func data(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        guard ["song.link", "www.youtube.com", "musicbrainz.org", "open.spotify.com", "itunes.apple.com"].contains(url.host ?? ""), url.scheme == "https" else { throw WriterError.message("取得先のURLが不正です。") }
        if url.host == "musicbrainz.org" {
            // Reserve each slot before awaiting; concurrent song rows still share the 1/sec limit.
            let start = max(Date(), nextMusicBrainzRequest)
            nextMusicBrainzRequest = start.addingTimeInterval(1.1)
            let delay = start.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        if url.host == "itunes.apple.com" {
            let start = max(Date(), nextAppleRequest)
            nextAppleRequest = start.addingTimeInterval(3.2)
            let delay = start.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        var request = URLRequest(url: url)
        request.setValue("cocoWriter/0.1 (iOS; personal blog writer)", forHTTPHeaderField: "User-Agent")
        // Consistent metadata language prevents translated artist names from breaking matching.
        if url.host == "open.spotify.com" { request.setValue("en", forHTTPHeaderField: "Accept-Language") }
        let (body, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, body.count < 3_000_000 else { throw WriterError.message("公開情報を取得できませんでした。") }
        return body
    }
    private func page(_ url: URL) async throws -> String {
        guard let html = String(data: try await data(url), encoding: .utf8) else { throw WriterError.message("ページを読み取れませんでした。") }
        return html
    }
    private func musicBrainz(_ path: String, items: [URLQueryItem]) async throws -> Data {
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/" + path)!
        url.queryItems = items + [URLQueryItem(name: "fmt", value: "json")]
        do { return try await data(url.url!) }
        catch {
            try Task.checkCancellation()
            // Public MusicBrainz searches occasionally return a temporary 503.
            return try await data(url.url!)
        }
    }
    private func musicBrainzCandidates(_ info: MusicMetadata, plan: MusicSearchPlan) async throws -> [MusicCandidate] {
        let quoted: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let searchTitles = plan.titles.flatMap { [$0, MusicPageParser.baseTitle($0)] }.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let titles = "(" + searchTitles.prefix(8).map { "recording:\(quoted($0))" }.joined(separator: " OR ") + ")"
        let artists = "(" + plan.artists.prefix(6).map { "artist:\(quoted($0))" }.joined(separator: " OR ") + ")"
        var recordings: [MBRecording] = []
        for query in [titles + " AND " + artists, titles] {
            do {
                let search = try JSONDecoder().decode(MBSearch.self, from: await musicBrainz("recording", items: [.init(name: "query", value: query), .init(name: "limit", value: "50")]))
                recordings = search.recordings.filter { recording in
                    plan.titleScore(recording.title) != nil && recording.artistNames.contains { plan.artistMatches($0) }
                }
                if !recordings.isEmpty { break }
            } catch { try Task.checkCancellation() }
        }
        recordings.sort { $0.rank(for: info) < $1.rank(for: info) }
        var expanded = plan
        var groups: [(id: String, priority: Int, note: String?)] = []
        for recording in recordings {
            expanded.addArtists(recording.artistNames)
            for release in recording.releases ?? [] {
                if let group = release.group {
                    if !groups.contains(where: { $0.id == group.id }) {
                        let types = group.secondaryTypes ?? []
                        let priority = (types.contains("Live") != MusicPageParser.isLive(info.title) ? 4 : 0) + (types.contains("Compilation") ? 2 : 0)
                        let note: String?
                        if let length = recording.length, let duration = info.duration, abs(length - duration) > 15_000 { note = "別録音・別バージョンの可能性があります。" }
                        else { note = nil }
                        groups.append((group.id, priority, note))
                    }
                }
            }
        }
        var candidates: [MusicCandidate] = []
        var checkedAlbums = Set<String>()
        // Bounded lookup: do not crawl every release/version of a recording.
        let orderedGroups = groups.enumerated().sorted { $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority }.map(\.element)
        for group in orderedGroups.prefix(6) {
            let releases: MBReleases
            do { releases = try JSONDecoder().decode(MBReleases.self, from: await musicBrainz("release", items: [.init(name: "release-group", value: group.id), .init(name: "inc", value: "url-rels"), .init(name: "limit", value: "100")])) }
            catch { try Task.checkCancellation(); continue }
            let albums = releases.releases.flatMap { ($0.relations ?? []).compactMap { SpotifyLink($0.url.resource) } }.filter { $0.kind == "album" }
            for album in albums where checkedAlbums.count < 6 {
                guard checkedAlbums.insert(album.id).inserted else { continue }
                do {
                    let html = try await page(album.url)
                    for track in MusicPageParser.albumTracks(html) where expanded.titleScore(track.title) != nil {
                        do {
                            if var candidate = try await verifiedTrack(track.link, plan: expanded, album: MusicPageParser.albumName(html)), !candidates.contains(where: { $0.id == candidate.id }) {
                                candidate.matchNote = candidate.matchNote ?? group.note
                                candidates.append(candidate)
                            }
                        } catch { try Task.checkCancellation() }
                    }
                } catch { try Task.checkCancellation() }
            }
            if candidates.count >= 3 || checkedAlbums.count >= 6 { break }
        }
        if candidates.isEmpty {
            var artistIDs = recordings.flatMap { $0.credits.compactMap { $0.artist?.id } }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if artistIDs.isEmpty {
                do {
                    let search = try JSONDecoder().decode(MBArtistSearch.self, from: await musicBrainz("artist", items: [.init(name: "query", value: quoted(info.artist)), .init(name: "limit", value: "5")]))
                    artistIDs = search.artists.filter { artist in ([artist.name] + (artist.aliases ?? []).map(\.name)).contains { expanded.artistMatches($0) } }.compactMap(\.id)
                } catch { try Task.checkCancellation() }
            }
            // Smaller catalogs may have only an artist-level Spotify relation, not links on each release.
            for artistID in artistIDs.prefix(2) {
                do {
                    let artist = try JSONDecoder().decode(MBArtist.self, from: await musicBrainz("artist/" + artistID, items: [.init(name: "inc", value: "url-rels")]))
                    expanded.addArtists([artist.name] + (artist.aliases ?? []).map(\.name))
                    let urls = (artist.relations ?? []).compactMap { MusicPageParser.spotifyArtistURL($0.url.resource) }
                    for url in urls.prefix(1) {
                        let html = try await page(url)
                        guard let name = MusicPageParser.structuredName("MusicGroup", in: html), expanded.artistMatches(name) else { continue }
                        for album in MusicPageParser.artistAlbums(html).prefix(6) {
                            do {
                                let albumHTML = try await page(album.url)
                                for track in MusicPageParser.albumTracks(albumHTML) where expanded.titleScore(track.title) != nil {
                                    do {
                                        if let candidate = try await verifiedTrack(track.link, plan: expanded, album: MusicPageParser.albumName(albumHTML)), !candidates.contains(where: { $0.id == candidate.id }) { candidates.append(candidate) }
                                    } catch { try Task.checkCancellation() }
                                }
                            } catch { try Task.checkCancellation() }
                            if candidates.count >= 3 { break }
                        }
                    }
                } catch { try Task.checkCancellation() }
                if !candidates.isEmpty { break }
            }
        }
        return Array(candidates.sorted { (expanded.titleScore($0.title) ?? 9) < (expanded.titleScore($1.title) ?? 9) }.prefix(6))
    }
    private func verifiedTrack(_ link: SpotifyLink, plan: MusicSearchPlan, album: String, mapped: Bool = false) async throws -> MusicCandidate? {
        let html = try await page(link.url)
        guard let track = MusicPageParser.spotifyTrack(html) else { return nil }
        let score = plan.titleScore(track.title)
        guard mapped || (score != nil && plan.artistMatches(track.artist)) else { return nil }
        let note = score == 0 && plan.artistMatches(track.artist) ? nil : "別表記・近い曲名の候補です。曲とバージョンを確認してください。"
        let artwork = MusicPageParser.meta("og:image", in: html).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" && url.host == "i.scdn.co" ? url : nil
        }
        return MusicCandidate(spotify: link, title: track.title, artist: track.artist, album: album, matchNote: note, artworkURL: artwork)
    }
    private func catalogAliases(for info: MusicMetadata, plan: MusicSearchPlan) async throws -> MusicSearchPlan {
        var expanded = plan
        var ids = Set<Int>()
        for country in ["JP", "US"] {
            do {
                var url = URLComponents(string: "https://itunes.apple.com/search")!
                url.queryItems = [.init(name: "term", value: MusicLink.searchQuery(title: info.title, artist: info.artist)), .init(name: "country", value: country), .init(name: "entity", value: "song"), .init(name: "limit", value: "15")]
                let results = try JSONDecoder().decode(AppleSearch.self, from: await data(url.url!)).results
                let matching = results.filter { plan.titleScore($0.trackName) != nil && plan.artistMatches($0.artistName) }.prefix(3)
                for track in matching { ids.insert(track.trackId); expanded.addTitles([track.trackName]); expanded.addArtists([track.artistName]) }
            } catch { try Task.checkCancellation() }
        }
        guard !ids.isEmpty else { return expanded }
        for country in ["JP", "US"] {
            do {
                var url = URLComponents(string: "https://itunes.apple.com/lookup")!
                url.queryItems = [.init(name: "id", value: ids.sorted().prefix(3).map(String.init).joined(separator: ",")), .init(name: "country", value: country)]
                let tracks = try JSONDecoder().decode(AppleSearch.self, from: await data(url.url!)).results
                for track in tracks where ids.contains(track.trackId) { expanded.addTitles([track.trackName]); expanded.addArtists([track.artistName]) }
            } catch { try Task.checkCancellation() }
        }
        return expanded
    }
}

struct MusicSearchPlan: Equatable {
    private(set) var titles: [String] = []
    private(set) var artists: [String] = []
    init(_ info: MusicMetadata) { addTitles([info.title]); addArtists([info.artist]) }
    mutating func addTitles(_ names: [String]) {
        for name in names {
            for variant in MusicPageParser.titleVariants(name) where !titles.contains(variant) { titles.append(variant) }
        }
    }
    mutating func addArtists(_ names: [String]) {
        for name in names {
            let cleaned = MusicPageParser.searchArtist(name)
            if !cleaned.isEmpty && !artists.contains(cleaned) { artists.append(cleaned) }
        }
    }
    func titleScore(_ title: String) -> Int? {
        let variants = MusicPageParser.titleVariants(title)
        if variants.contains(where: { candidate in titles.contains { MusicPageParser.sameTitle(candidate, $0) } }) { return 0 }
        let base = MusicPageParser.baseTitle(title)
        if !base.isEmpty && titles.contains(where: { MusicPageParser.sameTitle(base, MusicPageParser.baseTitle($0)) }) { return 1 }
        if titles.contains(where: { MusicPageParser.closeName(base, MusicPageParser.baseTitle($0)) }) { return 2 }
        return nil
    }
    func artistMatches(_ artist: String) -> Bool {
        artists.contains { MusicPageParser.sameArtist(MusicPageParser.searchArtist(artist), $0) }
    }
}

private struct AppleSearch: Decodable { let results: [AppleTrack] }
private struct AppleTrack: Decodable { let trackId: Int; let trackName: String; let artistName: String }
private struct MBSearch: Decodable { let recordings: [MBRecording] }
private struct MBRecording: Decodable {
    let title: String
    let length: Int?
    let disambiguation: String?
    let credits: [MBCredit]
    let releases: [MBRelease]?
    enum CodingKeys: String, CodingKey { case title, length, disambiguation, releases; case credits = "artist-credit" }
    var artist: String { credits.map(\.name).joined(separator: " ") }
    var artistNames: [String] { [artist] + credits.flatMap { [$0.name, $0.artist?.name ?? ""] + ($0.artist?.aliases ?? []).map(\.name) } }
    func rank(for info: MusicMetadata) -> Int {
        let liveMismatch = MusicPageParser.isLive(disambiguation ?? "") != MusicPageParser.isLive(info.title)
        return (liveMismatch ? 1_000_000 : 0) + abs((length ?? info.duration ?? 0) - (info.duration ?? length ?? 0))
    }
}
private struct MBCredit: Decodable { let name: String; let artist: MBArtist? }
private struct MBArtist: Decodable { let id: String?; let name: String; let aliases: [MBAlias]?; let relations: [MBRelation]? }
private struct MBArtistSearch: Decodable { let artists: [MBArtist] }
private struct MBAlias: Decodable { let name: String }
private struct MBReleases: Decodable { let releases: [MBRelease] }
private struct MBRelease: Decodable {
    let group: MBGroup?
    let relations: [MBRelation]?
    enum CodingKeys: String, CodingKey { case relations; case group = "release-group" }
}
private struct MBGroup: Decodable {
    let id: String
    let secondaryTypes: [String]?
    enum CodingKeys: String, CodingKey { case id; case secondaryTypes = "secondary-types" }
}
private struct MBRelation: Decodable { let url: MBURL }
private struct MBURL: Decodable { let resource: String }

enum MusicPageParser {
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) }
        }
    }
    static func unescape(_ text: String) -> String {
        var result = text
        for match in matches("&#(x[0-9a-f]+|[0-9]+);", in: text).reversed() {
            let raw = match[1]; let value = raw.lowercased().hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            if let value, let scalar = UnicodeScalar(value) { result = result.replacingOccurrences(of: match[0], with: String(scalar)) }
        }
        for (from, to) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] { result = result.replacingOccurrences(of: from, with: to) }
        return result
    }
    static func songlink(_ html: String, videoID: String) throws -> (MusicMetadata, [SpotifyLink]) {
        guard let json = matches("<script[^>]*id=\"__NEXT_DATA__\"[^>]*>(.*?)</script>", in: html).first?[1], let data = json.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let props = root["props"] as? [String: Any], let pageProps = props["pageProps"] as? [String: Any], let page = pageProps["pageData"] as? [String: Any], let entity = page["entityData"] as? [String: Any], entity["id"] as? String == videoID, entity["provider"] as? String == "youtube", let title = entity["title"] as? String, let artist = entity["artistName"] as? String, !title.isEmpty, !artist.isEmpty else { throw WriterError.message("曲情報がありません。") }
        let metadata = clean(title: title, artist: artist, duration: entity["duration"] as? Int)
        let links = (page["sections"] as? [[String: Any]] ?? []).flatMap { $0["links"] as? [[String: Any]] ?? [] }.filter { $0["platform"] as? String == "spotify" }.compactMap { ($0["url"] as? String).flatMap(SpotifyLink.init) }
        return (metadata, links)
    }
    static func oembed(_ data: Data) throws -> MusicMetadata {
        struct Embed: Decodable { let title: String; let author_name: String }
        let response = try JSONDecoder().decode(Embed.self, from: data)
        guard !response.title.isEmpty, !response.author_name.isEmpty else { throw WriterError.message("曲情報がありません。") }
        return clean(title: response.title, artist: response.author_name, duration: nil)
    }
    static func videoLabelsRemoved(_ title: String) -> String {
        var text = title.components(separatedBy: "　").map { $0.precomposedStringWithCompatibilityMapping }.joined(separator: "　")
        text = text.replacingOccurrences(of: "【公式】", with: "").replacingOccurrences(of: #"(?i)【4Kリマスター】"#, with: "", options: .regularExpression)
        let label = #"(?:(?:official|Japanese)\s+)?(?:music\s+video|audio\s+video|video|audio|mv|m/v|lyric(?:s|\s+video)?)"#
        text = text.replacingOccurrences(of: #"(?i)\s*[\(\[【［（]\s*"# + label + #"\s*[\)\]】］）]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\s*[-–—_]\s*official\s+(?:music\s+video|video|mv)(?=\)|$)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\s*(?:music\s*video|mv)\s*(?:\(\d{4}\))?\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*@\w+\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\s*(?:\(official\)|\(オフィシャル[・ ]ビデオ\)|\s+official)\s*$"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func clean(title: String, artist: String, duration: Int?) -> MusicMetadata {
        let originalArtist = searchArtist(artist)
        let title = videoLabelsRemoved(title)
        guard !originalArtist.isEmpty else { return MusicMetadata(title: title, artist: "", duration: duration) }
        // Video channels can be a label/publisher. Read explicit performer credits before searching.
        func credit(_ text: String) -> (artist: String, title: String)? {
            if let quoted = (matches(#"^(.+?)\s*(?:[-–—/:]\s*)?[\"「『“](.+?)[\"」』”](.*)$"#, in: text) + matches(#"^(.+?)\s+(?:[-–—/:]\s*)?'(.*?)'(.*)$"#, in: text)).first,
               quoted[1].range(of: #"\s[-–—]\s.*\S"#, options: .regularExpression) == nil {
                let name = quoted[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—/:"))).replacingOccurrences(of: #"(?i)\s+MV$"#, with: "", options: .regularExpression)
                let tail = quoted[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = matches(#"^(\([^)]*\))"#, in: tail).first?[1] ?? (isVersion(tail) ? tail : "")
                return (name, quoted[2] + (suffix.isEmpty ? "" : " " + suffix))
            }
            if let reversed = matches(#"^[\"“](.+?)[\"”]\s*//\s*(.+)$"#, in: text).first { return (reversed[2], reversed[1]) }
            if let split = matches(#"^(.+?)\s+(?:[-–—_]|/{1,2})\s+(.+)$"#, in: text).first {
                if !split[2].contains("("), sameArtist(split[2], originalArtist) { return (split[2], split[1]) }
                // A Japanese song followed by its Latin translation is not a performer credit.
                let script = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#
                let publisher = originalArtist.range(of: #"(?i)record|label|channel|music|entertainment|SPACE SHOWER|lute|KAKUBARHYTHM|UK\.PROJECT|P-VINE|felicity|kiti|apollosounds|matsuristudio|1theK|Sub Pop|CapturedTracks|Fuji Rock"#, options: .regularExpression) != nil
                if split[1].range(of: script, options: .regularExpression) != nil,
                   split[2].range(of: script, options: .regularExpression) == nil,
                   !sameArtist(split[1], originalArtist), !publisher { return nil }
                guard !isVersion(split[2]) || sameArtist(split[1], originalArtist) else { return nil }
                return (split[1], split[2])
            }
            // A few official channels use a chess symbol rather than a dash.
            if let split = matches(#"^(.+?)\s+♗\s*(.+)$"#, in: text).first, sameArtist(split[1], originalArtist) { return (split[1], split[2]) }
            return nil
        }
        let parts = title.components(separatedBy: " / ")
        let credits = parts.compactMap(credit)
        if parts.count > 1 && credits.count == parts.count {
            let performer = credits.contains { sameArtist($0.artist, originalArtist) } ? originalArtist : searchArtist(credits[0].artist)
            return MusicMetadata(title: credits.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " / "), artist: performer, duration: duration)
        }
        // Some Japanese/English credits are separated by an ideographic space.
        let wideParts = title.components(separatedBy: "　")
        let wideCredits = wideParts.compactMap(credit)
        if wideParts.count > 1 && wideCredits.count == wideParts.count {
            let performer = wideCredits.contains { sameArtist($0.artist, originalArtist) } ? originalArtist : searchArtist(wideCredits[0].artist)
            return MusicMetadata(title: wideCredits.map(\.title).joined(separator: " / "), artist: performer, duration: duration)
        }
        if let parsed = credit(title) {
            let performer = sameArtist(parsed.artist, originalArtist) && normalized(parsed.artist).contains(normalized(originalArtist)) ? originalArtist : searchArtist(parsed.artist)
            return MusicMetadata(title: parsed.title.trimmingCharacters(in: .whitespacesAndNewlines), artist: performer, duration: duration)
        }
        return MusicMetadata(title: title, artist: originalArtist, duration: duration)
    }
    static func searchTitle(_ title: String) -> String {
        // Featured credits and bilingual labels may differ; remix/live/version text is retained.
        let noFeature = title.replacingOccurrences(of: "(?i)\\s*\\((?:feat\\.?|ft\\.?)\\s+[^)]*\\)", with: "", options: .regularExpression).replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?)\s+.*$"#, with: "", options: .regularExpression)
        if noFeature.range(of: "[\\p{Han}\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil, let split = noFeature.range(of: " - "), !isVersion(String(noFeature[split.upperBound...])), noFeature[split.upperBound...].range(of: "[\\p{Han}\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) == nil { return String(noFeature[..<split.lowerBound]) }
        return noFeature
    }
    static func searchArtist(_ artist: String) -> String {
        artist.replacingOccurrences(of: "(?i)\\s*(?:-\\s*Topic|Official(?:\\s+YouTube)?(?:\\s+Channel)?|VEVO|\\s+channel|公式(?:YouTube)?チャンネル)\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func titleVariants(_ title: String) -> [String] {
        let cleaned = clean(title: title, artist: "", duration: nil).title.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var names = [searchTitle(cleaned)]
        // Keep both sides of a Japanese/Latin bilingual title, including parenthesized romanization.
        if cleaned.range(of: "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]", options: .regularExpression) != nil {
            let dashParts = cleaned.components(separatedBy: " - ")
            if !dashParts.dropFirst().contains(where: isVersion) {
                for part in dashParts where !part.isEmpty { names.append(part) }
            }
            for separator in [" / ", " | "] {
                for part in cleaned.components(separatedBy: separator) where !part.isEmpty && !isVersion(part) { names.append(part) }
            }
            for match in matches(#"^(.+?)\s*\(([^()]+)\)\s*$"#, in: cleaned) where !isVersion(match[2]) { names += [match[1], match[2]] }
            for match in matches(#"^([\p{Han}\p{Hiragana}\p{Katakana}\s●]+)\s+([A-Za-z][A-Za-z '’.-]+)$"#, in: cleaned) where !isVersion(match[2]) { names += [match[1], match[2]] }
        }
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    static func isVersion(_ text: String) -> Bool { text.range(of: "(?i)\\blive(?:\\d+)?\\b|remix|remaster|version|\\bver\\b|instrumental|acoustic|karaoke|ライブ|リミックス|カラオケ", options: .regularExpression) != nil }
    static func baseTitle(_ title: String) -> String {
        searchTitle(videoLabelsRemoved(title)).replacingOccurrences(of: #"(?i)\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}$"#, with: "", options: .regularExpression).replacingOccurrences(of: "\\s*[\\(\\[][^(\\[]*[\\)\\]]", with: "", options: .regularExpression).replacingOccurrences(of: "(?i)\\s+[-–—]\\s+.*(?:live|remix|remaster|version|\\bver\\b|instrumental|acoustic).*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func closeName(_ left: String, _ right: String) -> Bool {
        let a = Array(normalized(left)), b = Array(normalized(right))
        // Short/common titles must match exactly; fuzzy matches are displayed only as candidates.
        guard min(a.count, b.count) >= 6, abs(a.count - b.count) <= 2 else { return false }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var row = [i + 1]
            for (j, other) in b.enumerated() { row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1))) }
            previous = row
        }
        return previous[b.count] <= min(2, min(a.count, b.count) / 6)
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func sameTitle(_ left: String, _ right: String) -> Bool { normalized(searchTitle(left)) == normalized(searchTitle(right)) }
    static func sameArtist(_ left: String, _ right: String) -> Bool {
        let a = normalized(left), b = normalized(right)
        let words: (String) -> [String] = { $0.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }.filter { !$0.isEmpty }.sorted() }
        return !a.isEmpty && !b.isEmpty && (a == b || (words(left).count > 1 && words(left) == words(right)) || (min(a.count, b.count) >= 3 && (a.contains(b) || b.contains(a))))
    }
    static func isLive(_ text: String) -> Bool { text.range(of: "\\blive\\b|ライブ", options: [.regularExpression, .caseInsensitive]) != nil }
    static func albumTracks(_ html: String) -> [(link: SpotifyLink, title: String)] {
        matches("<a\\b[^>]*href=\"(?:https://open\\.spotify\\.com)?(/(?:intl-[a-z-]+/)?track/[A-Za-z0-9]{22})\"[^>]*>(.*?)</a>", in: html).compactMap { match in
            guard let link = SpotifyLink("https://open.spotify.com" + match[1]) else { return nil }
            let title = unescape(match[2].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (link, title)
        }
    }
    static func spotifyArtistURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text), components.scheme == "https", components.host == "open.spotify.com", components.user == nil, components.password == nil, components.port == nil else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.first?.hasPrefix("intl-") == true { parts.removeFirst() }
        guard parts.count == 2, parts[0] == "artist", parts[1].count == 22, parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return URL(string: "https://open.spotify.com/artist/" + parts[1])
    }
    static func artistAlbums(_ html: String) -> [SpotifyLink] {
        var seen = Set<String>()
        return matches("<a\\b[^>]*href=\"(?:https://open\\.spotify\\.com)?(/(?:intl-[a-z-]+/)?album/[A-Za-z0-9]{22})\"", in: html).compactMap { match in
            guard let link = SpotifyLink("https://open.spotify.com" + match[1]), seen.insert(link.id).inserted else { return nil }
            return link
        }
    }
    static func meta(_ name: String, in html: String) -> String? {
        for tag in matches("<meta\\b[^>]*>", in: html).map({ $0[0] }) {
            let attributes = matches("([a-z:_-]+)=\"([^\"]*)\"", in: tag)
            let values = Dictionary(attributes.map { ($0[1].lowercased(), unescape($0[2])) }, uniquingKeysWith: { first, _ in first })
            if values["property"] == name || values["name"] == name { return values["content"] }
        }
        return nil
    }
    static func structuredName(_ type: String, in html: String) -> String? {
        for script in matches("<script[^>]*type=\"application/ld\\+json\"[^>]*>(.*?)</script>", in: html) {
            guard let data = script[1].data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = object as? [[String: Any]] ?? (object as? [String: Any]).map { [$0] } ?? []
            for node in objects where node["@type"] as? String == type {
                if let name = node["name"] as? String, !name.isEmpty { return name }
            }
        }
        return nil
    }
    static func albumName(_ html: String) -> String { structuredName("MusicAlbum", in: html) ?? meta("og:title", in: html)?.replacingOccurrences(of: " - (?:Album|Single|EP) by .* \\| Spotify$", with: "", options: .regularExpression) ?? "" }
    static func spotifyTrack(_ html: String) -> MusicMetadata? {
        guard meta("og:type", in: html) == "music.song", let title = structuredName("MusicRecording", in: html) ?? meta("og:title", in: html), let description = meta("og:description", in: html), let artist = description.components(separatedBy: " · ").first, !artist.isEmpty else { return nil }
        return MusicMetadata(title: title, artist: artist, duration: nil)
    }
}
