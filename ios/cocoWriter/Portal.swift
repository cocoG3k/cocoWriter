import SwiftUI

@MainActor struct DraftListView: View {
    @EnvironmentObject private var drafts: DraftStore
    @EnvironmentObject private var musicLibrary: MusicLibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var sharedDraft: Draft?
    @State private var editingSharedDraft: Draft?
    var body: some View {
        TabView(selection: $tab) {
            ArticleLibraryView().tabItem { Label("記事", systemImage: "doc.text") }.tag(0)
            MusicLibraryView().tabItem { Label("アルバム", systemImage: "photo.on.rectangle.angled") }.tag(3)
            PrivateNotesView().tabItem { Label("自分のメモ", systemImage: "note.text") }.tag(1)
            SettingsView().tabItem { Label("設定", systemImage: "gearshape") }.tag(2)
        }
        .safeAreaInset(edge: .top) {
            if let sharedDraft {
                HStack {
                    Text("共有した曲から下書きを作成しました").font(.caption)
                    Spacer()
                    Button("続きを書く") { editingSharedDraft = drafts.drafts.first { $0.id == sharedDraft.id }; self.sharedDraft = nil }
                    Button { self.sharedDraft = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("案内を閉じる")
                }.padding(12).writerBarBackground()
            }
        }
        .sheet(item: $editingSharedDraft) { draft in NavigationStack { EditorView(draft: draft) } }
        .task { receiveMusic() }
        .onChange(of: drafts.drafts) { _, _ in musicLibrary.reconcile(from: drafts) }
        .onChange(of: drafts.storageError) { _, error in if error == nil { musicLibrary.reconcile(from: drafts) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { receiveMusic() } }
    }
    private func receiveMusic() {
        if drafts.loaded { _ = musicLibrary.migrate(from: drafts.drafts) }
        musicLibrary.reconcile(from: drafts)
        if let directory = MusicShareInbox.directory() {
            let created = musicLibrary.importShares(from: directory, drafts: drafts)
            if let latest = created.last { sharedDraft = latest; tab = 0 }
        }
    }
}

@MainActor struct ArticleLibraryView: View {
    @EnvironmentObject private var store: DraftStore
    @State private var shelf: ArticleShelf = .drafts
    @AppStorage("article-filter-mode") private var filterMode: ArticleFilterMode = .tags
    @State private var selectedArticleTag: String?
    @State private var categoryFilter: String?
    @State private var destination: ArticleDestination?
    @State private var syncing = false
    @State private var syncError: String?
    @AppStorage("article-published-sort") private var publishedSort: PublishedArticleSort = .newest
    @State private var managing = false
    @State private var selection = Set<UUID>()
    @State private var message: String?
    private var items: [Draft] {
        ArticleLibrary.items(store.drafts, shelf: shelf, publishedSort: publishedSort)
            .filter { draft in
                switch filterMode {
                case .categories: return categoryFilter == nil || store.categoryID(for: draft) == categoryFilter
                case .tags: return selectedArticleTag.map { RepositoryArticleMarkdown.tagValues(draft.tags).contains($0) } ?? true
                }
            }
    }
    private var shelfItems: [Draft] {
        ArticleLibrary.items(store.drafts, shelf: shelf)
    }
    private var articleTags: [String] {
        var tags = Set(shelfItems.flatMap { RepositoryArticleMarkdown.tagValues($0.tags) })
        if let selectedArticleTag { tags.insert(selectedArticleTag) }
        return tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var trashCount: Int { store.drafts.filter { $0.deletedAt != nil }.count }
    private var publisher: GitHubPublisher { GitHubPublisher(configuration: store.site) }
    var body: some View {
        let items = self.items
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Picker("記事の状態", selection: $shelf) {
                        ForEach(ArticleShelf.allCases) { value in Text("\(value.label) \(ArticleLibrary.items(store.drafts, shelf: value).count)").tag(value) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("article-shelf")
                    HStack(spacing: 7) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                filterButton("全て \(shelfItems.count)", active: filterMode == .categories ? categoryFilter == nil : selectedArticleTag == nil) {
                                    selectedArticleTag = nil; categoryFilter = nil
                                }
                                    .accessibilityIdentifier("article-filter-all")
                                if filterMode == .categories {
                                    ForEach(store.categories) { category in
                                        filterButton(category.name + " \(shelfItems.filter { store.categoryID(for: $0) == category.id }.count)", active: categoryFilter == category.id) { categoryFilter = category.id }
                                            .accessibilityIdentifier("article-filter-category-" + category.id)
                                    }
                                } else {
                                    ForEach(articleTags, id: \.self) { tag in
                                        filterButton("#" + tag + " \(shelfItems.filter { RepositoryArticleMarkdown.tagValues($0.tags).contains(tag) }.count)", active: selectedArticleTag == tag) { selectedArticleTag = tag }
                                            .accessibilityIdentifier("article-filter-tag-" + tag)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Picker("記事の絞り込み", selection: $filterMode) {
                                ForEach(ArticleFilterMode.allCases) { mode in Text(mode.label).tag(mode) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Label(filterMode.label, systemImage: filterMode == .categories ? "folder" : "tag")
                                Image(systemName: "chevron.down")
                            }.font(.caption).fixedSize()
                        }
                        .accessibilityLabel("絞り込み方法・" + filterMode.label)
                        .accessibilityHint("カテゴリまたはタグを選べます")
                        .accessibilityIdentifier("article-filter-mode")
                    }
                    Button { create() } label: { Label("記事を書く", systemImage: "square.and.pencil").font(.subheadline).frame(maxWidth: .infinity, minHeight: 28) }
                        .buttonStyle(.bordered).disabled(!store.loaded || managing || syncing)
                        .accessibilityIdentifier("article-create")
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
                List {
                    Group {
                        if syncing { HStack { ProgressView(); Text("GitHubの記事を読み込み中…").font(.caption) } }
                        if let syncError { Text(syncError).font(.caption).foregroundStyle(.red) }
                        if let error = store.storageError {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("再保存") { store.persist() }
                        }
                        if items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: shelf == .drafts ? "doc.badge.plus" : "checkmark.circle").font(.title2).foregroundStyle(WriterPalette.secondary)
                                Text(shelf == .drafts ? "該当する下書きはありません" : "該当する投稿済みの記事はありません").font(.subheadline)
                            }.frame(maxWidth: .infinity).padding(.vertical, 28).listRowSeparator(.hidden).listRowBackground(Color.clear)
                        }
                        ForEach(items) { draft in
                            Button {
                                if managing { if selection.contains(draft.id) { selection.remove(draft.id) } else if !draft.hasPendingOperation { selection.insert(draft.id) } }
                                else if draft.pendingDeletionSHA != nil { destination = .deletion(draft.id) }
                                else { destination = .editor(draft) }
                            } label: {
                                CompactArticleRow(draft: draft, category: store.categoryLabel(for: draft), selecting: managing, selected: selection.contains(draft.id))
                            }.buttonStyle(.plain).disabled(syncing).listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                .accessibilityIdentifier("article-row-" + draft.id.uuidString)
                                .accessibilityLabel("\(draft.displayTitle)、\(store.categoryLabel(for: draft))、\(draft.pendingMarkdown != nil ? "送信結果の確認待ち" : shelf.label)")
                                .accessibilityValue(selection.contains(draft.id) ? "選択済み" : "")
                                .swipeActions(edge: .trailing, allowsFullSwipe: shelf == .drafts) {
                                    if shelf == .published {
                                        Button(role: .destructive) { destination = .deletion(draft.id) } label: { Label("サイトから削除", systemImage: "trash") }.disabled(managing || syncing)
                                    } else {
                                        Button(role: .destructive) { remove([draft.id]) } label: { Label("ゴミ箱へ", systemImage: "trash") }.disabled(draft.hasPendingOperation || managing)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { store.togglePin(draft.id) } label: { Label(draft.pinnedAt == nil ? "ピン留め" : "ピン解除", systemImage: draft.pinnedAt == nil ? "pin" : "pin.slash") }.tint(.teal).disabled(managing)
                                }
                                .contextMenu {
                                    Button(draft.pinnedAt == nil ? "ピン留め" : "ピン解除", systemImage: "pin") { store.togglePin(draft.id) }
                                    Button("複製して下書きにする", systemImage: "doc.on.doc") {
                                        if let copy = store.duplicate(draft.id) { shelf = .drafts; selectedArticleTag = nil; categoryFilter = nil; destination = .editor(copy) }
                                    }.disabled(draft.hasPendingOperation)
                                    if draft.isPublished {
                                        Button("サイトから削除…", systemImage: "trash", role: .destructive) { destination = .deletion(draft.id) }
                                            .accessibilityIdentifier("delete-published-" + draft.id.uuidString)
                                    }
                                    Button("端末のゴミ箱へ移動", systemImage: "trash", role: .destructive) { remove([draft.id]) }.disabled(draft.hasPendingOperation)
                                }
                        }
                    }.listRowBackground(Color.clear)
                }.writerCanvas()
                    // Publishing/deleting can remove rows while a sheet covers this list.
                    // Rebuild membership changes instead of applying stale collection diffs.
                    .id(Set(items.map(\.id)))
                    .listStyle(.plain).environment(\.defaultMinListRowHeight, 44)
                    .refreshable { if shelf == .published { await refreshPublished() } }
                if shelf == .published { Text("GitHubの記事を表示します。下に引くと最新の記事を読み込みます。").font(.caption2).foregroundStyle(WriterPalette.secondary).padding(.horizontal, 16).padding(.vertical, 5) }
            }.writerChrome().navigationTitle("記事").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(managing ? "完了" : "選択") { managing.toggle(); selection.removeAll() }.disabled(items.isEmpty && !managing) }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let siteURL = store.site.websiteURL { Link(destination: siteURL) {
                            Image(systemName: "globe")
                        }
                        .accessibilityLabel("公開サイトを開く")
                        .accessibilityHint("公開サイトをブラウザで開いて確認します")
                        .accessibilityIdentifier("article-open-site") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if shelf == .published {
                                Picker("並び順", selection: $publishedSort) {
                                    ForEach(PublishedArticleSort.allCases) { value in Text(value.label).tag(value) }
                                }.accessibilityIdentifier("article-published-sort")
                            }
                            Button("GitHubの記事を読み込む", systemImage: "arrow.clockwise") { Task { await refreshPublished() } }
                                .disabled(syncing || managing).accessibilityIdentifier("article-sync")
                            Button("ゴミ箱（\(trashCount)）", systemImage: "trash") { destination = .trash }
                            if managing { Button("表示中を全て選択") { selection = Set(items.filter { !$0.hasPendingOperation }.map(\.id)) } }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("記事の管理")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if managing {
                        HStack {
                            Text("\(selection.count)件選択").font(.caption).foregroundStyle(WriterPalette.secondary)
                            Spacer()
                            Button("端末のゴミ箱へ移動", role: .destructive) { remove(selection) }.disabled(selection.isEmpty)
                        }.padding(.horizontal, 16).padding(.vertical, 10).writerBarBackground()
                    }
                }
                .onChange(of: shelf) { _, _ in selection.removeAll() }
                .onChange(of: filterMode) { _, _ in selectedArticleTag = nil; categoryFilter = nil; selection.removeAll() }
                .onChange(of: selectedArticleTag) { _, _ in selection.removeAll() }
                .onChange(of: categoryFilter) { _, _ in selection.removeAll() }
                .onChange(of: publishedSort) { _, _ in selection.removeAll() }
                .task(id: shelf) { if shelf == .published { await refreshPublished() } }
                .alert("管理", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        }.sheet(item: $destination) { target in
            switch target {
            case .editor(let draft): NavigationStack { EditorView(draft: draft) }
            case .deletion(let id): PublishedDeletionView(articleID: id)
            case .trash: ArticleTrashView()
            }
        }
    }
    private func refreshPublished() async {
        store.beginRemoteOperation()
        defer { store.endRemoteOperation() }
        guard !syncing, destination == nil, !managing, store.loaded, store.storageError == nil else { return }
        if let error = store.categorySettingsError { syncError = error; return }
        syncing = true; syncError = nil
        defer { syncing = false }
        do {
            let token = (try? TokenVault.read()) ?? ""
            let categories = store.categories
            let remote = try await publisher.publishedArticles(token: token, categories: categories, knownArticles: store.drafts)
            try Task.checkCancellation()
            guard store.mergePublishedArticles(remote, scannedProfiles: categories.filter(\.isEnabled).map(\.profile), scannedCategories: categories) else { syncError = store.storageError; return }
            if store.drafts.contains(where: { $0.remoteChanged == true }) { syncError = "GitHub側にも変更がある記事があります。端末の編集中の内容を残しました。" }
        } catch is CancellationError { }
        catch { syncError = "記事を読み込めませんでした。保存済みの記事は残っています。\n\(error.localizedDescription)" }
    }
    private func create() {
        if let error = store.categorySettingsError { message = error; return }
        let draft = store.newDraft()
        // A failed disk save still retains the draft in memory. Open its editor so
        // the save error and retry action are visible instead of dropping the tap.
        _ = store.update(draft)
        shelf = .drafts; selectedArticleTag = nil; categoryFilter = nil
        destination = .editor(draft)
    }
    private func remove(_ ids: Set<UUID>) {
        if store.moveToTrash(ids) { selection.subtract(ids) }
        else { message = store.storageError ?? "公開・削除結果の確認待ちの記事は、確認が終わるまで移動できません。" }
    }
}

private enum ArticleFilterMode: String, CaseIterable, Identifiable {
    case categories, tags
    var id: String { rawValue }
    var label: String { self == .categories ? "カテゴリ" : "タグ" }
}

private enum ArticleDestination: Identifiable {
    case editor(Draft), deletion(UUID), trash
    var id: String {
        switch self {
        case .editor(let draft): return "editor-" + draft.id.uuidString
        case .deletion(let id): return "delete-" + id.uuidString
        case .trash: return "trash"
        }
    }
}

private struct CompactArticleRow: View {
    let draft: Draft
    let category: String
    var selecting = false
    var selected = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selecting ? (selected ? "checkmark.circle.fill" : "circle") : draft.containsMusic ? "music.note" : "doc.text").foregroundStyle(Color.accentColor).font(.body).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(draft.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(WriterPalette.text).lineLimit(1)
                    if draft.pinnedAt != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(WriterPalette.secondary) }
                }
                HStack(spacing: 6) {
                    Text(category).lineLimit(1)
                    Text(draft.isPublished ? draft.date : draft.updatedAt, format: .dateTime.month().day())
                    if draft.pendingMarkdown != nil { Text("結果確認待ち").foregroundStyle(.orange) }
                    else if draft.pendingDeletionSHA != nil { Text("削除確認待ち").foregroundStyle(.orange) }
                    else if draft.remoteChanged == true { Text("GitHubに変更あり").foregroundStyle(.orange) }
                    else if draft.isPublished && draft.hasUnpublishedEdits { Text("編集中").foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(WriterPalette.secondary)
            }
            Spacer(minLength: 2)
            if !selecting { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }.frame(minHeight: 36).contentShape(Rectangle())
    }
}

