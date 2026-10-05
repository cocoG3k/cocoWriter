import SwiftUI
import UniformTypeIdentifiers

struct MarkdownFile: FileDocument {
    static let markdownType = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [markdownType] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
@MainActor struct EditorView: View {
    @EnvironmentObject private var store: DraftStore
    @EnvironmentObject private var musicLibrary: MusicLibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var draft: Draft
    @State private var choosingMusic = false
    @State private var preview = false
    @State private var expandedBody = false
    @State private var exporting = false
    @State private var exportingBundle = false
    @State private var bundleFile: ArticleBundle?
    @State private var showPublishConfirmation = false
    @State private var publishing = false
    @State private var importingImage = false
    @State private var photos = false
    @State private var files = false
    @State private var showReloadConfirmation = false
    @State private var message: String?
    private var publisher: GitHubPublisher { GitHubPublisher(configuration: store.site) }
    var body: some View {
        Form {
            Group {
                if let error = store.storageError { Section { Text(error).foregroundStyle(.red); Button("再保存") { store.persist() } } }
                if draft.pendingMarkdown != nil {
                    Section("送信結果の確認待ち") { Text("送信時の内容を保護するため編集を止めています。下のボタンで結果を確認してください。競合が続く場合は Markdown を書き出して GitHub 側と比較してください。") }
                }
                if draft.remoteChanged == true || (draft.remoteSHA != nil && draft.pendingMarkdown != nil) {
                    Section("GitHubの記事を確認") {
                        Text("端末の編集を別の下書きに残して、GitHubの最新記事を読み直せます。").font(.caption)
                        Button("編集の控えを残して最新を読み込む") { showReloadConfirmation = true }.disabled(publishing || store.storageError != nil)
                            .accessibilityIdentifier("article-load-latest")
                    }
                }
                Group {
                    Section("記事") {
                        TextField("タイトル", text: $draft.title, axis: .vertical).font(.headline)
                        TextField("一覧に表示する説明文", text: $draft.description, axis: .vertical)
                        DatePicker("記事の日付", selection: $draft.date, displayedComponents: .date).environment(\.locale, Locale(identifier: "ja_JP"))
                        TextField("タグ（カンマ区切り）", text: $draft.tags)
                    }
                    Section(draft.kind == .music && draft.repositorySource == nil ? "はじめに" : "本文 · Markdown") {
                        MarkdownEditor(text: $draft.body, minHeight: 150)
                        Button { expandedBody = true } label: { Label("本文を広く開く", systemImage: "arrow.up.left.and.arrow.down.right") }
                    }
                    ArticleImagesSection(draft: $draft, importing: $importingImage, photos: $photos, files: $files, message: $message)
                    if draft.kind == .music && draft.repositorySource == nil {
                        Section {
                            ForEach(draft.music) { item in
                                VStack(alignment: .leading) {
                                    MusicItemEditor(item: musicBinding(for: item)) { draft.music.removeAll { $0.id == item.id } }
                                    Button("この曲・紹介文をストックに保存") {
                                        var saved = item; saved.id = item.sourceID ?? item.id; saved.sourceID = nil
                                        if musicLibrary.update(saved) {
                                            if let index = draft.music.firstIndex(where: { $0.id == item.id }) { draft.music[index].sourceID = saved.id }
                                            message = "曲のストックに保存しました。"
                                        } else { message = musicLibrary.storageError }
                                    }.buttonStyle(.borderless).accessibilityIdentifier("music-save-stock-" + item.id.uuidString)
                                }
                            }
                                .onMove { draft.music.move(fromOffsets: $0, toOffset: $1) }
                                .onDelete { draft.music.remove(atOffsets: $0) }
                            Button { choosingMusic = true } label: { Label("ストックから選ぶ", systemImage: "music.note.list") }
                                .accessibilityIdentifier("music-choose-stock")
                            Button { draft.music.append(MusicItem()) } label: { Label("曲・アルバムを追加", systemImage: "plus.circle") }
                                .accessibilityIdentifier("music-add-item")
                        } header: { Text("曲・アルバム（掲載順）") } footer: { Text("各項目の「削除」で消せます。編集ボタンで並べ替えできます。") }
                    }
                }.disabled(publishing || draft.hasPendingOperation)
                Section {
                    Button { preview = true } label: { Label("プレビュー・Markdown を確認", systemImage: "doc.text.magnifyingglass") }
                    Button { exporting = true } label: { Label("Markdown を書き出す", systemImage: "square.and.arrow.up") }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.profile.frontMatter.requireDescription && draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !draft.referencedImages.isEmpty {
                        Button { Task { await exportArticleBundle() } } label: { Label("記事と写真をまとめて書き出す", systemImage: "folder.badge.plus") }
                            .disabled(publishing || importingImage || store.storageError != nil)
                        Text("Markdownだけの書き出しには写真ファイルが含まれません。").font(.caption).foregroundStyle(WriterPalette.secondary)
                    }
                    if let validation = draft.validation, draft.pendingMarkdown == nil { Text(validation).font(.caption).foregroundStyle(WriterPalette.secondary) }
                }
                Section {
                    Button { showPublishConfirmation = true } label: {
                        HStack { Label(draft.pendingMarkdown != nil ? "結果を確認・再送" : draft.isPublished ? "変更内容を確認" : "公開内容を確認", systemImage: "arrow.up.doc"); if publishing { Spacer(); ProgressView() } }
                    }.disabled(publishing || importingImage || draft.pendingDeletionSHA != nil || store.storageError != nil || (draft.pendingMarkdown == nil && draft.validation != nil))
                    if let url = draft.commitURL.flatMap(URL.init(string:)) { Link("GitHub のコミットを開く", destination: url) }
                    if let url = store.site.actionsURL { Link("サイトへの反映状況を確認", destination: url) }
                } footer: { Text("設定したブランチへ保存すると、サイト側の公開処理が始まります。GitHub への保存とサイトへの反映は別です。") }
            }.listRowBackground(WriterPalette.surface)
        }.writerCanvas()
        .environment(\.defaultMinListRowHeight, 36)
        .font(.subheadline)
        .scrollDismissesKeyboard(.interactively)
        .writerChrome().navigationTitle(draft.kind.label).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { if store.update(draft) { dismiss() } }.disabled(publishing || importingImage) }
            ToolbarItem(placement: .primaryAction) { if draft.kind == .music && draft.repositorySource == nil { EditButton().disabled(publishing || draft.hasPendingOperation) } }
        }
        .interactiveDismissDisabled(publishing || importingImage || store.storageError != nil)
        .onChange(of: draft) { _, value in _ = store.update(value) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { _ = store.update(draft) } }
        .sheet(isPresented: $photos) {
            ArticlePhotoPicker(started: { importingImage = true; photos = false }, completion: { result in
                photos = false
                defer { importingImage = false }
                guard let result else { return }
                switch result {
                case .success(let (prepared, live)): addImage(prepared, live: live)
                case .failure(let error): message = error.localizedDescription
                }
            })
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let url):
                importingImage = true
                Task {
                    let result = await Task.detached(priority: .userInitiated) { () -> Result<PreparedImage, Error> in
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return Result { try PublicJPEG.prepare(url: url) }
                    }.value
                    defer { importingImage = false }
                    switch result {
                    case .success(let prepared): addImage(prepared, live: false)
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            }
        }
        .sheet(isPresented: $choosingMusic) {
            MusicLibraryPicker(existing: draft.music) { draft.music.append(contentsOf: MusicLibraryStore.articleCopies($0)) }
        }
        .sheet(isPresented: $preview) { PreviewView(draft: draft) }
        .sheet(isPresented: $expandedBody) {
            NavigationStack {
                MarkdownEditor(text: $draft.body, identifier: "expanded-body-editor", minHeight: 280)
                    .padding(16).background(WriterPalette.background)
                    .writerChrome().navigationTitle(draft.kind == .music && draft.repositorySource == nil ? "はじめにを書く" : "本文を書く").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { expandedBody = false } } }
            }
        }
        .sheet(isPresented: $showPublishConfirmation) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("公開前の最終確認").font(.title2.bold())
                    Text("\(store.site.repositorySlug) · \(store.site.branch)\n\(draft.path)").font(.caption).textSelection(.enabled)
                    Text("以下の全文が GitHub に送信され、公開サイトに掲載されます。")
                    if !draft.referencedImages.isEmpty {
                        Text("写真 \(draft.referencedImages.count)枚 · 送信前にJPEGの容量とメタデータを検査します。").font(.caption)
                    }
                    ScrollView { Text(draft.pendingMarkdown ?? draft.markdown).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    Button("この内容を GitHub に保存・公開") { showPublishConfirmation = false; Task { await publish() } }.buttonStyle(.borderedProminent).foregroundStyle(WriterPalette.onAccent).frame(maxWidth: .infinity)
                }.padding().toolbar { Button("戻る") { showPublishConfirmation = false } }
            }
        }
        .fileExporter(isPresented: $exporting, document: MarkdownFile(text: draft.pendingMarkdown ?? draft.markdown), contentType: MarkdownFile.markdownType, defaultFilename: draft.filename) { result in
            if case .failure(let error) = result { message = "書き出せませんでした。\(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $exportingBundle, document: bundleFile, contentType: .folder, defaultFilename: "article-" + draft.id.uuidString.lowercased()) { result in
            if case .failure(let error) = result { message = "書き出せませんでした。\(error.localizedDescription)" }
        }
        .alert("お知らせ", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .confirmationDialog("端末の編集を別の下書きに残して、GitHubの最新記事を読み込みますか？", isPresented: $showReloadConfirmation, titleVisibility: .visible) {
            Button("控えを残して読み込む") { Task { await loadLatest() } }
            Button("キャンセル", role: .cancel) { }
        }
    }
    private func addImage(_ prepared: PreparedImage, live: Bool) {
        guard !draft.hasPendingOperation else { message = "送信結果の確認が終わってから写真を追加してください。"; return }
        do {
            let image = try store.imageFiles.save(prepared, articleID: draft.id, profile: draft.profile, configuration: store.site)
            if !draft.attachedImages.contains(where: { $0.id == image.id }) { draft.images = draft.attachedImages + [image] }
            draft.body += "\n\n" + image.markdown + "\n"
            if !store.update(draft) { message = store.storageError; return }
            message = live || prepared.flattenedAnimation ? "静止画として追加しました。元の写真・動画は変更していません。" : nil
        } catch { message = error.localizedDescription }
    }
    private func musicBinding(for item: MusicItem) -> Binding<MusicItem> {
        // Removed rows may finish updating their controls before SwiftUI tears them down.
        // Resolve by identity and keep their last value available instead of an array index.
        Binding(get: { draft.music.first { $0.id == item.id } ?? item }, set: { value in
            guard let index = draft.music.firstIndex(where: { $0.id == item.id }) else { return }
            draft.music[index] = value
        })
    }
    private func exportArticleBundle() async {
        store.beginRemoteOperation()
        defer { store.endRemoteOperation() }
        guard !publishing, !importingImage, store.persist() else { return }
        publishing = true
        defer { publishing = false }
        do {
            try await publisher.restoreImageCopies(draft, imageFiles: store.imageFiles, token: (try? TokenVault.read()) ?? "")
            bundleFile = try ArticleBundle(draft: draft, imageFiles: store.imageFiles)
            exportingBundle = true
        } catch { message = error.localizedDescription }
    }
    private func publish() async {
        store.beginRemoteOperation()
        defer { store.endRemoteOperation() }
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        do {
            if let error = store.site.connectionError { throw WriterError.message("公開先を設定してください。" + error) }
            let token = try TokenVault.read()
            guard !token.isEmpty else { throw WriterError.message("一覧の設定で GitHub トークンを保存してください。") }
            if draft.pendingMarkdown == nil { draft.repositoryPath = draft.path; draft.pendingMarkdown = draft.markdown; draft.remoteDestination = store.site.destinationID }
            guard store.update(draft) else { return }
            let result = try await publisher.publish(draft, token: token, imageFiles: store.imageFiles)
            var completed = draft
            completed.remoteSHA = result.sha
            completed.commitURL = result.commitURL
            completed.publishedMarkdown = draft.pendingMarkdown
            completed.pendingMarkdown = nil
            completed.uploadedImagePaths = completed.referencedImages.map(\.repositoryPath)
            completed.imageCommitSHA = result.commitSHA ?? completed.imageCommitSHA
            completed.remoteChanged = nil
            if completed.repositorySource != nil {
                completed.repositorySource = RepositorySource(markdown: completed.markdown, title: completed.title, description: completed.description, date: completed.date, tags: completed.tags)
            }
            draft = completed
            let saved = store.update(completed)
            message = saved ? "GitHub への保存を確認しました。サイトの反映はまだ確認していません。Actions で確認できます。" : "GitHub への保存は成功しましたが、端末の保存に失敗しています。アプリを閉じず再保存してください。"
        } catch { message = error.localizedDescription }
    }
    private func loadLatest() async {
        store.beginRemoteOperation()
        defer { store.endRemoteOperation() }
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        do {
            let latest = try await publisher.latestArticle(draft, token: (try? TokenVault.read()) ?? "")
            if let restored = store.keepEditsAndLoadLatest(latest) {
                draft = restored
                message = "GitHubの最新記事を読み込みました。編集の控えは下書きに残っています。"
            }
        } catch { message = error.localizedDescription }
    }
}
@MainActor struct MusicItemEditor: View {
    @Binding var item: MusicItem
    let onDelete: () -> Void
    @State private var resolving = false
    @State private var candidates: [MusicCandidate] = []
    @State private var resolutionMessage: String?
    @State private var requestGeneration = UUID()
    @State private var retry = 0
    @State private var showingSpotifyPicker = false
    @State private var manualSpotifyURL = ""
    private var lookupKey: String { item.youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines) + "|\(retry)" }
    private var selectedCandidate: MusicCandidate? { candidates.first { $0.id == item.spotifyURL } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("曲・アルバム名", text: $item.title).font(.headline)
                Button(role: .destructive, action: onDelete) {
                    Label("削除", systemImage: "trash").font(.caption)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel(item.title.isEmpty ? "この曲・アルバムを削除" : "\(item.title)を削除")
                    .accessibilityIdentifier("music-delete-\(item.id)")
            }
            TextField("アーティスト", text: $item.artist)
            TextField("YouTube Music の共有 URL（任意）", text: $item.youtubeURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            if !item.youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, MusicLink.youtube(item.youtubeURL) == nil {
                Text("YouTube Musicの曲URLを入力してください。").font(.caption).foregroundStyle(.red)
            }
            spotifySelection
            Text("この音についてのコメント").font(.caption).foregroundStyle(WriterPalette.secondary)
            MarkdownEditor(text: $item.comment, identifier: "music-comment-\(item.id)", minHeight: 100)
        }.font(.subheadline).padding(.vertical, 5)
            // Form otherwise treats automatic buttons/links in this VStack as one tappable row.
            .buttonStyle(.borderless)
            .sheet(isPresented: $showingSpotifyPicker) { spotifyPicker }
            .onChange(of: item.spotifyURL) { _, _ in item.confirmed = false }
            .onChange(of: item.youtubeURL) { _, _ in item.confirmed = false }
            .onChange(of: item.title) { _, _ in item.confirmed = false }
            .onChange(of: item.artist) { _, _ in item.confirmed = false }
            .task(id: lookupKey) { await resolveMusic() }
            .onDisappear { requestGeneration = UUID(); resolving = false }
    }
    private var spotifySelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Spotify", systemImage: "music.note").font(.subheadline.bold())
                Spacer()
                if SpotifyLink(item.spotifyURL) != nil {
                    Text(item.confirmed ? "確認済み" : "未確認").font(.caption).foregroundStyle(WriterPalette.secondary)
                }
            }
            if let link = SpotifyLink(item.spotifyURL) {
                HStack(alignment: .top, spacing: 10) {
                    candidateArtwork(selectedCandidate?.artworkURL, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedCandidate?.title ?? item.title).font(.subheadline.bold())
                        Text(selectedCandidate?.artist ?? item.artist).font(.caption).foregroundStyle(WriterPalette.secondary)
                    }
                }
                if let note = selectedCandidate?.matchNote { Text(note).font(.caption).foregroundStyle(WriterPalette.secondary) }
                HStack {
                    Link(destination: link.url) { Label("聴いて確認", systemImage: "play.circle") }
                        .accessibilityIdentifier("music-open-selected")
                    Spacer()
                    Button("変更") { showSpotifyPicker() }.accessibilityIdentifier("music-change-spotify")
                }
                Toggle("曲・バージョンを確認済み", isOn: $item.confirmed).font(.caption)
                    .accessibilityIdentifier("music-confirm-spotify")
            } else {
                if resolving {
                    HStack(spacing: 8) { ProgressView(); Text("候補を探しています…").font(.caption).foregroundStyle(WriterPalette.secondary) }
                } else if let resolutionMessage, candidates.isEmpty {
                    Text(resolutionMessage).font(.caption).foregroundStyle(WriterPalette.secondary)
                }
                if !item.spotifyURL.isEmpty { Text("SpotifyのURLを確認してください。").font(.caption).foregroundStyle(.red) }
                Button { showSpotifyPicker() } label: {
                    Label(candidates.isEmpty ? "Spotifyを選ぶ" : "候補から選ぶ（\(candidates.count)件）", systemImage: "magnifyingglass")
                }.buttonStyle(.bordered).accessibilityIdentifier("music-choose-spotify")
            }
        }.padding(12).background(WriterPalette.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    private func showSpotifyPicker() {
        manualSpotifyURL = item.spotifyURL
        showingSpotifyPicker = true
    }
    private var spotifyPicker: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        if resolving {
                            HStack { ProgressView(); Text("候補を探しています…") }.font(.subheadline)
                        }
                        if !candidates.isEmpty {
                            ForEach(candidates) { candidate in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top, spacing: 10) {
                                        candidateArtwork(candidate.artworkURL, size: 56)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(candidate.title).font(.subheadline.bold())
                                            Text(candidate.artist).font(.caption).foregroundStyle(WriterPalette.secondary)
                                            if !candidate.album.isEmpty { Text(candidate.album).font(.caption).foregroundStyle(WriterPalette.secondary) }
                                        }
                                    }
                                    if let note = candidate.matchNote { Text(note).font(.caption).foregroundStyle(WriterPalette.secondary) }
                                    HStack {
                                        Link(destination: candidate.spotify.url) { Label("Spotifyで聴く", systemImage: "play.circle") }
                                            .font(.subheadline).accessibilityIdentifier("music-open-candidate-" + candidate.spotify.id)
                                        Spacer()
                                        Button {
                                            item.title = candidate.title; item.artist = candidate.artist
                                            item.spotifyURL = candidate.id; item.confirmed = false
                                            showingSpotifyPicker = false
                                        } label: {
                                            if item.spotifyURL == candidate.id { Label("選択中", systemImage: "checkmark") }
                                            else { Text("選ぶ") }
                                        }.buttonStyle(.bordered).disabled(item.spotifyURL == candidate.id)
                                            .accessibilityIdentifier("spotify-candidate-" + candidate.spotify.id)
                                    }
                                }.padding(.vertical, 6)
                            }
                        } else if !resolving {
                            Text(resolutionMessage ?? "YouTube Musicの曲URLから候補を探せます。Spotifyで検索するか、共有URLを貼り付けても選べます。")
                                .font(.subheadline).foregroundStyle(WriterPalette.secondary)
                        }
                    } header: {
                        Text(candidates.isEmpty ? "候補" : "候補（\(candidates.count)件）")
                    } footer: {
                        if !candidates.isEmpty { Text("同じ曲でも録音やバージョンが違う場合があります。") }
                    }
                    Section("ほかの探し方") {
                        if MusicLink.search(title: item.title, artist: item.artist) != nil {
                            Menu {
                                if let search = MusicLink.search(title: item.title, artist: item.artist) {
                                    Link("曲名とアーティストで検索", destination: search).accessibilityIdentifier("music-search-spotify")
                                }
                                if let search = MusicLink.search(title: item.title, artist: ""), !item.artist.isEmpty {
                                    Link("曲名だけで検索", destination: search).accessibilityIdentifier("music-search-title")
                                }
                            } label: {
                                Label("Spotifyで検索", systemImage: "magnifyingglass")
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                                .accessibilityIdentifier("music-search-menu")
                        }
                        DisclosureGroup {
                            TextField("Spotify の曲・アルバム URL", text: $manualSpotifyURL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityIdentifier("music-manual-spotify-url")
                            if !manualSpotifyURL.isEmpty, SpotifyLink(manualSpotifyURL) == nil {
                                Text("Spotifyの曲・アルバムの共有URLを入力してください。").font(.caption).foregroundStyle(.red)
                            }
                            Button("このURLを使う") {
                                guard let link = SpotifyLink(manualSpotifyURL) else { return }
                                item.spotifyURL = link.url.absoluteString; item.confirmed = false
                                showingSpotifyPicker = false
                            }.disabled(SpotifyLink(manualSpotifyURL) == nil).accessibilityIdentifier("music-use-manual-spotify")
                        } label: { Text("SpotifyのURLを貼り付ける").accessibilityIdentifier("music-manual-spotify") }
                        if let youtube = MusicLink.youtube(item.youtubeURL) {
                            Button { retry += 1 } label: { Label("候補を再取得", systemImage: "arrow.clockwise") }
                                .disabled(resolving).accessibilityIdentifier("music-refresh-candidates")
                            Link("YouTube Musicで開く", destination: youtube).accessibilityIdentifier("music-open-youtube")
                        }
                    }
                }.listRowBackground(WriterPalette.surface)
            }.writerCanvas().buttonStyle(.borderless)
                .writerChrome().navigationTitle("Spotifyを選ぶ").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showingSpotifyPicker = false } } }
                .scrollDismissesKeyboard(.interactively)
        }
    }
    private func candidateArtwork(_ url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity).background(WriterPalette.secondary.opacity(0.1))
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
    }
    private func resolveMusic() async {
        let generation = UUID()
        requestGeneration = generation; candidates = []; resolutionMessage = nil; resolving = false
        let originalURL = item.youtubeURL
        guard let url = MusicLink.youtube(originalURL) else { return }
        guard MusicLink.videoID(url) != nil else { resolutionMessage = "プレイリストの一括変換には対応していません。曲の共有URLを貼り付けてください。"; return }
        do {
            try await Task.sleep(nanoseconds: 700_000_000)
            guard requestGeneration == generation, item.youtubeURL == originalURL else { return }
            resolving = true
            let result = try await (retry == 0 ? PublicMusicResolver.shared.resolve(url) : PublicMusicResolver.shared.refresh(url))
            try Task.checkCancellation()
            guard requestGeneration == generation, item.youtubeURL == originalURL else { return }
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.title = result.metadata.title }
            if item.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.artist = result.metadata.artist }
            candidates = result.candidates
            resolutionMessage = result.notice
        } catch {
            if !Task.isCancelled, requestGeneration == generation { resolutionMessage = error.localizedDescription }
        }
        if requestGeneration == generation { resolving = false }
    }
}
@MainActor struct PreviewView: View {
    let draft: Draft
    @EnvironmentObject private var store: DraftStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = false
    @State private var previewLoading = true
    @State private var previewError: String?
    var body: some View {
        NavigationStack {
            VStack {
                Picker("表示", selection: $source) { Text("サイト表示").tag(false); Text("Markdown 全文").tag(true) }.pickerStyle(.segmented).padding(.horizontal)
                if source {
                    ScrollView { Text(draft.pendingMarkdown ?? draft.markdown).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(24).textSelection(.enabled) }
                } else {
                    ZStack {
                        BlogWebPreview(draft: draft, loading: $previewLoading, error: $previewError, imageFiles: store.imageFiles, configuration: store.site)
                        if previewLoading { ProgressView("プレビューを作成中…") }
                        if let previewError { Text(previewError).font(.subheadline).padding(24) }
                    }
                    Text("下書きの表示確認です。公開・コメントの送信は行いません。")
                        .font(.caption2).foregroundStyle(WriterPalette.secondary).padding(.horizontal).padding(.bottom, 6)
                }
            }.writerChrome().navigationTitle("プレビュー").navigationBarTitleDisplayMode(.inline).toolbar { Button("閉じる") { dismiss() } }
        }
    }
}
@MainActor struct SettingsView: View {
    @EnvironmentObject private var store: DraftStore
    @State private var connection = SiteConfiguration()
    @State private var token = ""
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("このアプリ") {
                        Text("記事と自分用メモを、この端末でまとめます。").font(.subheadline)
                        Text("記事・メモは端末内に保存します。クラウド同期はありません。アプリを削除すると失われるため、大切な記事はMarkdownを書き出してください。").font(.caption).foregroundStyle(WriterPalette.secondary)
                    }
                    Section {
                        DisclosureGroup("GitHub公開の接続設定") {
                            TextField("GitHubユーザー名・組織名", text: $connection.owner)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("リポジトリ名", text: $connection.repository)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("ブランチ", text: $connection.branch)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("公開サイトURL (https://…/)", text: $connection.website)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("サイト名", text: $connection.title)
                            TextField("サイトの説明", text: $connection.tagline)
                            Text("記事: \(BlogProfile.current.articleDirectory.isEmpty ? "リポジトリ直下" : BlogProfile.current.articleDirectory)\n写真: \(BlogProfile.current.imageDirectory)\n画像公開パス: \(BlogProfile.current.imagePublicPath)\nヘッダー: \(BlogProfile.current.frontMatter.format.rawValue.uppercased())\nプロジェクトサイトのURLには /リポジトリ名/ を含めます。")
                                .font(.caption).foregroundStyle(WriterPalette.secondary)
                            if store.hasConnectedArticles {
                                Text("投稿済み・確認待ちの記事がある間は、ユーザー名・リポジトリ・ブランチを変更できません。")
                                    .font(.caption).foregroundStyle(WriterPalette.secondary)
                            }
                            Button("公開先の設定を保存") {
                                do { try store.saveSiteConfiguration(connection); connection = store.site; token = ""; message = "公開先を保存しました。" }
                                catch { message = error.localizedDescription }
                            }
                            Text("現在の公開先: \(store.site.connectionError == nil ? store.site.repositorySlug + " · " + store.site.branch : "未設定")").font(.caption)
                            SecureField("トークンを入力", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("この iPhone の Keychain に保存") {
                                do { guard store.site.connectionError == nil else { message = "先に公開先の設定を保存してください。"; return }; guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "トークンを入力してください。"; return }; try TokenVault.save(token); token = ""; message = "保存しました。公開するまで GitHub に送信しません。" } catch { message = error.localizedDescription }
                            }
                            Button("保存済みトークンを削除", role: .destructive) { do { try TokenVault.save(""); message = "削除しました。" } catch { message = error.localizedDescription } }
                            Text("接続する場合は、このリポジトリのContents: Read and writeだけを許可したFine-grained tokenを本人が入力します。自分用メモには公開機能がありません。").font(.caption).foregroundStyle(WriterPalette.secondary)
                            if !message.isEmpty { Text(message).font(.caption) }
                        }
                    }
                    Section("アプリ情報") {
                        NavigationLink { DependencyInfoView() } label: { Label("ライセンス", systemImage: "doc.text") }
                        Text("バージョン \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.1")").font(.caption).foregroundStyle(WriterPalette.secondary)
                    }
                    Section("写真の保存容量") {
                        Button("投稿済み写真の端末コピーを整理") {
                            do { let count = try store.clearPublishedImageCopies(); message = "\(count)枚の端末コピーを整理しました。公開画像は残り、必要なときに再取得できます。" }
                            catch { message = error.localizedDescription }
                        }
                        Text("未投稿・編集中・送信結果の確認待ちの写真は残します。元の写真アプリの画像は変更しません。").font(.caption).foregroundStyle(WriterPalette.secondary)
                        if !message.isEmpty { Text(message).font(.caption) }
                    }
                }.listRowBackground(WriterPalette.surface)
            }.writerCanvas().writerChrome().navigationTitle("設定").navigationBarTitleDisplayMode(.inline).environment(\.defaultMinListRowHeight, 36)
                .onAppear { connection = store.site }
                .onDisappear { token = "" }
        }
    }
}
