import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import SwiftUI
import PhotosUI
import Markdown

struct ArticleImage: Codable, Equatable, Identifiable {
    var id: String { repositoryPath }
    let hash: String
    let repositoryPath: String
    let width: Int
    let height: Int
    let byteCount: Int
    // Retain the public reference when a later app build uses a different layout.
    var publishedPath: String? = nil
    var publicPath: String { publishedPath ?? BlogProfile.standard.publicPath(for: repositoryPath) ?? "" }
    var markdown: String { "![写真](\(publicPath))" }
    static func valid(_ path: String, profile: BlogProfile = .current) -> Bool { profile.validImagePath(path) }

}

struct PreparedImage {
    let data: Data
    let width: Int
    let height: Int
    let flattenedAnimation: Bool
}

enum PublicJPEG {
    static let maxDimension = 1600
    static let maxBytes = 800_000
    static let targetBytes = 400_000
    static let maxInputBytes = 150_000_000
    static func prepare(url: URL) throws -> PreparedImage {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maxInputBytes else { throw WriterError.message("画像は150MB以下のファイルを選んでください。") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw WriterError.message("この画像を読み込めません。写真アプリから選び直してください。元ファイルは送信していません。")
        }
        return try prepare(source: source)
    }
    static func prepare(data: Data) throws -> PreparedImage {
        guard !data.isEmpty, data.count <= maxInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw WriterError.message("画像を読み込めません。元ファイルは送信していません。")
        }
        return try prepare(source: source)
    }
    private static func prepare(source: CGImageSource) throws -> PreparedImage {
        guard let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true else {
            throw WriterError.message("静止画像を選んでください。動画は追加できません。")
        }
        // Always render from pixels, never use an embedded thumbnail or copy source properties.
        // Decode SDR before rendering into 8-bit sRGB to handle iPhone HDR pictures.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WriterError.message("JPEGへ変換できません。RAW画像は写真アプリから選び直してください。")
        }
        var best: PreparedImage?
        for dimension in [1600, 1280, 1024, 800] {
            let scale = min(1, Double(dimension) / Double(max(thumbnail.width, thumbnail.height)))
            let width = max(1, Int((Double(thumbnail.width) * scale).rounded()))
            let height = max(1, Int((Double(thumbnail.height) * scale).rounded()))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw WriterError.message("画像の変換に必要なメモリを確保できません。")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let pixels = context.makeImage() else { throw WriterError.message("画像を変換できません。") }
            for quality in [0.80, 0.70, 0.60] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw WriterError.message("JPEGを作成できません。")
                }
                CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw WriterError.message("JPEGの保存に失敗しました。") }
                let result = PreparedImage(data: try stripGeneratedMetadata(output as Data), width: width, height: height,
                    flattenedAnimation: CGImageSourceGetCount(source) > 1)
                if result.data.count <= maxBytes, best == nil { best = result }
                if result.data.count <= targetBytes { try validate(result.data); return result }
            }
        }
        guard let result = best else { throw WriterError.message("800KB以下へ縮小できませんでした。別の画像を選んでください。") }
        try validate(result.data)
        return result
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func blobSHA(_ data: Data) -> String {
        Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
    }
    private static func stripGeneratedMetadata(_ data: Data) throws -> Data {
        // Apple adds EXIF dimensions and a Photoshop resolution block even to newly
        // rendered pixels. Remove those generated APP segments before validation.
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { throw WriterError.message("JPEGの生成に失敗しました。") }
        var result = Data(bytes.prefix(2)), offset = 2
        while offset + 3 < bytes.count {
            let start = offset
            guard bytes[offset] == 0xff else { break }
            while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { break }
            let marker = bytes[offset]; offset += 1
            if marker == 0xda { result.append(contentsOf: bytes[start...]); return result }
            guard offset + 2 <= bytes.count else { break }
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard length >= 2, offset + length <= bytes.count else { break }
            if marker != 0xfe && (!(0xe0...0xef).contains(marker) || marker == 0xe0 || marker == 0xe2) {
                result.append(contentsOf: bytes[start..<(offset + length)])
            }
            offset += length
        }
        throw WriterError.message("JPEGのメタデータを除去できません。")
    }
    static func validate(_ data: Data) throws {
        func invalid() -> WriterError { .message("公開用JPEGの形式・容量・メタデータを確認できません。画像は送信していません。") }
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= maxDimension,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw invalid() }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary] {
            if properties[key] != nil { throw invalid() }
        }
        // ImageIO properties alone do not cover every XMP/comment segment.
        // Allow only JFIF and ICC APP markers; reject EXIF, XMP, IPTC and comments.
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { throw invalid() }
        var offset = 2
        while offset + 1 < bytes.count {
            guard bytes[offset] == 0xff else { throw invalid() }
            while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { throw invalid() }
            let marker = bytes[offset]; offset += 1
            if marker == 0xd9 {
                guard offset == bytes.count else { throw invalid() }
                return
            }
            guard marker != 0xfe, marker != 0xd8, offset + 2 <= bytes.count else { throw invalid() }
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard length >= 2, offset + length <= bytes.count else { throw invalid() }
            if marker >= 0xe0 && marker <= 0xef {
                let signature = marker == 0xe0 ? Array("JFIF\0".utf8) : Array("ICC_PROFILE\0".utf8)
                guard (marker == 0xe0 || marker == 0xe2), length >= signature.count + 2,
                      Array(bytes[(offset + 2)..<(offset + 2 + signature.count)]) == signature else { throw invalid() }
            }
            offset += length
            if marker == 0xda {
                // Entropy bytes use FF00 escapes and restart markers. Continue checking
                // every later scan/segment, including metadata following image data.
                while offset < bytes.count {
                    if bytes[offset] != 0xff { offset += 1; continue }
                    let start = offset
                    while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
                    guard offset < bytes.count else { throw invalid() }
                    let next = bytes[offset]
                    if next == 0 || (0xd0...0xd7).contains(next) { offset += 1; continue }
                    offset = start
                    break
                }
            }
        }
        throw invalid()
    }
}