@MainActor struct PublishedDeletionView: View {
    let articleID: UUID
    @EnvironmentObject private var store: DraftStore
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var completed = false
    @State private var message: String?
    private var publisher: GitHubPublisher { GitHubPublisher(configuration: store.site, profile: draft?.publicationProfile ?? .current) }
    private var draft: Draft? { store.drafts.first { $0.id == articleID } }
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if let draft {
                        Section { Text(draft.displayTitle).font(.headline); Text(draft.description).font(.subheadline).foregroundStyle(WriterPalette.secondary) }
                        if completed {
                            Section {
                                Text("GitHubからの削除を確認しました。本文は端末の下書きに残っています。")
                                Text("サイトから消えるのは、公開処理が終わってからです。").font(.caption).foregroundStyle(WriterPalette.secondary)
                                if let url = store.site.websiteURL { Link("公開サイトで確認", destination: url) }
                                if let url = store.site.actionsURL { Link("サイトへの反映状況を確認", destination: url) }
                            }
                        } else {
                            Section {
                                Text("GitHubの公開記事を削除し、サイトから取り下げます。本文は端末の下書きに残します。")
                                Button(role: .destructive) { Task { await removePublished() } } label: {
                                    HStack {
                                        Text(draft.pendingDeletionSHA == nil ? "この記事をサイトから削除" : "削除結果を確認・再試行")
                                        if working { Spacer(); ProgressView() }
                                    }
                                }.disabled(working || store.storageError != nil)
                                    .accessibilityIdentifier("confirm-published-deletion")
                                if draft.pendingDeletionSHA != nil {
                                    Button("削除を中止する") { Task { await cancelDeletion() } }.disabled(working || store.storageError != nil)
                                }
                            } footer: { Text("確認待ちの場合は、GitHubの記事を照合してから再試行します。") }
                        }
                        if let message { Section { Text(message).font(.caption) } }
                        if let error = store.storageError { Section { Text(error).foregroundStyle(.red); Button("再保存") { store.persist() } } }
                    } else { Text("記事が見つかりません。") }
                }.listRowBackground(WriterPalette.surface)
            }.writerCanvas().writerChrome().navigationTitle("公開記事の削除").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(working || store.storageError != nil) } }
                .interactiveDismissDisabled(working || store.storageError != nil)
        }
    }
    private func removePublished() async {
        store.beginRemoteOperation()
        defer { store.endRemoteOperation() }
        guard !working else { return }
        working = true; message = nil
        defer { working = false }
        do {
            if let error = store.site.connectionError { throw WriterError.message("公開先を設定してください。" + error) }
            let token = try TokenVault.read()
            guard !token.isEmpty else { throw WriterError.message("設定でGitHubトークンを保存してください。") }
            guard let snapshot = store.beginRemoteDeletion(articleID), let sha = snapshot.pendingDeletionSHA else { return }
            let commit = try await publisher.deletePublished(snapshot, token: token)
            _ = store.finishRemoteDeletion(articleID, expectedSHA: sha, commitURL: commit)
            completed = true
        } catch is GitHubPublisher.DeletionError {
            _ = store.cancelRemoteDeletion(articleID, remoteChanged: true)
            message = GitHubPublisher.DeletionError.changed.localizedDescription
        } catch { message = error.localizedDescription }
    }
    private func cancelDeletion() async {
        store.beginRemoteOperation()
        defer { store.endRemoteOperation() }
        guard !working, let snapshot = draft, let sha = snapshot.pendingDeletionSHA else { return }
        working = true; message = nil
        defer { working = false }
        do {
            let token = try TokenVault.read()
            if try await publisher.canCancelDeletion(snapshot, token: token) {
                if store.cancelRemoteDeletion(articleID) { message = "GitHubに記事が残っていることを確認し、削除を中止しました。" }
            } else {
                _ = store.finishRemoteDeletion(articleID, expectedSHA: sha, commitURL: nil)
                completed = true
            }
        } catch { message = error.localizedDescription }
    }
}

