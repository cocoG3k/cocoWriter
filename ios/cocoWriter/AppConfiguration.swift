import Foundation

/// Installation identity and storage are independent of the Xcode project name.
struct AppConfiguration: Codable, Equatable {
    struct Site: Codable, Equatable {
        var owner = ""
        var repository = ""
        var branch = "main"
        var website = ""
        var title = "My Journal"
        var tagline = "日々の記録と好きな音楽"
        var destinationID: String { (owner + "/" + repository).lowercased() + "@" + branch }
    }
    var schemaVersion = 1
    var storageDirectory = "cocoWriter"
    var keychainService = "cocoWriter.GitHub"
    var appGroupIdentifier = "group.org.example.cocoWriter"
    var defaultSite = Site()
    // Explicitly opt in when updating an older app whose articles have no destination metadata.
    var legacyDestinationID: String?

    static let standard = AppConfiguration()
    private static let loaded: Result<AppConfiguration, Error> = Result {
        guard let url = Bundle.main.url(forResource: "WriterConfiguration", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }
    static var current: AppConfiguration { (try? loaded.get()) ?? standard }
    static var configurationError: String? {
        if case .failure = loaded { return "アプリの保存先設定を読み込めません。既存データを保護するため保存を停止しました。" }
        return nil
    }
    static func decode(_ data: Data) throws -> AppConfiguration {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1,
              value.storageDirectory.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil,
              value.storageDirectory != ".", value.storageDirectory != "..",
              value.keychainService.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$"#, options: .regularExpression) != nil,
              value.appGroupIdentifier.range(of: #"^group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
              value.legacyDestinationID == nil || value.legacyDestinationID == value.defaultSite.destinationID,
              value.legacyDestinationID == nil || (!value.defaultSite.owner.isEmpty && !value.defaultSite.repository.isEmpty) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
    func storageURL(_ name: String, applicationSupport: URL? = nil) -> URL {
        let root = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent(storageDirectory, isDirectory: true).appendingPathComponent(name)
    }
}