struct ArticleImageFiles {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? AppConfiguration.current.storageURL("images")
    }
    func url(for image: ArticleImage) throws -> URL {
        guard BlogProfile.safePath(image.repositoryPath), image.hash.count == 64, image.hash.allSatisfy({ "0123456789abcdef".contains($0) }), image.repositoryPath.hasSuffix("/\(image.hash).jpg") else {
            throw WriterError.message("画像の保存先を確認できません。")
        }
        return root.appendingPathComponent(image.hash + ".jpg")
    }
    func save(_ prepared: PreparedImage, articleID: UUID, profile: BlogProfile = .current, configuration: SiteConfiguration = .current) throws -> ArticleImage {
        try PublicJPEG.validate(prepared.data)
        let hash = PublicJPEG.hash(prepared.data)
        try profile.validate()
        let path = profile.imagePath(id: articleID, hash: hash)
        guard let reference = profile.imageReference(for: path, configuration: configuration) else { throw WriterError.message("写真を追加する前に公開サイトURLを設定してください。") }
        let image = ArticleImage(hash: hash, repositoryPath: path,
            width: prepared.width, height: prepared.height, byteCount: prepared.data.count, publishedPath: reference)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try prepared.data.write(to: url(for: image), options: [.atomic, .completeFileProtectionUnlessOpen])
        return image
    }
    func read(_ image: ArticleImage) throws -> Data {
        let data = try Data(contentsOf: url(for: image))
        guard PublicJPEG.hash(data) == image.hash else { throw WriterError.message("保存した画像が変更されています。写真を追加し直してください。") }
        try PublicJPEG.validate(data)
        return data
    }
}

// Use the system photo picker: access only the selected photo, no library-wide permission.
// The compatible still representation includes Photos edits; no paired movie is requested.
struct ArticlePhotoPicker: UIViewControllerRepresentable {
    var started: () -> Void
    var completion: (Result<(PreparedImage, Bool), Error>?) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(started: started, completion: completion) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Result<(PreparedImage, Bool), Error>?) -> Void
        let started: () -> Void
        init(started: @escaping () -> Void, completion: @escaping (Result<(PreparedImage, Bool), Error>?) -> Void) {
            self.started = started; self.completion = completion
        }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { completion(nil); return }
            started()
            let live = provider.canLoadObject(ofClass: PHLivePhoto.self)
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                let result: Result<(PreparedImage, Bool), Error>
                do {
                    guard let url else { throw error ?? WriterError.message("写真を取得できません。iCloudの写真は通信状態を確認して再試行してください。") }
                    result = .success((try PublicJPEG.prepare(url: url), live))
                } catch { result = .failure(error) }
                DispatchQueue.main.async { self.completion(result) }
            }
        }
    }
}