@MainActor struct ArticleTrashView: View {
    @EnvironmentObject private var store: DraftStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: Draft?
    private var items: [Draft] { store.drafts.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! } }
    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section { Text("端末内のゴミ箱です。復元すると元のタブに戻ります。投稿済みの記事を端末から削除しても、公開サイトの記事は残ります。").font(.caption).foregroundStyle(WriterPalette.secondary) }
                    if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red); Button("再保存") { store.persist() } }
                    if items.isEmpty { Text("ゴミ箱は空です").foregroundStyle(WriterPalette.secondary) }
                    ForEach(items) { draft in
                        VStack(alignment: .leading, spacing: 5) {
                            CompactArticleRow(draft: draft, category: store.categoryLabel(for: draft))
                            HStack {
                                Button("復元") { store.restore(draft.id) }.accessibilityIdentifier("restore-article-" + draft.id.uuidString)
                                Spacer()
                                Button("完全に削除", role: .destructive) { deleting = draft }.accessibilityIdentifier("delete-article-" + draft.id.uuidString)
                            }.font(.caption).buttonStyle(.borderless).frame(minHeight: 32)
                        }.padding(.vertical, 2)
                    }
                }.listRowBackground(WriterPalette.surface)
            }.writerCanvas().writerChrome().navigationTitle("記事のゴミ箱").navigationBarTitleDisplayMode(.inline).toolbar { Button("閉じる") { dismiss() } }
                .confirmationDialog("「\(deleting?.displayTitle ?? "")」を端末から完全に削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("完全に削除する", role: .destructive) { if let deleting { store.deletePermanently(deleting.id) }; deleting = nil }
                    Button("キャンセル", role: .cancel) { deleting = nil }
                }
        }
    }
}

