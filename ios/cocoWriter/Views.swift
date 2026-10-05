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
    @State private var composingMusic = false
    @State private var pendingEditorAction: EditorAttachmentAction?
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
    private var publisher: GitHubPublisher { GitHubPublisher(configuration: store.site, profile: draft.publicationProfile) }
    private var publishDisabled: Bool {
        publishing || importingImage || draft.pendingDeletionSHA != nil || store.storageError != nil || (draft.pendingMarkdown == nil && draft.validation != nil)
    }
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
                        if draft.canChangeCategory {
                            Picker("カテゴリ", selection: Binding(get: { draft.profile.articleDirectory }, set: { directory in
                                guard let category = store.enabledCategories.first(where: { $0.id == directory }) else { return }
                                do { try draft.selectCategory(category, configuration: store.site) }
                                catch { message = error.localizedDescription }
                            })) {
                                if !store.enabledCategories.contains(where: { $0.id == draft.profile.articleDirectory }) {
                                    Text(store.categoryLabel(for: draft) + "（現在の保存先）").tag(draft.profile.articleDirectory)
                                }
                                ForEach(store.enabledCategories) { category in Text(category.name).tag(category.id) }
                            }.accessibilityIdentifier("article-category")
                        } else {
                            LabeledContent("カテゴリ", value: store.categoryLabel(for: draft))
                        }
                        TextField("タイトル", text: $draft.title, axis: .vertical).font(.headline)
                        TextField("一覧に表示する説明文", text: $draft.description, axis: .vertical)
                        DatePicker("記事の日付", selection: $draft.date, displayedComponents: .date).environment(\.locale, Locale(identifier: "ja_JP"))
                        TextField("タグ（カンマ区切り）", text: $draft.tags)
                        if !store.tagSuggestions.isEmpty {
                            Menu {
                                ForEach(store.tagSuggestions, id: \.self) { tag in
                                    Button { draft.tags = ArticleTags.toggling(tag, in: draft.tags) } label: {
                                        Label(tag, systemImage: RepositoryArticleMarkdown.tagValues(draft.tags).contains(tag) ? "checkmark" : "plus")
                                    }
                                }
                            } label: { Label("タグ候補から選ぶ", systemImage: "tag") }
                                .accessibilityIdentifier("article-select-tags")
                        }
                    }
                    Section("本文 · Markdown") {
                        MarkdownEditor(text: $draft.body, minHeight: 150,
                                       onAddMusic: { requestEditorAction(.music) }, onChooseMusic: { requestEditorAction(.stock) },
                                       onAddPhoto: { requestEditorAction(.photo) }, onAddImageFile: { requestEditorAction(.imageFile) })
                        Button { expandedBody = true } label: { Label("本文を広く開く", systemImage: "arrow.up.left.and.arrow.down.right") }
                    }
                    if !draft.attachedImages.isEmpty { ArticleImagesSection(draft: $draft, importing: $importingImage, photos: $photos, files: $files, message: $message) }
                    if !draft.music.isEmpty {
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
                            Button { composingMusic = true } label: { Label("曲・アルバムを追加", systemImage: "plus.circle") }
                                .accessibilityIdentifier("music-add-item")
                        } header: { Text("曲紹介") } footer: {
                            Text("曲紹介は本文のあとに掲載します。各項目で削除でき、編集ボタンで並べ替えできます。")
                        }
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
                    }.disabled(publishDisabled)
                    if let url = draft.commitURL.flatMap(URL.init(string:)) { Link("GitHub のコミットを開く", destination: url) }
                    if let url = store.site.actionsURL { Link("サイトへの反映状況を確認", destination: url) }
                } footer: { Text("設定したブランチへ保存すると、サイト側の公開処理が始まります。GitHub への保存とサイトへの反映は別です。") }
            }.listRowBackground(WriterPalette.surface)
        }.writerCanvas()
        .environment(\.defaultMinListRowHeight, 36)
        .font(.subheadline)
        .scrollDismissesKeyboard(.interactively)
        .writerChrome().navigationTitle(draft.isPublished ? "記事を編集" : "記事を書く").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { if store.update(draft) { dismiss() } }.disabled(publishing || importingImage) }
            ToolbarItemGroup(placement: .primaryAction) {
                if !draft.music.isEmpty { EditButton().disabled(publishing || draft.hasPendingOperation) }
                Button { showPublishConfirmation = true } label: {
                    Group {
                        if publishing { ProgressView().tint(WriterPalette.onAccent) }
                        else { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                    }.frame(width: 24, height: 24)
                }
                .modifier(PublishButtonAppearance())
                .buttonBorderShape(.circle)
                .tint(WriterPalette.accent)
                .foregroundStyle(WriterPalette.onAccent)
                .disabled(publishDisabled)
                .accessibilityLabel(draft.pendingMarkdown != nil ? "Push・結果を確認して再送" : "Push・公開内容を確認")
                .accessibilityIdentifier("article-push")
            }
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
        .sheet(isPresented: $composingMusic) { ArticleMusicComposer { draft.music.append($0) } }
        .sheet(isPresented: $preview) { PreviewView(draft: draft) }
        .sheet(isPresented: $expandedBody, onDismiss: {
            if let action = pendingEditorAction { pendingEditorAction = nil; requestEditorAction(action) }
        }) {
            NavigationStack {
                MarkdownEditor(text: $draft.body, identifier: "expanded-body-editor", minHeight: 280,
                               onAddMusic: { requestEditorAction(.music) }, onChooseMusic: { requestEditorAction(.stock) },
                               onAddPhoto: { requestEditorAction(.photo) }, onAddImageFile: { requestEditorAction(.imageFile) })
                    .padding(16).background(WriterPalette.background)
                    .writerChrome().navigationTitle("本文を書く").navigationBarTitleDisplayMode(.inline)
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
    private enum EditorAttachmentAction { case music, stock, photo, imageFile }
    private func requestEditorAction(_ action: EditorAttachmentAction) {
        guard !publishing, !importingImage, !draft.hasPendingOperation else { return }
        if expandedBody { pendingEditorAction = action; expandedBody = false; return }
        switch action {
        case .music: composingMusic = true
        case .stock: choosingMusic = true
        case .photo: photos = true
        case .imageFile: files = true
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
private struct PublishButtonAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.buttonStyle(.glass(.regular.tint(WriterPalette.accent)))
        } else if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

@MainActor private struct ArticleMusicComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item = MusicItem()
    let onAdd: (MusicItem) -> Void
    private var hasContent: Bool {
        [item.title, item.artist, item.youtubeURL, item.spotifyURL, item.comment]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MusicItemEditor(item: $item, showsDelete: false) { }
                } footer: { Text("記事に追加したあとも編集できます。曲紹介は本文のあとに掲載します。") }
            }.writerCanvas().writerChrome().navigationTitle("曲紹介を書く").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("記事に追加") { onAdd(item); dismiss() }.disabled(!hasContent)
                            .accessibilityIdentifier("music-composer-add")
                    }
                }
        }
    }
}