@MainActor struct ArticleImagesSection: View {
    @Binding var draft: Draft
    @Binding var importing: Bool
    @EnvironmentObject private var store: DraftStore
    @Binding var photos: Bool
    @Binding var files: Bool
    @Binding var message: String?
    var body: some View {
        Section {
            ForEach(draft.attachedImages) { image in
                VStack(alignment: .leading, spacing: 8) {
                    if let data = try? store.imageFiles.read(image), let photo = UIImage(data: data) {
                        SwiftUI.Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 180).accessibilityLabel("追加した写真")
                    } else {
                        AsyncImage(url: store.site.publicAssetURL(for: image.publicPath)) { photo in
                            photo.resizable().scaledToFit().frame(maxHeight: 180)
                        } placeholder: { Label("公開済みの写真", systemImage: "photo") }
                    }
                    SwiftUI.Text(image.byteCount > 0 ? "JPEG · \(image.width)×\(image.height) · \(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))" : "公開済みのJPEG · 容量は取得時に確認")
                        .font(.caption).foregroundStyle(WriterPalette.secondary)
                    HStack {
                        Button("本文の末尾に挿入") { draft.body += "\n\n" + image.markdown + "\n" }
                        Spacer()
                        Button("取り外す", role: .destructive) {
                            draft.body = draft.body.replacingOccurrences(of: image.markdown, with: "")
                            // Preserve custom alt text by removing any Markdown node for this exact image.
                            draft.body = ArticleImageReferences.removing(image.publicPath, from: draft.body)
                            for index in draft.music.indices {
                                draft.music[index].comment = ArticleImageReferences.removing(image.publicPath, from: draft.music[index].comment)
                            }
                            if draft.markdown.contains(image.publicPath) {
                                message = "本文にこの画像への参照が残っています。本文から参照を削除してから取り外してください。"
                            } else { draft.images?.removeAll { $0.id == image.id } }
                        }
                    }.font(.caption).buttonStyle(.borderless)
                }
            }
            Button { photos = true } label: { Label("写真から追加", systemImage: "photo.on.rectangle") }
                .accessibilityIdentifier("article-add-photo")
            Button { files = true } label: { Label("画像ファイルから追加", systemImage: "folder") }
                .accessibilityIdentifier("article-add-image-file")
            if !draft.referencedImages.isEmpty {
                Button("写真を端末に保存してオフラインで使う") {
                    importing = true
                    Task {
                        store.beginRemoteOperation()
                        defer { importing = false; store.endRemoteOperation() }
                        do {
                            try await GitHubPublisher(configuration: store.site).restoreImageCopies(draft, imageFiles: store.imageFiles, token: (try? TokenVault.read()) ?? "")
                            message = "写真の端末コピーを保存しました。"
                        } catch { message = error.localizedDescription }
                    }
                }.font(.caption)
            }
            if importing { ProgressView("公開用の写真を作成中…") }
        } header: { SwiftUI.Text("写真") } footer: {
            SwiftUI.Text("JPEGに変換し、位置情報・撮影情報を除いて保存します。Live Photosとアニメーションは静止画1枚になります。透明部分は白背景になります。画像の説明は本文の「写真」を書き換えられます。")
        }
        .disabled(importing || draft.hasPendingOperation)
    }

}

struct ArticleBundle: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    let markdown: String
    let articlePath: String
    let imageData: [String: Data]
    init(draft: Draft, imageFiles: ArticleImageFiles) throws {
        markdown = draft.pendingMarkdown ?? draft.markdown
        articlePath = draft.path
        guard RepositoryArticleMarkdown.validPath(articlePath, profile: draft.profile) else { throw WriterError.message("記事の保存先を確認できません。") }
        var files: [String: Data] = [:]
        for image in draft.referencedImages { files[image.repositoryPath] = try imageFiles.read(image) }
        imageData = files
    }
    init(configuration: ReadConfiguration) throws { throw WriterError.message("記事フォルダの読み込みには対応していません。") }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        var files = imageData; files[articlePath] = Data(markdown.utf8)
        for (path, data) in files {
            var folder = root
            let parts = path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if let existing = folder.fileWrappers?[part] { folder = existing }
                else {
                    let created = FileWrapper(directoryWithFileWrappers: [:]); created.preferredFilename = part
                    folder.addFileWrapper(created); folder = created
                }
            }
            let file = FileWrapper(regularFileWithContents: data); file.preferredFilename = parts.last!
            folder.addFileWrapper(file)
        }
        return root
    }
}