@MainActor struct PrivateNotesView: View {
    @EnvironmentObject private var store: PrivateNoteStore
    @AppStorage("private-note-composer") private var draftText = ""
    @State private var selected: PrivateNote?
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var browsingAll = false
    @State private var calendarOpen = false
    @State private var filter: NoteKind?
    @State private var selectedTag: String?
    @State private var query = ""
    @State private var searching = false
    @State private var trash = false
    @State private var managing = false
    @State private var managingTags = false
    @State private var selection = Set<UUID>()
    @State private var savedCount = 0
    @State private var scrollTarget: UUID?
    private var items: [PrivateNote] {
        PrivateNoteTimeline.entries(store.notes, day: browsingAll ? nil : selectedDay, kind: filter, tag: selectedTag, query: query)
    }
    private var tags: [String] { store.tags }
    private var title: String {
        if browsingAll { return selectedTag.map { "#" + $0 } ?? "すべてのメモ" }
        return selectedDay.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                timelineHeader
                ScrollViewReader { proxy in
                    List {
                        Group {
                            if let error = store.storageError {
                                Text(error).font(.caption).foregroundStyle(.red)
                                Button("再保存") { store.persist() }
                            }
                            if let error = store.tagStorageError { Text(error).font(.caption).foregroundStyle(.red) }
                            if items.isEmpty {
                                VStack(spacing: 6) {
                                    Text(searching || selectedTag != nil ? "メモが見つかりません" : "この日のメモはまだありません")
                                    if !browsingAll { Text("下の入力欄から、今日のメモを書けます。").font(.caption) }
                                }.font(.subheadline).foregroundStyle(WriterPalette.secondary).frame(maxWidth: .infinity)
                                    .padding(.vertical, 28).listRowSeparator(.hidden).listRowBackground(Color.clear)
                            }
                            ForEach(items) { note in timelineRow(note).id(note.id) }
                        }.listRowBackground(Color.clear)
                    }.writerCanvas().listStyle(.plain).scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
                        .contentMargins(.top, 8, for: .scrollContent).environment(\.defaultMinListRowHeight, 0)
                        .simultaneousGesture(DragGesture(minimumDistance: 45).onEnded { value in
                            guard !browsingAll, !managing,
                                  abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                            moveDay(value.translation.width < 0 ? 1 : -1)
                        })
                        .onChange(of: savedCount) { _, _ in
                            if let scrollTarget { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(scrollTarget, anchor: browsingAll ? .top : .bottom) } }
                        }
                        .task(id: selectedDay) {
                            guard !browsingAll else { return }
                            if let scrollTarget, items.contains(where: { $0.id == scrollTarget }) {
                                proxy.scrollTo(scrollTarget, anchor: .bottom)
                            } else if let last = items.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                }
            }.background(WriterPalette.background)
                .writerChrome().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if managing {
                            Button("完了") { managing = false; selection.removeAll() }
                        } else {
                            Menu {
                                Button("日付で見る", systemImage: "calendar") { browsingAll = false; selectedTag = nil; query = ""; searching = false }
                                Button("タグ・すべてのメモ", systemImage: "number") { browsingAll = true }
                                Button("タグを管理", systemImage: "slider.horizontal.3") { managingTags = true }
                                Button("検索", systemImage: "magnifyingglass") { searching.toggle(); browsingAll = true; if !searching { query = "" } }
                                    .accessibilityIdentifier("note-search-toggle")
                                Picker("記録の種類", selection: $filter) {
                                    Text("すべての記録").tag(Optional<NoteKind>.none)
                                    ForEach(NoteKind.allCases) { kind in Text(kind.label).tag(Optional(kind)) }
                                }
                                Button("選択", systemImage: "checkmark.circle") { managing = true }.disabled(items.isEmpty)
                                Button("ゴミ箱（\(store.trash.count)）", systemImage: "trash") { trash = true }
                            } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("メモのメニュー")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if browsingAll || !Calendar.current.isDateInToday(selectedDay) {
                            Button("今日") { selectedDay = Calendar.current.startOfDay(for: Date()); browsingAll = false; selectedTag = nil; query = ""; searching = false }
                                .font(.subheadline).accessibilityIdentifier("note-today")
                        }
                        Button { calendarOpen = true } label: { Image(systemName: "calendar") }
                            .accessibilityLabel("日付を選ぶ").accessibilityIdentifier("note-calendar")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if managing {
                        HStack {
                            Menu("\(selection.count)件選択") { Button("表示中を全て選択") { selection = Set(items.map(\.id)) } }
                            Spacer()
                            Button("ゴミ箱へ移動", role: .destructive) { if store.moveToTrash(selection) { selection.removeAll() } }.disabled(selection.isEmpty)
                        }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 12).writerBarBackground()
                    } else {
                        QuickNoteComposer(text: $draftText, tags: tags, enabled: store.loaded,
                                          selectedTag: selectedTag, manageTags: { managingTags = true }, hideTag: { store.hideTag($0) }) {
                            let body = selectedTag.map { NoteTags.appending($0, to: draftText) } ?? draftText
                            let now = Date()
                            guard store.addEntry(body: body, date: now) else { return false }
                            scrollTarget = store.notes.first?.id
                            selectedDay = Calendar.current.startOfDay(for: now)
                            browsingAll = false; selectedTag = nil; query = ""; searching = false; filter = nil
                            draftText = ""; savedCount += 1
                            return true
                        }
                    }
                }
                .sensoryFeedback(.success, trigger: savedCount)
                .onChange(of: filter) { _, _ in selection.removeAll() }
                .onChange(of: selectedTag) { _, _ in selection.removeAll() }
                .onChange(of: query) { _, _ in selection.removeAll() }
                .onChange(of: selectedDay) { _, _ in selection.removeAll() }
                .onChange(of: tags) { _, values in
                    if let selectedTag, !values.contains(where: { NoteTags.key($0) == NoteTags.key(selectedTag) }) { self.selectedTag = nil }
                }
                .sheet(item: $selected) { note in
                    PrivateNoteEditor(note: note).environmentObject(store)
                        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $trash) { PrivateNoteTrashView().environmentObject(store) }
                .sheet(isPresented: $managingTags) { NoteTagManagementView().environmentObject(store) }
                .sheet(isPresented: $calendarOpen) {
                    NavigationStack {
                        DatePicker("日付", selection: $selectedDay, displayedComponents: .date)
                            .datePickerStyle(.graphical).environment(\.locale, Locale(identifier: "ja_JP")).padding(.horizontal, 12)
                            .writerChrome().navigationTitle("日付を選ぶ").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("完了") { browsingAll = false; selectedTag = nil; query = ""; searching = false; calendarOpen = false } }
                    }.presentationDetents([.height(420)]).presentationDragIndicator(.visible)
                }
        }
    }

    private var timelineHeader: some View {
        VStack(spacing: 0) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(WriterPalette.secondary)
                    TextField("ことばや #タグで探す", text: $query).accessibilityIdentifier("note-search").autocorrectionDisabled()
                    Button { searching = false; query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("検索を閉じる")
                }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
            }
            if browsingAll {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        tagFilter("すべて", tag: nil).accessibilityIdentifier("note-filter-all")
                        ForEach(tags, id: \.self) { tag in tagFilter("#" + tag, tag: tag).accessibilityIdentifier("note-filter-tag-" + tag) }
                        if let selectedTag, !tags.contains(where: { NoteTags.key($0) == NoteTags.key(selectedTag) }) { tagFilter("#" + selectedTag, tag: selectedTag) }
                    }.padding(.horizontal, 16)
                    }
                    Button { managingTags = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 36) }
                        .buttonStyle(.plain).accessibilityLabel("タグを管理").accessibilityIdentifier("note-filter-manage-tags")
                }.padding(.vertical, 8)
            } else {
                HStack(spacing: 0) {
                    Button { moveDay(-7) } label: { Image(systemName: "chevron.left").font(.caption).frame(width: 28, height: 48) }
                        .accessibilityLabel("前の週")
                    ForEach(PrivateNoteTimeline.week(containing: selectedDay), id: \.self) { day in
                        let active = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                        let hasNotes = store.active.contains { Calendar.current.isDate($0.date, inSameDayAs: day) }
                        Button { selectedDay = day } label: {
                            VStack(spacing: 4) {
                                Text(day, format: .dateTime.weekday(.narrow)).font(.system(size: 10)).foregroundStyle(WriterPalette.secondary)
                                Text(String(Calendar.current.component(.day, from: day))).font(.subheadline.weight(active ? .semibold : .regular))
                                    .foregroundStyle(active ? WriterPalette.selectedText : WriterPalette.text)
                                    .frame(width: 30, height: 30).background(active ? WriterPalette.selected : Color.clear, in: Circle())
                                Circle().fill(hasNotes ? WriterPalette.secondary : Color.clear).frame(width: 3, height: 3)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(WriterPalette.text)
                            .accessibilityLabel(day.formatted(date: .complete, time: .omitted)).accessibilityValue(active ? "選択中" : "")
                            .accessibilityIdentifier("note-day-" + dayIdentifier(day))
                    }
                    Button { moveDay(7) } label: { Image(systemName: "chevron.right").font(.caption).frame(width: 28, height: 48) }
                        .accessibilityLabel("次の週")
                }.padding(.horizontal, 4).environment(\.locale, Locale(identifier: "ja_JP"))
            }
            if let filter { Button("\(filter.label)のみ · 解除") { self.filter = nil }.font(.caption).padding(.bottom, 5) }
            Divider().opacity(0.35)
        }
    }

    private func tagFilter(_ label: String, tag: String?) -> some View {
        let active = tag.map { NoteTags.key($0) == selectedTag.map(NoteTags.key) } ?? (selectedTag == nil)
        return Button { selectedTag = tag } label: {
            Text(label).font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? WriterPalette.text : WriterPalette.secondary).padding(.vertical, 4)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(WriterPalette.text.opacity(0.65)).frame(height: 1) } }
        }.buttonStyle(.plain).accessibilityValue(active ? "選択中" : "")
    }

    private func timelineRow(_ note: PrivateNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if managing {
                Image(systemName: selection.contains(note.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor).frame(width: 24).padding(.top, 8)
            } else if !browsingAll {
                VStack(spacing: 4) {
                    Text(note.date, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit()
                    if note.pinnedAt != nil { Image(systemName: "pin.fill").font(.system(size: 8)) }
                }.foregroundStyle(WriterPalette.secondary).frame(width: 36, alignment: .trailing).padding(.top, 10)
            }
            Group {
                if managing {
                    Button {
                        if selection.contains(note.id) { selection.remove(note.id) } else { selection.insert(note.id) }
                    } label: { noteBlock(note) }.buttonStyle(.plain)
                } else {
                    noteBlock(note)
                        .accessibilityAction(named: "編集") { selected = note }
                }
            }.accessibilityIdentifier("note-row-" + note.id.uuidString)
                .accessibilityValue(selection.contains(note.id) ? "選択済み" : "")
                .contextMenu {
                    Button("編集", systemImage: "pencil") { selected = note }
                    ForEach(note.tags, id: \.self) { tag in Button("#" + tag + "を見る", systemImage: "number") { selectedTag = tag; browsingAll = true } }
                    Button(note.pinnedAt == nil ? "ピン留め" : "ピン解除", systemImage: "pin") { store.togglePin(note.id) }
                    Button("ゴミ箱へ移動", systemImage: "trash", role: .destructive) { store.moveToTrash([note.id]) }
                }
            Spacer(minLength: 12)
        }.listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12)).listRowSeparator(.hidden).listRowBackground(Color.clear)
            .swipeActions(edge: .trailing) {
                if browsingAll { Button(role: .destructive) { store.moveToTrash([note.id]) } label: { Label("ゴミ箱へ", systemImage: "trash") }.disabled(managing) }
            }
            .swipeActions(edge: .leading) {
                if browsingAll { Button { store.togglePin(note.id) } label: { Label(note.pinnedAt == nil ? "ピン留め" : "ピン解除", systemImage: "pin") }.tint(.teal).disabled(managing) }
            }
    }

    private func noteBlock(_ note: PrivateNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 4) {
                if !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note.title).font(.subheadline).lineLimit(1)
                }
                Text(verbatim: note.displayBody.isEmpty ? (note.tags.isEmpty ? "空のメモ" : "タグのみ") : note.displayBody)
                    .font(.subheadline).foregroundStyle(note.displayBody.isEmpty ? WriterPalette.secondary : WriterPalette.text).lineSpacing(2)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("note-display-body-" + note.id.uuidString)
                if !note.tags.isEmpty {
                    Text(verbatim: note.tags.map { "#" + $0 }.joined(separator: "  "))
                        .font(.system(size: 11)).foregroundStyle(WriterPalette.secondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                        .accessibilityIdentifier("note-display-tags-" + note.id.uuidString)
                }
            }.foregroundStyle(WriterPalette.text).padding(.horizontal, 11).padding(.vertical, 8)
                .background(WriterPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            if browsingAll {
                HStack(spacing: 4) {
                    Text(note.date, format: .dateTime.year().month().day().hour().minute())
                    if note.pinnedAt != nil { Image(systemName: "pin.fill") }
                }.font(.system(size: 10)).foregroundStyle(WriterPalette.secondary).padding(.horizontal, 11)
            }
        }.contentShape(Rectangle())
    }

    private func moveDay(_ amount: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: amount, to: selectedDay) { selectedDay = day }
    }

    private func dayIdentifier(_ day: Date) -> String {
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = .current; date.dateFormat = "yyyy-MM-dd"
        return date.string(from: day)
    }
}

