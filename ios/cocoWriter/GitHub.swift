import Foundation
import Security

enum WriterError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum TokenVault {
    private static let service = "cocoWriter.GitHub"
    static func read() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw WriterError.message("Keychain から認証情報を読み出せません。") }
        return token
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal"]
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw WriterError.message("認証情報を削除できません。") }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw WriterError.message("Keychain に保存できません。") }
        } else if status != errSecSuccess { throw WriterError.message("Keychain を更新できません。") }
    }
}
actor GitHubPublisher {
    private let configuration: SiteConfiguration
    private let profile: BlogProfile
    struct RemoteFile: Decodable { let sha: String; let content: String?; let encoding: String? }
    struct PutResult: Decodable {
        struct File: Decodable { let sha: String }
        struct Commit: Decodable { let html_url: URL }
        let content: File
        let commit: Commit
    }
    struct Result { let sha: String; let commitURL: String?; var commitSHA: String? = nil }
    struct DeleteResult: Decodable { let commit: PutResult.Commit }
    enum DeletionError: LocalizedError {
        case changed
        var errorDescription: String? { "GitHub側で記事が変更されているため、削除していません。GitHubの記事と端末の内容を確認してください。" }
    }
    private let session: URLSession
    init(configuration: SiteConfiguration = .current, session: URLSession? = nil, profile: BlogProfile = .current) {
        self.configuration = configuration
        self.profile = profile
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: config)
    }
    private func request(path: String, token: String, method: String = "GET") throws -> URLRequest {
        if let message = configuration.connectionError { throw WriterError.message("設定で公開先を保存してください。" + message) }
        // Paths are validated article paths; encode path characters separately
        // from query/fragment characters, including imported file names.
        var components = URLComponents(string: "https://api.github.com/repos/\(configuration.repositorySlug)/contents")!
        components.path += "/" + path
        if method == "GET" { components.queryItems = [URLQueryItem(name: "ref", value: configuration.branch)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("cocoWriter", forHTTPHeaderField: "User-Agent")
        return request
    }
    private func getFile(path: String, token: String, ref: String? = nil) async throws -> RemoteFile? {
        var read = try request(path: path, token: token)
        var components = URLComponents(url: read.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ref", value: ref ?? configuration.branch)]
        read.url = components.url!
        let (data, response) = try await session.data(for: read)
        guard let response = response as? HTTPURLResponse else { throw WriterError.message("GitHub から応答がありません。") }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw failure(response.statusCode) }
        return try JSONDecoder().decode(RemoteFile.self, from: data)
    }
    private func get(_ draft: Draft, token: String) async throws -> RemoteFile? {
        try await getFile(path: draft.path, token: token)
    }
    private func matches(_ remote: RemoteFile?, markdown: String) -> Bool {
        guard let remote, remote.encoding == "base64", let encoded = remote.content, let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return false }
        return data == Data(markdown.utf8)
    }
    private func failure(_ status: Int) -> WriterError {
        switch status {
        case 401, 403: return .message("GitHub の認証・権限または利用制限を確認してください。下書きは残っています。")
        case 409, 422: return .message("GitHub 側で変更が競合しました。上書きしていません。GitHub と書き出した Markdown を確認してください。")
        default: return .message("GitHub がエラー \(status) を返しました。下書きは残っています。")
        }
    }
    private func validateDestination(_ draft: Draft) throws {
        if let error = BlogProfile.configurationError { throw WriterError.message(error) }
        guard draft.profile == profile else { throw WriterError.message("この記事のビルド設定が現在のアプリと異なります。元の設定でビルドしてください。") }
        try profile.validate()
        guard draft.referencedImages.allSatisfy({ profile.validImagePath($0.repositoryPath) && profile.imageReference(for: $0.repositoryPath, configuration: configuration) == $0.publicPath }) else {
            throw WriterError.message("画像の保存先・公開パスが記事のビルド設定と一致しません。画像を追加し直してください。")
        }
        if let target = draft.remoteDestination, target != configuration.destinationID {
            throw WriterError.message("この記事は別の投稿先に接続されています。元の公開先へ戻してから操作してください。")
        }
    }
    func publish(_ draft: Draft, token: String, imageFiles: ArticleImageFiles = ArticleImageFiles()) async throws -> Result {
        try validateDestination(draft)
        guard RepositoryArticleMarkdown.validPath(draft.path, profile: profile) else { throw WriterError.message("記事の保存先を確認できません。") }
        guard draft.pendingDeletionSHA == nil else { throw WriterError.message("公開記事の削除結果を先に確認してください。") }
        guard !token.isEmpty else { throw WriterError.message("設定で GitHub トークンを保存してください。") }
        guard let markdown = draft.pendingMarkdown else { throw WriterError.message("公開内容の確認が必要です。") }
        if !draft.referencedImages.isEmpty {
            return try await publishWithImages(draft, markdown: markdown, token: token, imageFiles: imageFiles)
        }
        let remote = try await get(draft, token: token)
        // A previous request may already have succeeded. Compare exact bytes
        // before another PUT; do not duplicate or overwrite a different version.
        if matches(remote, markdown: markdown) { return Result(sha: remote!.sha, commitURL: nil) }
        guard remote?.sha == draft.remoteSHA else { throw failure(409) }
        var body: [String: String] = ["message": "Post from cocoWriter", "content": Data(markdown.utf8).base64EncodedString(), "branch": configuration.branch]
        if let sha = draft.remoteSHA { body["sha"] = sha }
        var put = try request(path: draft.path, token: token, method: "PUT")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, response) = try await session.data(for: put)
            guard let response = response as? HTTPURLResponse else { throw WriterError.message("応答を確認できません。") }
            guard [200, 201].contains(response.statusCode) else { throw failure(response.statusCode) }
            let result = try JSONDecoder().decode(PutResult.self, from: data)
            return Result(sha: result.content.sha, commitURL: result.commit.html_url.absoluteString)
        } catch {
            if let reconciled = try? await get(draft, token: token), matches(reconciled, markdown: markdown) {
                return Result(sha: reconciled.sha, commitURL: nil)
            }
            throw WriterError.message("送信結果を確定できません。確認待ちの内容を保持しました。「結果を確認・再送」で GitHub の同一内容を照合してから処理します。\n\(error.localizedDescription)")
        }
    }
    private struct ObjectSHA: Decodable { let sha: String }
    private struct Reference: Decodable { let object: ObjectSHA }
    private struct GitCommit: Decodable { let tree: ObjectSHA }
    private struct CreatedCommit: Decodable { let sha: String; let html_url: String }
    private func gitAPI(_ suffix: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var call = try request(path: "", token: token, method: method)
        let path: [String]
        if suffix.hasPrefix("ref/heads/") { path = ["git", "ref", "heads", configuration.branch] }
        else if suffix.hasPrefix("refs/heads/") { path = ["git", "refs", "heads", configuration.branch] }
        else { path = ["git"] + suffix.split(separator: "/").map(String.init) }
        call.url = apiURL(path)
        if let body {
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: call)
        guard let response = response as? HTTPURLResponse, [200, 201].contains(response.statusCode) else {
            throw failure((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
    private func apiURL(_ path: [String], recursive: Bool = false) -> URL {
        var url = URLComponents(string: "https://api.github.com")!
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        url.percentEncodedPath = "/" + (["repos", configuration.owner, configuration.repository] + path)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        if recursive { url.queryItems = [URLQueryItem(name: "recursive", value: "1")] }
        return url.url!
    }
    private func head(token: String) async throws -> String {
        try JSONDecoder().decode(Reference.self, from: await gitAPI("ref/heads/\(configuration.branch)", token: token)).object.sha
    }
    private func remoteImage(_ image: ArticleImage, token: String, ref: String) async throws -> Data? {
        guard let remote = try await getFile(path: image.repositoryPath, token: token, ref: ref) else { return nil }
        guard remote.encoding == "base64", let content = remote.content,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
              PublicJPEG.hash(data) == image.hash, PublicJPEG.blobSHA(data) == remote.sha else {
            throw WriterError.message("GitHubの同名画像が異なる内容です。上書きしていません。")
        }
        try PublicJPEG.validate(data)
        return data
    }
    private func reconcileImages(_ draft: Draft, markdown: String, token: String) async throws -> Result? {
        let snapshot = try await head(token: token)
        guard let article = try await getFile(path: draft.path, token: token, ref: snapshot), matches(article, markdown: markdown) else { return nil }
        for image in draft.referencedImages {
            guard try await remoteImage(image, token: token, ref: snapshot) != nil else { return nil }
        }
        return Result(sha: article.sha, commitURL: nil, commitSHA: snapshot)
    }
    private func publishWithImages(_ draft: Draft, markdown: String, token: String, imageFiles: ArticleImageFiles) async throws -> Result {
        // Validate every local attachment before making any write request.
        var local: [String: Data] = [:]
        for image in draft.referencedImages {
            let url = try imageFiles.url(for: image)
            if FileManager.default.fileExists(atPath: url.path) { local[image.repositoryPath] = try imageFiles.read(image) }
        }
        let base = try await head(token: token)
        let article = try await getFile(path: draft.path, token: token, ref: base)
        var content: [String: Data] = [draft.path: Data(markdown.utf8)]
        var allImagesExist = true
        for image in draft.referencedImages {
            if let remote = try await remoteImage(image, token: token, ref: base) {
                if let bytes = local[image.repositoryPath], bytes != remote { throw failure(409) }
                content[image.repositoryPath] = remote
            } else {
                allImagesExist = false
                var bytes = local[image.repositoryPath]
                if bytes == nil, let ref = draft.imageCommitSHA, (draft.uploadedImagePaths ?? []).contains(image.repositoryPath) {
                    bytes = try await remoteImage(image, token: token, ref: ref)
                }
                guard let bytes else {
                    throw WriterError.message("写真の端末コピーもGitHubの画像も見つかりません。写真を追加し直してください。記事は送信していません。")
                }
                content[image.repositoryPath] = bytes
            }
        }
        if allImagesExist, matches(article, markdown: markdown) { return Result(sha: article!.sha, commitURL: nil, commitSHA: base) }
        guard article?.sha == draft.remoteSHA else { throw failure(409) }
        let parent = try JSONDecoder().decode(GitCommit.self, from: await gitAPI("commits/\(base)", token: token))
        do {
            var entries: [[String: String]] = []
            for path in content.keys.sorted() {
                let bytes = content[path]!
                let blob = try JSONDecoder().decode(ObjectSHA.self, from: await gitAPI("blobs", token: token, method: "POST",
                    body: ["content": bytes.base64EncodedString(), "encoding": "base64"]))
                guard blob.sha == PublicJPEG.blobSHA(bytes) else { throw WriterError.message("GitHubの保存内容が一致しません。公開していません。") }
                entries.append(["path": path, "mode": "100644", "type": "blob", "sha": blob.sha])
            }
            let tree = try JSONDecoder().decode(ObjectSHA.self, from: await gitAPI("trees", token: token, method: "POST",
                body: ["base_tree": parent.tree.sha, "tree": entries]))
            let commit = try JSONDecoder().decode(CreatedCommit.self, from: await gitAPI("commits", token: token, method: "POST",
                body: ["message": "Post article and photos from cocoWriter", "tree": tree.sha, "parents": [base]]))
            // Do not overwrite another client's work, including an article changing during uploads.
            guard try await head(token: token) == base else { throw failure(409) }
            _ = try await gitAPI("refs/heads/\(configuration.branch)", token: token, method: "PATCH", body: ["sha": commit.sha, "force": false])
            return Result(sha: PublicJPEG.blobSHA(Data(markdown.utf8)), commitURL: commit.html_url, commitSHA: commit.sha)
        } catch {
            if let result = try? await reconcileImages(draft, markdown: markdown, token: token) { return result }
            throw WriterError.message("送信結果を確定できません。記事と写真の確認待ち状態を保持しました。「結果を確認・再送」で同じ内容を照合してから処理します。\n\(error.localizedDescription)")
        }
    }
    func restoreImageCopies(_ draft: Draft, imageFiles: ArticleImageFiles, token: String) async throws {
        try validateDestination(draft)
        let ref = draft.imageCommitSHA ?? configuration.branch
        for image in draft.referencedImages {
            let url = try imageFiles.url(for: image)
            if FileManager.default.fileExists(atPath: url.path) { _ = try imageFiles.read(image); continue }
            guard let bytes = try await remoteImage(image, token: token, ref: ref) else {
                throw WriterError.message("GitHubから写真を取得できません。通信状態を確認してください。")
            }
            try FileManager.default.createDirectory(at: imageFiles.root, withIntermediateDirectories: true)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }
    // A file 404 can also mean lost repository access. Confirm that main is
    // accessible before interpreting it as a successful/previous deletion.
    private func deletionTarget(_ draft: Draft, token: String) async throws -> RemoteFile? {
        if let remote = try await get(draft, token: token) { return remote }
        var probe = try request(path: draft.path, token: token)
        probe.url = apiURL(["branches", configuration.branch])
        let (_, response) = try await session.data(for: probe)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw WriterError.message("GitHubの記事が見つかりませんが、リポジトリへのアクセスも確認できないため、削除済みとは判断していません。認証・権限を確認してください。")
        }
        return nil
    }
    func deletePublished(_ draft: Draft, token: String) async throws -> String? {
        try validateDestination(draft)
        guard RepositoryArticleMarkdown.validPath(draft.path, profile: profile) else { throw WriterError.message("記事の削除先を確認できません。") }
        guard !token.isEmpty else { throw WriterError.message("設定でGitHubトークンを保存してください。") }
        guard let sha = draft.pendingDeletionSHA, sha == draft.remoteSHA, draft.pendingMarkdown == nil else {
            throw WriterError.message("削除する公開記事の確認が必要です。")
        }
        guard let remote = try await deletionTarget(draft, token: token) else { return nil }
        guard remote.sha == sha else { throw DeletionError.changed }
        var deletion = try request(path: draft.path, token: token, method: "DELETE")
        deletion.setValue("application/json", forHTTPHeaderField: "Content-Type")
        deletion.httpBody = try JSONEncoder().encode(["message": "Remove published article from cocoWriter", "sha": sha, "branch": configuration.branch])
        do {
            let (data, response) = try await session.data(for: deletion)
            guard let response = response as? HTTPURLResponse else { throw WriterError.message("GitHubの応答を確認できません。") }
            guard response.statusCode == 200 else { throw failure(response.statusCode) }
            return try JSONDecoder().decode(DeleteResult.self, from: data).commit.html_url.absoluteString
        } catch {
            // Do not send another DELETE until the exact file is rechecked.
            do {
                if try await deletionTarget(draft, token: token) == nil { return nil }
            } catch { /* Keep the durable pending state when checking also fails. */ }
            throw WriterError.message("削除結果を確定できません。記事と削除の確認待ち状態を残しました。「削除結果を確認・再試行」で確認してください。\n\(error.localizedDescription)")
        }
    }
    func canCancelDeletion(_ draft: Draft, token: String) async throws -> Bool {
        try validateDestination(draft)
        guard !token.isEmpty else { throw WriterError.message("設定でGitHubトークンを保存してください。") }
        return try await deletionTarget(draft, token: token) != nil
    }
    struct Tree: Decodable {
        struct Entry: Decodable { let path: String; let type: String; let sha: String }
        let tree: [Entry]
        let truncated: Bool
    }
    private func readAPI(_ path: [String], token: String, recursive: Bool = false) async throws -> Data {
        var read = try request(path: "", token: token)
        read.url = apiURL(path, recursive: recursive)
        let (data, response) = try await session.data(for: read)
        guard let response = response as? HTTPURLResponse else { throw WriterError.message("GitHubの記事一覧を取得できません。") }
        guard response.statusCode == 200 else { throw failure(response.statusCode) }
        return data
    }
    func publishedArticles(token: String) async throws -> [Draft] {
        let tree = try JSONDecoder().decode(Tree.self, from: await readAPI(["git", "trees", configuration.branch], token: token, recursive: true))
        guard !tree.truncated else { throw WriterError.message("記事一覧を全件取得できませんでした。端末の内容は変更していません。") }
        var articles: [Draft] = []
        for entry in tree.tree where entry.type == "blob" && RepositoryArticleMarkdown.validPath(entry.path, profile: profile) {
            // Reading blobs by SHA keeps every body consistent with this tree,
            // even if another client changes main during the refresh.
            guard entry.sha.count == 40, entry.sha.allSatisfy({ $0.isHexDigit }) else { throw WriterError.message("記事のバージョンを確認できません。") }
            let blob = try JSONDecoder().decode(RemoteFile.self, from: await readAPI(["git", "blobs", entry.sha], token: token))
            guard blob.sha == entry.sha, blob.encoding == "base64", let encoded = blob.content,
                  let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), let markdown = String(data: bytes, encoding: .utf8) else {
                throw WriterError.message("記事「\(entry.path)」の本文を取得できません。")
            }
            var article = try RepositoryArticleMarkdown.decode(path: entry.path, sha: entry.sha, markdown: markdown, profile: profile, configuration: configuration)
            article.remoteDestination = configuration.destinationID
            articles.append(article)
        }
        return articles
    }
    func latestArticle(_ draft: Draft, token: String) async throws -> Draft {
        try validateDestination(draft)
        guard RepositoryArticleMarkdown.validPath(draft.path, profile: profile),
              let remote = try await get(draft, token: token), remote.encoding == "base64", let encoded = remote.content,
              let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), let markdown = String(data: bytes, encoding: .utf8) else {
            throw WriterError.message("GitHubの最新記事を取得できません。端末の編集中の内容は残っています。")
        }
        var article = try RepositoryArticleMarkdown.decode(path: draft.path, sha: remote.sha, markdown: markdown, profile: profile, configuration: configuration)
        article.remoteDestination = configuration.destinationID
        return article
    }
}