enum ArticleImageReferences {
    struct Reference: Equatable {
        var source: String
        var caption: String
    }
    private struct Collector: MarkupVisitor {
        typealias Result = [Reference]
        mutating func defaultVisit(_ markup: Markup) -> [Reference] { markup.children.flatMap { visit($0) } }
        mutating func visitImage(_ image: Markdown.Image) -> [Reference] {
            image.source.map { [Reference(source: $0, caption: image.plainText)] } ?? []
        }
    }
    static func references(in markdown: String) -> [Reference] {
        var collector = Collector()
        return collector.visit(Document(parsing: markdown))
    }
    static func paths(in markdown: String) -> Set<String> { Set(references(in: markdown).map(\.source)) }
    static func imported(from markdown: String, profile: BlogProfile = .current, configuration: SiteConfiguration = .current) -> [ArticleImage] {
        paths(in: markdown).sorted().compactMap { path in
            guard let repositoryPath = profile.repositoryImageReference(path, configuration: configuration) else { return nil }
            let hash = String((repositoryPath as NSString).lastPathComponent.dropLast(4))
            return ArticleImage(hash: hash, repositoryPath: repositoryPath, width: 0, height: 0, byteCount: 0, publishedPath: path)
        }
    }
    static func removing(_ path: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: path)
        guard let regex = try? NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(\(escaped)\\)") else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

struct ArticleAlbumUse: Identifiable {
    var id: UUID { articleID }
    let articleID: UUID
    let title: String
    let date: Date
    let isPublished: Bool
    let tags: String
    let caption: String
    let image: ArticleImage?
    let remoteURL: URL?
}

struct ArticleAlbumPhoto: Identifiable {
    let id: String
    var uses: [ArticleAlbumUse]
}

enum ArticleAlbum {
    // Derive the album from actual Markdown references. Merely attaching a file,
    // removing it from the article, or moving the article to Trash must not leave
    // an unrelated photo in this view. There is no separate album database.
    static func photos(in drafts: [Draft], configuration: SiteConfiguration = .current,
                       shelf: ArticleShelf? = nil, query: String = "") -> [ArticleAlbumPhoto] {
        var result: [ArticleAlbumPhoto] = []
        var indexes: [String: Int] = [:]
        let articles = drafts.filter { $0.deletedAt == nil && (shelf == nil || $0.isPublished == (shelf == .published)) }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        for draft in articles {
            for reference in ArticleImageReferences.references(in: draft.pendingMarkdown ?? draft.markdown) {
                let image = draft.attachedImages.first { $0.publicPath == reference.source }
                let remoteURL = configuration.previewAssetURL(for: reference.source, profile: draft.profile)
                // A processed photo can occur at different paths in several articles.
                guard let key = image.map({ "local:" + $0.hash }) ?? remoteURL.map({ "remote:" + $0.absoluteString }) else { continue }
                let use = ArticleAlbumUse(articleID: draft.id, title: draft.displayTitle, date: draft.date,
                    isPublished: draft.isPublished, tags: draft.tags, caption: reference.caption, image: image, remoteURL: remoteURL)
                if let index = indexes[key] {
                    if !result[index].uses.contains(where: { $0.articleID == draft.id }) { result[index].uses.append(use) }
                } else {
                    indexes[key] = result.count
                    result.append(ArticleAlbumPhoto(id: key, uses: [use]))
                }
            }
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.filter { photo in
            query.isEmpty || photo.uses.contains { ($0.title + "\n" + $0.caption + "\n" + $0.tags).localizedStandardContains(query) }
        }
    }
}

@MainActor struct ArticleAlbumView: View {
    @EnvironmentObject private var store: DraftStore
    @State private var shelf: ArticleShelf?
    @State private var query = ""
    @State private var selected: ArticleAlbumPhoto?
    @State private var musicOpen = false
    private var photos: [ArticleAlbumPhoto] { ArticleAlbum.photos(in: store.drafts, configuration: store.site, shelf: shelf, query: query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("画像を使っている記事", selection: $shelf) {
                    SwiftUI.Text("すべて").tag(Optional<ArticleShelf>.none)
                    ForEach(ArticleShelf.allCases) { shelf in SwiftUI.Text(shelf.label).tag(Optional(shelf)) }
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8).accessibilityIdentifier("album-shelf")
                if let error = store.storageError { SwiftUI.Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 16) }
                ScrollView {
                    if photos.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "記事の写真はまだありません" : "画像が見つかりません",
                            systemImage: "photo.on.rectangle.angled",
                            description: SwiftUI.Text(query.isEmpty ? "記事の本文に挿入した画像が、ここに並びます。" : "記事名・写真の説明・タグを変えて探せます。"))
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 18) {
                            ForEach(photos) { photo in
                                Button { selected = photo } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        WriterPalette.surface.aspectRatio(1, contentMode: .fit)
                                            .overlay { ArticleAlbumImage(photo: photo, files: store.imageFiles, dimension: 400, contentMode: .fill) }
                                            .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                                        if let use = photo.uses.first {
                                            SwiftUI.Text(verbatim: use.title).font(.caption).foregroundStyle(WriterPalette.text).lineLimit(1)
                                            HStack(spacing: 4) {
                                                SwiftUI.Text(use.date, format: .dateTime.year().month().day())
                                                if photo.uses.count > 1 { SwiftUI.Text("· \(photo.uses.count)記事") }
                                            }.font(.caption2).foregroundStyle(WriterPalette.secondary).lineLimit(1)
                                        }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel((photo.uses.first?.caption ?? "写真") + " · " + (photo.uses.first?.title ?? ""))
                                    .accessibilityIdentifier("album-photo-" + photo.id)
                            }
                        }.padding(16)
                        SwiftUI.Text("\(photos.count)枚 · 記事に挿入した画像").font(.caption).foregroundStyle(WriterPalette.secondary).padding(.bottom, 16)
                    }
                }
            }.background(WriterPalette.background).writerChrome().navigationTitle("アルバム").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "記事名・写真の説明・タグ")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { musicOpen = true } label: { Image(systemName: "music.note.list") }
                            .accessibilityLabel("曲ストック").accessibilityIdentifier("album-open-music")
                    }
                }
                .sheet(item: $selected) { photo in ArticleAlbumDetail(photoID: photo.id).environmentObject(store) }
                .sheet(isPresented: $musicOpen) { MusicLibraryView(showsCloseButton: true) }
        }
    }
}