private struct NoteTagSuggestions: View {
    @Binding var text: String
    var tags: [String]
    var manage: () -> Void
    var hide: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    let added = NoteTags.extract(from: text).contains { NoteTags.key($0) == NoteTags.key(tag) }
                    Button { text = NoteTags.appending(tag, to: text) } label: {
                        Text("#" + tag).font(.caption).padding(.horizontal, 10).frame(minHeight: 32)
                            .background(Color.accentColor.opacity(added ? 0.16 : 0.06), in: Capsule())
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(added)
                        .accessibilityLabel("#\(tag)を追加").accessibilityValue(added ? "追加済み" : "")
                        .accessibilityIdentifier("note-suggest-tag-" + tag)
                        .contextMenu { Button("候補・一覧から削除", systemImage: "minus.circle", role: .destructive) { hide(tag) } }
                }
            }
        }
            Button(action: manage) { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32) }
                .buttonStyle(.plain).foregroundStyle(WriterPalette.secondary).accessibilityLabel("タグを管理").accessibilityIdentifier("note-suggestions-manage-tags")
        }
    }
}

private struct QuickNoteComposer: View {
    @Binding var text: String
    var tags: [String]
    var enabled: Bool
    var selectedTag: String?
    var manageTags: () -> Void
    var hideTag: (String) -> Void
    var save: () -> Bool
    @FocusState private var writing: Bool
    @State private var tagChoices = false
    @State private var markerRequest = 0
    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            if tagChoices || writing { NoteTagSuggestions(text: $text, tags: tags, manage: manageTags, hide: hideTag).padding(.horizontal, 12).padding(.top, 7) }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    if #available(iOS 18.0, *) { markerRequest += 1 }
                    else { text = NoteTags.insertingMarker(in: text, at: NSRange(location: text.utf16.count, length: 0)).text }
                    tagChoices = true; writing = true
                } label: {
                    Image(systemName: "number").font(.body).frame(width: 28, height: 36)
                }.buttonStyle(.plain).foregroundStyle(WriterPalette.secondary).accessibilityLabel("#を入力").accessibilityIdentifier("quick-note-hash")
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日のメモ" + (selectedTag.map { " #" + $0 } ?? ""))
                        .font(.system(size: 10)).foregroundStyle(WriterPalette.secondary)
                    if #available(iOS 18.0, *) {
                        NoteComposerField(text: $text, markerRequest: markerRequest, writing: $writing)
                    } else {
                        TextField("ひとこと書く…", text: $text, prompt: Text("ひとこと書く…").foregroundStyle(WriterPalette.placeholder), axis: .vertical)
                        .lineLimit(1...5).focused($writing).font(.subheadline).padding(.vertical, 8)
                        .accessibilityIdentifier("quick-note-body")
                    }
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if writing {
                        Button { writing = false; tagChoices = false } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 32, height: 36) }
                            .buttonStyle(.plain).foregroundStyle(WriterPalette.secondary).accessibilityLabel("キーボードを閉じる")
                    }
                } else {
                    Button { if save() { writing = true } } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).frame(width: 36, height: 36)
                    }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel("残す").accessibilityIdentifier("quick-note-save")
                }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }.writerBarBackground()
    }
}