@MainActor struct MusicItemEditor: View {
    @Binding var item: MusicItem
    var showsDelete = true
    let onDelete: () -> Void
    @State private var resolving = false
    @State private var candidates: [MusicCandidate] = []
    @State private var resolutionMessage: String?
    @State private var requestGeneration = UUID()
    @State private var retry = 0
    @State private var showingSpotifyPicker = false
    @State private var manualSpotifyURL = ""
    private var lookupKey: String { item.youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines) + "|\(retry)" }
    private var sourceMessage: String? {
        guard !item.youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let source = SharedMusicLink.parse(item.youtubeURL) else { return "対応する曲の共有URLを入力してください。手入力・Spotify検索・URL貼り付けでも続けられます。" }
        return source.issue
    }
    private var selectedCandidate: MusicCandidate? { candidates.first { $0.id == item.spotifyURL } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("曲・アルバム名", text: $item.title).font(.headline)
                if showsDelete { Button(role: .destructive, action: onDelete) {
                    Label("削除", systemImage: "trash").font(.caption)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel(item.title.isEmpty ? "この曲・アルバムを削除" : "\(item.title)を削除")
                    .accessibilityIdentifier("music-delete-\(item.id)") }
            }
            TextField("アーティスト", text: $item.artist)
            TextField("音楽サービスの曲の共有 URL（任意）", text: $item.youtubeURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Text("YouTube Music・Apple Music・Amazon Musicに対応。曲名・アーティストの手入力でも続けられます。").font(.caption).foregroundStyle(WriterPalette.secondary)
            if let message = sourceMessage { Text(message).font(.caption).foregroundStyle(.red) }
            if let resolutionMessage { Text(resolutionMessage).font(.caption).foregroundStyle(WriterPalette.secondary) }
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
                            Text(resolutionMessage ?? "YouTube Music・Apple Music・Amazon Musicの曲URLから候補を探せます。Spotifyで検索するか、共有URLを貼り付けても選べます。")
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
                        if let source = SharedMusicLink.parse(item.youtubeURL) {
                            Button { retry += 1 } label: { Label("候補を再取得", systemImage: "arrow.clockwise") }
                                .disabled(resolving).accessibilityIdentifier("music-refresh-candidates")
                            Link("\(source.service.name)で開く", destination: source.url).accessibilityIdentifier("music-open-source")
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
        guard let source = SharedMusicLink.parse(originalURL), source.issue == nil else { return }
        let url = source.url
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
                        NavigationLink { ArticleCategoriesSettingsView() } label: { Label("記事のカテゴリ・タグ", systemImage: "folder") }
                            .accessibilityIdentifier("settings-article-categories")
                        Text("使用中: " + store.enabledCategories.map(\.name).joined(separator: "、"))
                            .font(.caption).foregroundStyle(WriterPalette.secondary)
                        if let error = store.categorySettingsError { Text(error).font(.caption).foregroundStyle(.red) }
                    } footer: { Text("カテゴリごとの保存先・記事形式・項目名と、タグ候補を設定できます。書く記事のカテゴリは記事作成画面で選びます。") }
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
                            Text("記事と画像の保存先・記事形式は「記事のカテゴリ・タグ」で設定できます。プロジェクトサイトのURLには /リポジトリ名/ を含めます。")
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

@MainActor struct ArticleCategoriesSettingsView: View {
    @EnvironmentObject private var store: DraftStore
    @State private var categories: [ArticleCategory] = []
    @State private var editing: ArticleCategory?
    @State private var discovering = false
    @State private var message: String?
    @State private var initialized = false
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var tagMessage: String?
    var body: some View {
        Form {
            Section {
                ForEach(categories) { category in
                    HStack {
                        Button { toggle(category) } label: {
                            Image(systemName: category.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.title3).frame(width: 32, height: 36)
                        }.buttonStyle(.borderless).accessibilityLabel(category.name + "を" + (category.isEnabled ? "使わない" : "使う"))
                            .accessibilityIdentifier("category-toggle-" + category.id)
                        Button { editing = category } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(category.name).foregroundStyle(WriterPalette.text)
                                Text(category.id.isEmpty ? "リポジトリ直下" : category.id).font(.caption).foregroundStyle(WriterPalette.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Button {
                    var profile = categories.first(where: \.isEnabled)?.profile ?? BlogProfile.current; profile.articleDirectory = ""
                    editing = ArticleCategory(name: "", profile: profile)
                } label: { Label("カテゴリを追加", systemImage: "plus.circle") }
                    .accessibilityIdentifier("category-add")
                Button { Task { await discover() } } label: {
                    HStack { Label("GitHubから保存先を探す", systemImage: "arrow.clockwise"); if discovering { Spacer(); ProgressView() } }
                }.disabled(discovering || store.site.connectionError != nil)
                    .accessibilityIdentifier("category-discover")
            } header: { Text("カテゴリ · 保存先フォルダ") } footer: {
                Text("チェックしたカテゴリを記事作成画面に表示します。一覧の先頭が新しい下書きの初期カテゴリです。公開済みの記事の保存先は変わりません。")
            }
            Section {
                if categories.contains(where: \.isEnabled) {
                    Picker("新しい下書きのカテゴリ", selection: Binding(get: { categories.first(where: \.isEnabled)?.id ?? "" }, set: { directory in
                        guard let index = categories.firstIndex(where: { $0.id == directory }) else { return }
                        let category = categories.remove(at: index); categories.insert(category, at: 0)
                    })) {
                        ForEach(categories.filter(\.isEnabled)) { category in Text(category.name).tag(category.id) }
                    }.accessibilityIdentifier("category-default")
                }
                Text("カテゴリ名を開くと、記事・画像の保存先、記事形式、項目名を編集できます。変更は新しい記事に使い、保存済みの記事は元の設定を保ちます。")
                    .font(.caption).foregroundStyle(WriterPalette.secondary)
                Button("カテゴリ設定を保存") { save() }.disabled(discovering)
                    .accessibilityIdentifier("category-save")
                if let message { Text(message).font(.caption).foregroundStyle(WriterPalette.secondary) }
            }
            Section {
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Label(tag, systemImage: "tag")
                        Spacer()
                        Button(role: .destructive) { tags.removeAll { $0 == tag } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel(tag + "を候補から削除")
                    }
                }
                HStack {
                    TextField("タグを一つ追加（例: 散歩）", text: $newTag)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("tag-new")
                    Button { addTag() } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("タグ候補を追加")
                        .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("タグ候補を保存") { saveTags() }.accessibilityIdentifier("tag-save")
                if let tagMessage { Text(tagMessage).font(.caption).foregroundStyle(WriterPalette.secondary) }
            } header: { Text("タグ · 記事につけるラベル") } footer: {
                Text("記事作成画面から複数選べる候補です。記事ごとの自由入力もできます。タグを選んでも保存先フォルダは変わりません。候補を削除しても、既存の記事のタグは残ります。")
            }
        }.writerCanvas().writerChrome().navigationTitle("カテゴリとタグ").navigationBarTitleDisplayMode(.inline)
            .disabled(store.remoteOperations > 0 && !discovering)
            .onAppear { if !initialized { categories = store.categories; tags = store.tagSuggestions; initialized = true } }
            .sheet(item: $editing) { category in
                ArticleCategoryEditor(category: category) { updated in
                    if let index = categories.firstIndex(where: { $0.id == category.id && $0.name == category.name }) { categories[index] = updated }
                    else { categories.append(updated) }
                }
            }
    }
    private func toggle(_ category: ArticleCategory) {
        if let index = categories.firstIndex(where: { $0.id == category.id }) { categories[index].isEnabled.toggle() }
    }
    private func save() {
        do { try store.saveCategories(categories); categories = store.categories; message = "カテゴリ設定を保存しました。" }
        catch { message = error.localizedDescription }
    }
    private func addTag() {
        do { tags = try ArticleTags.normalized(tags + [newTag]); newTag = ""; tagMessage = nil }
        catch { tagMessage = error.localizedDescription }
    }
    private func saveTags() {
        do {
            let values = newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tags : tags + [newTag]
            try store.saveTagSuggestions(values); tags = store.tagSuggestions; newTag = ""; tagMessage = "タグ候補を保存しました。"
        } catch { tagMessage = error.localizedDescription }
    }
    private func discover() async {
        guard !discovering else { return }
        discovering = true; message = nil; store.beginRemoteOperation()
        defer { discovering = false; store.endRemoteOperation() }
        do {
            let directories = try await GitHubPublisher(configuration: store.site).articleDirectories(token: (try? TokenVault.read()) ?? "")
            var added = 0
            for directory in directories where !categories.contains(where: { $0.id == directory }) {
                var profile = categories.first(where: \.isEnabled)?.profile ?? BlogProfile.current; profile.articleDirectory = directory
                categories.append(ArticleCategory(name: ArticleCategory.suggestedName(for: directory), profile: profile, isEnabled: false)); added += 1
            }
            message = added == 0 ? "追加できる保存先はありませんでした。新しいフォルダは「カテゴリを追加」で登録できます。" : "\(added)件の保存先を追加しました。記事が入るフォルダにチェックを付けて保存してください。写真の保存先も必要に応じて確認できます。"
        } catch { message = error.localizedDescription }
    }
}

@MainActor private struct ArticleCategoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var category: ArticleCategory
    let onSave: (ArticleCategory) -> Void
    @State private var message: String?
    @State private var editingField: ArticleFixedField?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前（例: 日記、旅）", text: $category.name).accessibilityIdentifier("category-name")
                    TextField("記事の保存先（例: src/content/journey）", text: $category.profile.articleDirectory)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("category-directory")
                    Toggle("このカテゴリを使う", isOn: $category.isEnabled)
                } header: { Text("カテゴリ") } footer: { Text("リポジトリ内のフォルダを指定します。空欄はリポジトリ直下です。保存先を変えても、既存の記事は移動しません。") }
                Section {
                    TextField("画像の保存フォルダ", text: $category.profile.imageDirectory)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("category-image-directory")
                    TextField("画像の公開パス（例: /images/journey）", text: $category.profile.imagePublicPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("category-image-public-path")
                    Picker("画像リンクの形式", selection: $category.profile.imageReferenceStyle) {
                        Text("サイト内のパス").tag(BlogProfile.ImageReferenceStyle.siteRelative)
                        Text("サイトURLを含める").tag(BlogProfile.ImageReferenceStyle.absolute)
                    }
                } header: { Text("画像の保存先") } footer: { Text("公開サイトの構成に合わせて指定します。既存の画像は元の保存先・リンクを保ちます。") }
                ArticleFormatSettingsEditor(profile: $category.profile) { editingField = $0 }
                if let message { Section { Text(message).foregroundStyle(.red).font(.caption) } }
            }.writerCanvas().writerChrome().navigationTitle("カテゴリの設定").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            do {
                                category.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                category.profile.articleDirectory = category.profile.articleDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                                category.profile.imageDirectory = category.profile.imageDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                                category.profile.imagePublicPath = category.profile.imagePublicPath.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !category.name.isEmpty else { throw WriterError.message("カテゴリ名を入力してください。") }
                                try category.profile.validate(); onSave(category); dismiss()
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
        }.sheet(item: $editingField) { field in
            ArticleFixedFieldEditor(field: field) { key, value in
                var updated = category.profile
                if let original = field.originalKey { updated.frontMatter.extra.removeValue(forKey: original) }
                guard updated.frontMatter.extra[key] == nil else { throw WriterError.message("同じ名前の固定項目があります。") }
                updated.frontMatter.extra[key] = value
                try updated.validate(); category.profile = updated
            } onDelete: {
                if let original = field.originalKey { category.profile.frontMatter.extra.removeValue(forKey: original) }
            }
        }
    }
}

@MainActor private struct ArticleFormatSettingsEditor: View {
    @Binding var profile: BlogProfile
    @State private var excludedNames = ""
    let onEditField: (ArticleFixedField) -> Void
    var body: some View {
        Group {
            formatSection
            fieldsSection
            dateSection
            fixedFieldsSection
        }.onAppear { excludedNames = profile.excludedArticleNames.joined(separator: ", ") }
    }
    private var formatSection: some View {
        Section {
            Picker("ヘッダー形式", selection: $profile.frontMatter.format) {
                Text("YAML").tag(BlogProfile.Format.yaml)
                Text("TOML").tag(BlogProfile.Format.toml)
                Text("JSON").tag(BlogProfile.Format.json)
            }.accessibilityIdentifier("category-header-format")
            TextField("ファイル名（例: ios-{id}.md）", text: $profile.filenameTemplate)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("category-filename")
            Toggle(".md の記事を読み込む", isOn: extensionBinding("md"))
            Toggle(".markdown の記事を読み込む", isOn: extensionBinding("markdown"))
            TextField("一覧から除くファイル名（カンマ区切り）", text: $excludedNames)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: excludedNames) { _, value in profile.excludedArticleNames = RepositoryArticleMarkdown.tagValues(value) }
        } header: { Text("記事の形式") } footer: {
            Text("ファイル名には重複を防ぐ {id} を一つ入れます。日付は {date}、{year}、{month}、{day} が使えます。")
        }
    }
    private var fieldsSection: some View {
        Section {
            TextField("タイトルの項目名", text: $profile.frontMatter.fields.title).accessibilityIdentifier("category-title-field")
            TextField("日付の項目名", text: $profile.frontMatter.fields.date).accessibilityIdentifier("category-date-field")
            Toggle("説明文を保存する", isOn: Binding(get: { profile.frontMatter.fields.description != nil }, set: { enabled in
                profile.frontMatter.fields.description = enabled ? "description" : nil
                if !enabled { profile.frontMatter.requireDescription = false }
            }))
            if profile.frontMatter.fields.description != nil {
                TextField("説明文の項目名", text: Binding(get: { profile.frontMatter.fields.description ?? "" }, set: { profile.frontMatter.fields.description = $0 }))
                    .accessibilityIdentifier("category-description-field")
                Toggle("説明文を必須にする", isOn: $profile.frontMatter.requireDescription)
            }
            Toggle("タグを保存する", isOn: Binding(get: { profile.frontMatter.fields.tags != nil }, set: { profile.frontMatter.fields.tags = $0 ? "tags" : nil }))
            if profile.frontMatter.fields.tags != nil {
                TextField("タグの項目名", text: Binding(get: { profile.frontMatter.fields.tags ?? "" }, set: { profile.frontMatter.fields.tags = $0 }))
                    .accessibilityIdentifier("category-tags-field")
            }
        } header: { Text("ヘッダーの項目名") } footer: {
            Text("サイトが使う名前に合わせます。例えば説明文が summary のサイトでは、説明文の項目名を summary にします。タグを保存しない設定でも、端末内の下書きには残ります。")
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    private var dateSection: some View {
        Section {
            Picker("日付の形式", selection: $profile.frontMatter.dateStyle) {
                Text("年月日（2026-10-05）").tag(BlogProfile.DateStyle.date)
                Text("日時（ISO 8601）").tag(BlogProfile.DateStyle.iso8601)
                Text("日時（Jekyll）").tag(BlogProfile.DateStyle.jekyll)
            }
            TextField("タイムゾーン（例: Asia/Tokyo）", text: $profile.frontMatter.timeZone)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("日付") }
    }
    private var fixedFieldsSection: some View {
        Section {
            ForEach(profile.frontMatter.extra.keys.sorted(), id: \.self) { key in
                if let value = profile.frontMatter.extra[key] {
                    Button { onEditField(ArticleFixedField(originalKey: key, key: key, value: value)) } label: {
                        HStack { Text(key); Spacer(); Text(value.literal).font(.caption).foregroundStyle(WriterPalette.secondary).lineLimit(1); Image(systemName: "chevron.right").font(.caption) }
                    }
                }
            }
            Button { onEditField(ArticleFixedField(key: "", value: .string(""))) } label: { Label("固定項目を追加", systemImage: "plus.circle") }
        } header: { Text("固定で付ける項目") } footer: {
            Text("公開フラグなど、毎回同じ値を付ける項目です。変更した設定は、新しい記事に使います。プレビューの見た目はこのアプリのテーマを使います。")
        }
    }
    private func extensionBinding(_ value: String) -> Binding<Bool> {
        Binding(get: { profile.articleExtensions.contains(value) }, set: { enabled in
            profile.articleExtensions.removeAll { $0 == value }
            if enabled { profile.articleExtensions.append(value) }
        })
    }
}

private struct ArticleFixedField: Identifiable {
    var id = UUID()
    var originalKey: String?
    var key: String
    var value: BlogProfile.Value
}

@MainActor private struct ArticleFixedFieldEditor: View {
    private enum ValueType: String, CaseIterable { case text = "文字列", flag = "オン・オフ", number = "数値", list = "文字列のリスト" }
    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var type: ValueType
    @State private var text: String
    @State private var flag: Bool
    @State private var message: String?
    private let existing: Bool
    let onSave: (String, BlogProfile.Value) throws -> Void
    let onDelete: () -> Void
    init(field: ArticleFixedField, onSave: @escaping (String, BlogProfile.Value) throws -> Void, onDelete: @escaping () -> Void) {
        _key = State(initialValue: field.key); existing = field.originalKey != nil
        var initialType: ValueType = .text, initialText = "", initialFlag = false
        switch field.value {
        case .string(let value): initialText = value
        case .bool(let value): initialType = .flag; initialFlag = value
        case .number(let value): initialType = .number; initialText = String(value)
        case .strings(let value): initialType = .list; initialText = value.joined(separator: "\n")
        }
        _type = State(initialValue: initialType); _text = State(initialValue: initialText); _flag = State(initialValue: initialFlag)
        self.onSave = onSave; self.onDelete = onDelete
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("項目名（例: draft）", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("値の種類", selection: $type) { ForEach(ValueType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if type == .flag { Toggle("値（オン = true）", isOn: $flag) }
                    else { TextField(type == .list ? "一行に一つずつ入力" : "値", text: $text, axis: .vertical).autocorrectionDisabled() }
                }
                if existing { Section { Button("この固定項目を削除", role: .destructive) { onDelete(); dismiss() } } }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }.writerCanvas().writerChrome().navigationTitle("固定項目").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完了") { save() } }
                }
        }
    }
    private func save() {
        do {
            let value: BlogProfile.Value
            switch type {
            case .text: value = .string(text)
            case .flag: value = .bool(flag)
            case .number:
                guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite else { throw WriterError.message("数値を入力してください。") }
                value = .number(number)
            case .list: value = .strings(text.components(separatedBy: .newlines).filter { !$0.isEmpty })
            }
            try onSave(key.trimmingCharacters(in: .whitespacesAndNewlines), value); dismiss()
        } catch { message = error.localizedDescription }
    }
}