@MainActor private struct ArticleAlbumDetail: View {
    @EnvironmentObject private var store: DraftStore
    @Environment(\.dismiss) private var dismiss
    @State private var article: Draft?
    let photoID: String
    private var photo: ArticleAlbumPhoto? { ArticleAlbum.photos(in: store.drafts, configuration: store.site).first { $0.id == photoID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let photo {
                    VStack(alignment: .leading, spacing: 18) {
                        ArticleAlbumImage(photo: photo, files: store.imageFiles, dimension: 1600, contentMode: .fit)
                            .frame(maxWidth: .infinity).frame(height: 360)
                            .accessibilityLabel(photo.uses.first?.caption ?? "記事の写真")
                        if let caption = photo.uses.first?.caption, !caption.isEmpty, caption != "写真" {
                            SwiftUI.Text(verbatim: caption).font(.subheadline)
                        }
                        SwiftUI.Text("この画像を使っている記事").font(.subheadline.weight(.medium))
                        ForEach(photo.uses) { use in
                            Button {
                                article = store.drafts.first { $0.id == use.articleID && $0.deletedAt == nil }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        SwiftUI.Text(verbatim: use.title).font(.subheadline).foregroundStyle(WriterPalette.text)
                                        HStack {
                                            SwiftUI.Text(use.date, format: .dateTime.year().month().day())
                                            SwiftUI.Text(use.isPublished ? "投稿済み" : "下書き")
                                        }.font(.caption).foregroundStyle(WriterPalette.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(WriterPalette.secondary)
                                }.padding(12).background(WriterPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityIdentifier("album-open-article-" + use.articleID.uuidString)
                        }
                    }.padding(16)
                } else {
                    ContentUnavailableView("この記事の画像はありません", systemImage: "photo")
                }
            }.background(WriterPalette.background).writerChrome().navigationTitle("写真").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
                .sheet(item: $article) { draft in NavigationStack { EditorView(draft: draft) } }
        }
    }
}

private struct ArticleAlbumImage: View {
    let photo: ArticleAlbumPhoto
    let files: ArticleImageFiles
    let dimension: Int
    let contentMode: ContentMode
    @State private var localImage: UIImage?
    @State private var checkedLocal = false

    var body: some View {
        Group {
            if let localImage {
                SwiftUI.Image(uiImage: localImage).resizable().aspectRatio(contentMode: contentMode)
            } else if !checkedLocal {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = photo.uses.compactMap(\.remoteURL).first {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: contentMode)
                    case .failure: unavailable
                    default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else { unavailable }
        }.task(id: photo.id) {
            let images = photo.uses.compactMap(\.image)
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                for image in images {
                    guard let data = try? files.read(image), let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: dimension
                          ] as CFDictionary) else { continue }
                    return UIImage(cgImage: pixels)
                }
                return nil
            }.value
            guard !Task.isCancelled else { return }
            localImage = image; checkedLocal = true
        }
    }

    private var unavailable: some View {
        VStack(spacing: 6) {
            SwiftUI.Image(systemName: "photo").font(.title2)
            SwiftUI.Text("画像を読み込めません").font(.caption2)
        }.foregroundStyle(WriterPalette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