@available(iOS 18.0, *)
private struct NoteComposerField: View {
    @Binding var text: String
    var markerRequest: Int
    var writing: FocusState<Bool>.Binding
    @State private var selection: TextSelection?
    var body: some View {
        TextField("ひとこと書く…", text: $text, selection: $selection, prompt: Text("ひとこと書く…").foregroundStyle(WriterPalette.placeholder), axis: .vertical)
            .lineLimit(1...5).focused(writing).font(.subheadline).padding(.vertical, 8)
            .accessibilityIdentifier("quick-note-body")
            .onChange(of: markerRequest) { _, _ in
                let range: NSRange
                if let selection, case .selection(let indices) = selection.indices { range = NoteTags.selectionRange(indices, in: text) }
                else { range = NSRange(location: text.utf16.count, length: 0) }
                let edit = NoteTags.insertingMarker(in: text, at: range)
                text = edit.text
                if let cursor = Range(edit.selection, in: text)?.lowerBound { selection = TextSelection(insertionPoint: cursor) }
            }
    }
}

@MainActor private struct NoteTagManagementView: View {
    @EnvironmentObject private var store: PrivateNoteStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        Text("入力候補と絞り込み一覧で同じ順番を使います。右のつまみを上下に動かすと並び替えられます。")
                        Text("一覧から削除しても、メモ本文の #タグは残ります。下から戻すか、新しいメモに同じタグを書いて残すと再び表示されます。")
                    }.font(.caption).foregroundStyle(WriterPalette.secondary)
                    if let error = store.tagStorageError { Text(error).font(.caption).foregroundStyle(.red) }
                    Section("候補・絞り込み一覧") {
                        if store.tags.isEmpty { Text("タグはありません。#タグを書いてメモを残すと追加されます。").foregroundStyle(WriterPalette.secondary) }
                        ForEach(store.tags, id: \.self) { tag in
                            HStack {
                                Text("#" + tag)
                                Spacer()
                                Button { store.hideTag(tag) } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }
                                    .buttonStyle(.borderless).accessibilityLabel("#\(tag)を一覧から削除").accessibilityIdentifier("note-hide-tag-" + tag)
                            }.deleteDisabled(true).accessibilityIdentifier("note-managed-tag-" + tag)
                        }.onMove { store.moveTags(from: $0, to: $1) }
                    }.disabled(!store.loaded || !store.tagsLoaded)
                    if !store.tagCatalog.hidden.isEmpty {
                        Section("一覧から外したタグ") {
                            ForEach(store.tagCatalog.hidden, id: \.self) { tag in
                                HStack { Text("#" + tag).foregroundStyle(WriterPalette.secondary); Spacer(); Button("戻す") { store.restoreTag(tag) }.buttonStyle(.borderless).accessibilityIdentifier("note-restore-tag-" + tag) }
                                    .moveDisabled(true).deleteDisabled(true)
                            }
                        }.disabled(!store.loaded || !store.tagsLoaded)
                    }
                }.listRowBackground(WriterPalette.surface)
            }.writerCanvas().environment(\.editMode, .constant(.active))
                .writerChrome().navigationTitle("タグを管理").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}

@MainActor struct PrivateNoteEditor: View {
    @EnvironmentObject private var store: PrivateNoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var note: PrivateNote
    @State private var managingTags = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red); Button("再保存") { store.update(note) } }
                    Text(note.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(WriterPalette.secondary)
                    TextField("ふと思ったことを書いてみよう", text: $note.body, axis: .vertical)
                        .lineLimit(3...24).font(.subheadline).lineSpacing(2).accessibilityIdentifier("private-note-body")
                        .padding(.vertical, 8)
                    NoteTagSuggestions(text: $note.body, tags: store.tags, manage: { managingTags = true }, hide: { store.hideTag($0) })
                    DisclosureGroup("日付・タイトル") {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("タイトル（なくても大丈夫）", text: $note.title).accessibilityIdentifier("private-note-title")
                            DatePicker("記録の日時", selection: $note.date).environment(\.locale, Locale(identifier: "ja_JP"))
                            Picker("記録の種類", selection: $note.kind) { ForEach(NoteKind.allCases) { kind in Text(kind.label).tag(kind) } }
                        }.padding(.top, 12)
                    }.font(.subheadline)
                    Label("この端末に自動保存", systemImage: "lock").font(.caption).foregroundStyle(WriterPalette.secondary)
                }.padding(16)
            }.background(WriterPalette.background).scrollDismissesKeyboard(.interactively)
                .writerChrome().navigationTitle("ひとことを編集").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完了") { if store.update(note) { dismiss() } } }
                }
                .interactiveDismissDisabled(store.storageError != nil)
                .onChange(of: note) { _, value in store.update(value) }
                .onChange(of: scenePhase) { _, phase in if phase != .active { store.update(note) } }
                .sheet(isPresented: $managingTags) { NoteTagManagementView().environmentObject(store) }
        }
    }
}

@MainActor struct PrivateNoteTrashView: View {
    @EnvironmentObject private var store: PrivateNoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: PrivateNote?
    var body: some View {
        NavigationStack {
            List {
                Group {
                    if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red); Button("再保存") { store.persist() } }
                    if store.trash.isEmpty { Text("ゴミ箱は空です").foregroundStyle(WriterPalette.secondary) }
                    ForEach(store.trash) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.displayTitle).font(.subheadline.weight(.medium))
                            HStack { Button("復元") { store.restore(note.id) }.accessibilityIdentifier("restore-note-" + note.id.uuidString); Spacer(); Button("完全に削除", role: .destructive) { deleting = note }.accessibilityIdentifier("delete-note-" + note.id.uuidString) }.font(.caption).buttonStyle(.borderless).frame(minHeight: 32)
                        }
                    }
                }.listRowBackground(WriterPalette.surface)
            }.writerCanvas().writerChrome().navigationTitle("メモのゴミ箱").navigationBarTitleDisplayMode(.inline).toolbar { Button("閉じる") { dismiss() } }
                .confirmationDialog("「\(deleting?.displayTitle ?? "")」を完全に削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("完全に削除する", role: .destructive) { if let deleting { store.deletePermanently(deleting.id) }; deleting = nil }
                    Button("キャンセル", role: .cancel) { deleting = nil }
                }
        }
    }
}

private func filterButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) { Text(title).font(.caption.weight(active ? .semibold : .regular)).padding(.horizontal, 13).frame(minHeight: 34).foregroundStyle(active ? WriterPalette.onAccent : WriterPalette.text).background(active ? Color.accentColor : WriterPalette.inactiveFilter, in: Capsule()) }.buttonStyle(.plain).accessibilityValue(active ? "選択中" : "")
}
