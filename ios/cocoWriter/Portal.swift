import SwiftUI
import UIKit

@MainActor struct DraftListView: View {
    @EnvironmentObject private var drafts: DraftStore
    @EnvironmentObject private var privateNotes: PrivateNoteStore
    @EnvironmentObject private var musicLibrary: MusicLibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var sharedDraft: Draft?
    @State private var editingSharedDraft: Draft?
    var body: some View {
        Group {
        #if targetEnvironment(macCatalyst)
            MacWorkspaceView(sharedArticle: $editingSharedDraft)
        #else
        TabView(selection: $tab) {
            ArticleLibraryView().tabItem { Label("記事", systemImage: "doc.text") }.tag(0)
            ArticleAlbumView().tabItem { Label("アルバム", systemImage: "photo.on.rectangle.angled") }.tag(3)
            PrivateNotesView().tabItem { Label("自分のメモ", systemImage: "note.text") }.tag(1)
            SettingsView().tabItem { Label("設定", systemImage: "gearshape") }.tag(2)
        }
        #endif
        }
        .safeAreaInset(edge: .top) {
            if let sharedDraft {
                HStack {
                    Text("共有した曲から下書きを作成しました").font(.writerCaption)
                    Spacer()
                    Button("続きを書く") { editingSharedDraft = drafts.drafts.first { $0.id == sharedDraft.id }; self.sharedDraft = nil }
                    Button { self.sharedDraft = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("案内を閉じる")
                }.padding(12).writerBarBackground()
            }
        }
        #if !targetEnvironment(macCatalyst)
        .sheet(item: $editingSharedDraft) { draft in NavigationStack { EditorView(draft: draft) } }
        #endif
        .task { purgeTrash(); receiveMusic(); privateNotes.synchronizeWidget() }
        .onChange(of: drafts.drafts) { _, _ in musicLibrary.reconcile(from: drafts) }
        .onChange(of: drafts.storageError) { _, error in if error == nil { musicLibrary.reconcile(from: drafts) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { purgeTrash(); receiveMusic(); privateNotes.synchronizeWidget() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if scenePhase == .active { privateNotes.synchronizeWidget() }
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == Bundle.main.bundleIdentifier?.lowercased(), url.host == "todos" else { return }
            privateNotes.synchronizeWidget()
            tab = 1
            privateNotes.widgetTasksRequested = true
        }
    }
    private func purgeTrash() {
        _ = drafts.purgeExpiredTrash()
        _ = privateNotes.purgeExpiredTrash(drafts.trashRetention)
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
    var selectedArticleID: UUID? = nil
    var onOpenArticle: ((Draft) -> Void)? = nil
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
    @State private var search = ""
    private var items: [Draft] {
        ArticleLibrary.items(store.drafts, shelf: shelf, publishedSort: publishedSort)
            .filter { draft in
                guard search.isEmpty || [draft.title, draft.description, draft.body, draft.tags].contains(where: { $0.localizedStandardContains(search) }) else { return false }
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
    private func filterLabel(for draft: Draft) -> String {
        switch filterMode {
        case .categories:
            return store.categoryLabel(for: draft)
        case .tags:
            let tags = RepositoryArticleMarkdown.tagValues(draft.tags)
            return tags.isEmpty ? "タグなし" : tags.map { "#" + $0 }.joined(separator: " ")
        }
    }
    private var trashCount: Int { store.drafts.filter { $0.deletedAt != nil }.count }
    private var publisher: GitHubPublisher { GitHubPublisher(configuration: store.site) }
    var body: some View {
        let items = self.items
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    #if targetEnvironment(macCatalyst)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(WriterPalette.secondary)
                        TextField("記事を検索", text: $search,
                                  prompt: Text("記事を検索").foregroundStyle(WriterPalette.secondary)).textFieldStyle(.plain)
                            .accessibilityIdentifier("article-search")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("検索を消去")
                        }
                    }.font(.subheadline).padding(.horizontal, 10).padding(.vertical, 9)
                        .background(WriterPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(WriterPalette.separator.opacity(0.5), lineWidth: 1))
                    HStack(spacing: 2) {
                        ForEach(ArticleShelf.allCases) { value in
                            Button { shelf = value } label: {
                                HStack(spacing: 5) {
                                    Text(value.label).fixedSize()
                                    Spacer(minLength: 2)
                                    Text("\(ArticleLibrary.items(store.drafts, shelf: value).count)")
                                        .foregroundStyle(WriterPalette.secondary).monospacedDigit().fixedSize()
                                }
                                .font(.writerCaption.weight(shelf == value ? .semibold : .regular))
                                .foregroundStyle(shelf == value ? WriterPalette.text : WriterPalette.secondary)
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32)
                                .background(shelf == value ? WriterPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityValue(shelf == value ? "選択中" : "")
                                .accessibilityAddTraits(shelf == value ? .isSelected : [])
                        }
                    }.accessibilityIdentifier("article-shelf")
                    #else
                    Picker("記事の状態", selection: $shelf) {
                        ForEach(ArticleShelf.allCases) { value in Text("\(value.label) \(ArticleLibrary.items(store.drafts, shelf: value).count)").tag(value) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("article-shelf")
                    #endif
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
                            }.font(.writerCaption).fixedSize()
                        }
                        .accessibilityLabel("絞り込み方法・" + filterMode.label)
                        .accessibilityHint("カテゴリまたはタグを選べます")
                        .accessibilityIdentifier("article-filter-mode")
                    }
                    #if targetEnvironment(macCatalyst)
                    Button { create() } label: {
                        Label("記事を書く", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.medium)).fixedSize()
                            .foregroundStyle(WriterPalette.text)
                            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(WriterPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(WriterPalette.separator.opacity(0.5), lineWidth: 1))
                    }.buttonStyle(.plain).disabled(!store.loaded || managing || syncing)
                        .accessibilityIdentifier("article-create")
                    #else
                    Button { create() } label: { Label("記事を書く", systemImage: "square.and.pencil").font(.subheadline).frame(maxWidth: .infinity, minHeight: 28) }
                        .buttonStyle(.bordered).disabled(!store.loaded || managing || syncing)
                        .accessibilityIdentifier("article-create")
                    #endif
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
                List {
                    Group {
                        if syncing { HStack { ProgressView(); Text("GitHubの記事を読み込み中…").font(.writerCaption) } }
                        if let syncError { Text(syncError).font(.writerCaption).foregroundStyle(.red) }
                        if let error = store.storageError {
                            Text(error).font(.writerCaption).foregroundStyle(.red)
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
                                else if draft.pendingDeletionSHA != nil { openDeletion(draft.id) }
                                else { openArticle(draft) }
                            } label: {
                                CompactArticleRow(draft: draft, detail: filterLabel(for: draft), selecting: managing, selected: selection.contains(draft.id))
                            }.buttonStyle(.plain).disabled(syncing).listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                                .listRowBackground(selectedArticleID == draft.id ? WriterPalette.selected : Color.clear)
                                .accessibilityIdentifier("article-row-" + draft.id.uuidString)
                                .accessibilityLabel("\(draft.displayTitle)、\(filterLabel(for: draft))、\(draft.pendingMarkdown != nil ? "送信結果の確認待ち" : shelf.label)")
                                .accessibilityValue(selection.contains(draft.id) ? "選択済み" : "")
                                .swipeActions(edge: .trailing, allowsFullSwipe: shelf == .drafts) {
                                    if shelf == .published {
                                        Button(role: .destructive) { openDeletion(draft.id) } label: { Label("サイトから削除", systemImage: "trash") }.disabled(managing || syncing)
                                    } else {
                                        Button(role: .destructive) { remove([draft.id]) } label: { Label("ゴミ箱へ", systemImage: "trash") }.disabled(draft.hasPendingOperation || managing)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { store.togglePin(draft.id) } label: { Label(draft.pinnedAt == nil ? "ピン留め" : "ピン解除", systemImage: draft.pinnedAt == nil ? "pin" : "pin.slash") }.tint(.teal).disabled(managing || selectedArticleID == draft.id)
                                }
                                .contextMenu {
                                    Button(draft.pinnedAt == nil ? "ピン留め" : "ピン解除", systemImage: "pin") { store.togglePin(draft.id) }.disabled(selectedArticleID == draft.id)
                                    Button("複製して下書きにする", systemImage: "doc.on.doc") {
                                        if let copy = store.duplicate(draft.id) { shelf = .drafts; selectedArticleTag = nil; categoryFilter = nil; openArticle(copy) }
                                    }.disabled(draft.hasPendingOperation)
                                    if draft.isPublished {
                                        Button("サイトから削除…", systemImage: "trash", role: .destructive) { openDeletion(draft.id) }
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
                if shelf == .published {
                    #if targetEnvironment(macCatalyst)
                    Text("GitHubの記事を表示します。最新を読むには記事を閉じ、管理メニューから読み込んでください。")
                        .font(.writerCaption2).foregroundStyle(WriterPalette.secondary).padding(.horizontal, 16).padding(.vertical, 5)
                    #else
                    Text("GitHubの記事を表示します。下に引くと最新の記事を読み込みます。").font(.writerCaption2).foregroundStyle(WriterPalette.secondary).padding(.horizontal, 16).padding(.vertical, 5)
                    #endif
                }
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
                                .disabled(syncing || managing || selectedArticleID != nil).accessibilityIdentifier("article-sync")
                            Button("ゴミ箱（\(trashCount)）", systemImage: "trash") { destination = .trash }
                            if managing { Button("表示中を全て選択") { selection = Set(items.filter { !$0.hasPendingOperation }.map(\.id)) } }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("記事の管理")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if managing {
                        #if targetEnvironment(macCatalyst)
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Text("\(selection.count)件選択").font(.writerCaption).foregroundStyle(WriterPalette.secondary).fixedSize()
                                Spacer(minLength: 8)
                                Button("端末のゴミ箱へ移動", role: .destructive) { remove(selection) }.disabled(selection.isEmpty).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(selection.count)件選択").font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                                Button("端末のゴミ箱へ移動", role: .destructive) { remove(selection) }.disabled(selection.isEmpty)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.horizontal, 16).padding(.vertical, 10).writerBarBackground()
                        #else
                        HStack {
                            Text("\(selection.count)件選択").font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                            Spacer()
                            Button("端末のゴミ箱へ移動", role: .destructive) { remove(selection) }.disabled(selection.isEmpty)
                        }.padding(.horizontal, 16).padding(.vertical, 10).writerBarBackground()
                        #endif
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
        guard !syncing, destination == nil, selectedArticleID == nil, !managing, store.loaded, store.storageError == nil else { return }
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
        shelf = .drafts; selectedArticleTag = nil; categoryFilter = nil
        openArticle(draft)
    }
    private func openDeletion(_ id: UUID) {
        guard selectedArticleID != id else { message = "編集中の記事を閉じてから削除してください。"; return }
        destination = .deletion(id)
    }
    private func openArticle(_ draft: Draft) {
        if let onOpenArticle { onOpenArticle(draft) }
        else { destination = .editor(draft) }
    }
    private func remove(_ ids: Set<UUID>) {
        guard !ids.contains(where: { $0 == selectedArticleID }) else { message = "編集中の記事を閉じてから移動してください。"; return }
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
    let detail: String
    var selecting = false
    var selected = false
    var body: some View {
        #if targetEnvironment(macCatalyst)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selecting ? (selected ? "checkmark.circle.fill" : "circle") : draft.containsMusic ? "music.note" : "doc.text")
                .font(.subheadline).foregroundStyle(WriterPalette.secondary).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 5) {
                    Text(draft.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(WriterPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.pinnedAt != nil { Image(systemName: "pin.fill").font(.writerCaption2).foregroundStyle(WriterPalette.secondary) }
                }
                Text(detail).font(.writerCaption2).foregroundStyle(WriterPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(draft.isPublished ? draft.date : draft.updatedAt, format: .dateTime.month().day()).fixedSize()
                    if draft.pendingMarkdown != nil { Text("結果確認待ち").foregroundStyle(.orange) }
                    else if draft.pendingDeletionSHA != nil { Text("削除確認待ち").foregroundStyle(.orange) }
                    else if draft.remoteChanged == true { Text("GitHubに変更あり").foregroundStyle(.orange) }
                    else if draft.isPublished && draft.hasUnpublishedEdits { Text("編集中").foregroundStyle(.orange) }
                }.font(.writerCaption2).foregroundStyle(WriterPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).contentShape(Rectangle())
        #else
        HStack(spacing: 10) {
            Image(systemName: selecting ? (selected ? "checkmark.circle.fill" : "circle") : draft.containsMusic ? "music.note" : "doc.text").foregroundStyle(Color.accentColor).font(.body).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(draft.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(WriterPalette.text).lineLimit(1)
                    if draft.pinnedAt != nil { Image(systemName: "pin.fill").font(.writerCaption2).foregroundStyle(WriterPalette.secondary) }
                }
                HStack(spacing: 6) {
                    Text(detail).lineLimit(1)
                    Text(draft.isPublished ? draft.date : draft.updatedAt, format: .dateTime.month().day())
                    if draft.pendingMarkdown != nil { Text("結果確認待ち").foregroundStyle(.orange) }
                    else if draft.pendingDeletionSHA != nil { Text("削除確認待ち").foregroundStyle(.orange) }
                    else if draft.remoteChanged == true { Text("GitHubに変更あり").foregroundStyle(.orange) }
                    else if draft.isPublished && draft.hasUnpublishedEdits { Text("編集中").foregroundStyle(.orange) }
                }.font(.writerCaption2).foregroundStyle(WriterPalette.secondary)
            }
            Spacer(minLength: 2)
            if !selecting { Image(systemName: "chevron.right").font(.writerCaption2).foregroundStyle(.tertiary) }
        }.frame(minHeight: 36).contentShape(Rectangle())
        #endif
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
                                Text("サイトから消えるのは、公開処理が終わってからです。").font(.writerCaption).foregroundStyle(WriterPalette.secondary)
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
                        if let message { Section { Text(message).font(.writerCaption) } }
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
                    Section { Text("端末内のゴミ箱です。復元すると元のタブに戻ります。投稿済みの記事を端末から削除しても、公開サイトの記事は残ります。").font(.writerCaption).foregroundStyle(WriterPalette.secondary) }
                    if let error = store.storageError { Text(error).font(.writerCaption).foregroundStyle(.red); Button("再保存") { store.persist() } }
                    if items.isEmpty { Text("ゴミ箱は空です").foregroundStyle(WriterPalette.secondary) }
                    ForEach(items) { draft in
                        VStack(alignment: .leading, spacing: 5) {
                            CompactArticleRow(draft: draft, detail: store.categoryLabel(for: draft))
                            HStack {
                                Button("復元") { store.restore(draft.id) }.accessibilityIdentifier("restore-article-" + draft.id.uuidString)
                                Spacer()
                                Button("完全に削除", role: .destructive) { deleting = draft }.accessibilityIdentifier("delete-article-" + draft.id.uuidString)
                            }.font(.writerCaption).buttonStyle(.borderless).frame(minHeight: 32)
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
    @AppStorage("private-note-composer-task") private var draftIsTask = false
    @AppStorage("private-note-composer-deadline") private var draftDeadline = 0.0
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
    @State private var tasksOpen = false
    @State private var tasksOnly = false
    @State private var selection = Set<UUID>()
    @State private var savedCount = 0
    @State private var scrollTarget: String?
    private var items: [NoteTimelineEvent] {
        PrivateNoteTimeline.events(store.notes, day: browsingAll ? nil : selectedDay, kind: filter, tag: selectedTag, query: query, tasksOnly: tasksOnly)
    }
    private var draftDueDate: Binding<Date?> {
        Binding(get: { draftDeadline == 0 ? nil : Date(timeIntervalSince1970: draftDeadline) },
                set: { draftDeadline = $0?.timeIntervalSince1970 ?? 0 })
    }
    private var tags: [String] { store.tags }
    private var title: String {
        if browsingAll { return (selectedTag.map { "#" + $0 } ?? (tasksOnly ? "TODOの記録" : "すべてのメモ")) + (tasksOnly && selectedTag != nil ? " · TODO" : "") }
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
                                Text(error).font(.writerCaption).foregroundStyle(.red)
                                Button("再保存") { store.persist() }
                            }
                            if let error = store.tagStorageError { Text(error).font(.writerCaption).foregroundStyle(.red) }
                            if items.isEmpty {
                                VStack(spacing: 6) {
                                    Text(tasksOnly ? "TODOの記録はまだありません" : (searching || selectedTag != nil ? "メモが見つかりません" : "この日のメモはまだありません"))
                                    if !browsingAll { Text("下の入力欄から、今日のメモを書けます。").font(.writerCaption) }
                                }.font(.subheadline).foregroundStyle(WriterPalette.secondary).frame(maxWidth: .infinity)
                                    .padding(.vertical, 28).listRowSeparator(.hidden).listRowBackground(Color.clear)
                            }
                            ForEach(items) { event in timelineRow(event).id(event.id) }
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
                #if targetEnvironment(macCatalyst)
                composerBar
                #endif
            }.background(WriterPalette.background)
                .writerChrome().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if managing {
                            Button("完了") { managing = false; selection.removeAll() }
                        } else {
                            Menu {
                                Button("日付で見る", systemImage: "calendar") { browsingAll = false; selectedTag = nil; query = ""; searching = false; tasksOnly = false }
                                Button("タグ・すべてのメモ", systemImage: "number") {
                                    showTagSearch()
                                }
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
                        Button { tasksOpen = true } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "checklist")
                                Text("\(PrivateNoteTimeline.pendingTasks(store.notes).count)").font(.writerCaption).monospacedDigit()
                            }
                        }.accessibilityLabel("未完了のTODO一覧").accessibilityIdentifier("note-open-tasks")
                        Button { showTagSearch() } label: { Image(systemName: "number") }
                            .accessibilityLabel("タグで探す").accessibilityIdentifier("note-open-tags")
                        if browsingAll || !Calendar.current.isDateInToday(selectedDay) {
                            Button("今日") { selectedDay = Calendar.current.startOfDay(for: Date()); browsingAll = false; selectedTag = nil; query = ""; searching = false; tasksOnly = false }
                                .font(.subheadline).accessibilityIdentifier("note-today")
                        }
                        Button { calendarOpen = true } label: { Image(systemName: "calendar") }
                            .accessibilityLabel("日付を選ぶ").accessibilityIdentifier("note-calendar")
                    }
                }
                #if !targetEnvironment(macCatalyst)
                .safeAreaInset(edge: .bottom, spacing: 0) { composerBar }
                #endif
                .sensoryFeedback(.success, trigger: savedCount)
                .onChange(of: filter) { _, _ in selection.removeAll() }
                .onChange(of: selectedTag) { _, _ in selection.removeAll() }
                .onChange(of: query) { _, _ in selection.removeAll() }
                .onChange(of: selectedDay) { _, _ in selection.removeAll() }
                .onChange(of: tasksOnly) { _, _ in selection.removeAll() }
                .onChange(of: tags) { _, values in
                    if let selectedTag, !values.contains(where: { NoteTags.key($0) == NoteTags.key(selectedTag) }) { self.selectedTag = nil }
                }
                .onAppear { openWidgetTasksIfNeeded() }
                .onChange(of: store.widgetTasksRequested) { _, _ in openWidgetTasksIfNeeded() }
                .sheet(item: $selected) { note in
                    PrivateNoteEditor(note: note).environmentObject(store)
                        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $trash) { PrivateNoteTrashView().environmentObject(store) }
                .sheet(isPresented: $managingTags) { NoteTagManagementView().environmentObject(store) }
                .sheet(isPresented: $tasksOpen) {
                    PendingNoteTasksView(showHistory: { showTaskHistory() }).environmentObject(store)
                }
                .sheet(isPresented: $calendarOpen) {
                    NavigationStack {
                        DatePicker("日付", selection: $selectedDay, displayedComponents: .date)
                            .datePickerStyle(.graphical).environment(\.locale, Locale(identifier: "ja_JP")).padding(.horizontal, 12)
                            .writerChrome().navigationTitle("日付を選ぶ").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("完了") { browsingAll = false; selectedTag = nil; query = ""; searching = false; tasksOnly = false; calendarOpen = false } }
                    }.presentationDetents([.height(420)]).presentationDragIndicator(.visible)
                }
        }
    }

    @ViewBuilder private var composerBar: some View {
        if managing {
            HStack {
                Menu("\(selection.count)件選択") { Button("表示中を全て選択") { selection = Set(items.map { $0.note.id }) } }
                Spacer()
                Button("ゴミ箱へ移動", role: .destructive) { if store.moveToTrash(selection) { selection.removeAll() } }.disabled(selection.isEmpty)
            }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 12).writerBarBackground()
        } else {
            QuickNoteComposer(text: $draftText, isTask: $draftIsTask, dueDate: draftDueDate, tags: tags, enabled: store.loaded,
                              selectedTag: selectedTag, manageTags: { managingTags = true }, hideTag: { store.hideTag($0) }) {
                let body = selectedTag.map { NoteTags.appending($0, to: draftText) } ?? draftText
                let now = Date()
                guard store.addEntry(body: body, date: now, task: draftIsTask ? NoteTask(dueDate: draftDueDate.wrappedValue) : nil) else { return false }
                scrollTarget = store.notes.first?.id.uuidString
                selectedDay = Calendar.current.startOfDay(for: now)
                browsingAll = false; selectedTag = nil; query = ""; searching = false; filter = nil; tasksOnly = false
                draftText = ""; draftIsTask = false; draftDeadline = 0; savedCount += 1
                return true
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
                        Button { tasksOnly.toggle(); selectedTag = nil } label: {
                            Label("TODO", systemImage: "checklist").font(.subheadline.weight(tasksOnly ? .semibold : .regular))
                                .foregroundStyle(tasksOnly ? WriterPalette.text : WriterPalette.secondary).padding(.vertical, 4)
                                .overlay(alignment: .bottom) { if tasksOnly { Rectangle().fill(WriterPalette.text.opacity(0.65)).frame(height: 1) } }
                        }.buttonStyle(.plain).accessibilityValue(tasksOnly ? "選択中" : "").accessibilityIdentifier("note-filter-tasks")
                        ForEach(tags, id: \.self) { tag in tagFilter("#" + tag, tag: tag).accessibilityIdentifier("note-filter-tag-" + tag) }
                        if let selectedTag, !tags.contains(where: { NoteTags.key($0) == NoteTags.key(selectedTag) }) { tagFilter("#" + selectedTag, tag: selectedTag) }
                    }.padding(.horizontal, 16)
                    }
                    Button { managingTags = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 36) }
                        .buttonStyle(.plain).accessibilityLabel("タグを管理").accessibilityIdentifier("note-filter-manage-tags")
                }.padding(.vertical, 8)
            } else {
                HStack(spacing: 0) {
                    Button { moveDay(-7) } label: { Image(systemName: "chevron.left").font(.writerCaption).frame(width: 28, height: 48) }
                        .accessibilityLabel("前の週")
                    ForEach(PrivateNoteTimeline.week(containing: selectedDay), id: \.self) { day in
                        let active = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                        let hasNotes = store.active.contains {
                            Calendar.current.isDate($0.date, inSameDayAs: day)
                                || $0.task?.completedAt.map { Calendar.current.isDate($0, inSameDayAs: day) } == true
                        }
                        Button { selectedDay = day } label: {
                            VStack(spacing: 4) {
                                Text(day, format: .dateTime.weekday(.narrow)).font(.writerSmall(size: 10)).foregroundStyle(WriterPalette.secondary)
                                Text(String(Calendar.current.component(.day, from: day))).font(.subheadline.weight(active ? .semibold : .regular))
                                    .foregroundStyle(active ? WriterPalette.selectedText : WriterPalette.text)
                                    .frame(width: 30, height: 30).background(active ? WriterPalette.selected : Color.clear, in: Circle())
                                Circle().fill(hasNotes ? WriterPalette.secondary : Color.clear).frame(width: 3, height: 3)
                            }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(WriterPalette.text)
                            .accessibilityLabel(day.formatted(date: .complete, time: .omitted)).accessibilityValue(active ? "選択中" : "")
                            .accessibilityIdentifier("note-day-" + dayIdentifier(day))
                    }
                    Button { moveDay(7) } label: { Image(systemName: "chevron.right").font(.writerCaption).frame(width: 28, height: 48) }
                        .accessibilityLabel("次の週")
                }.padding(.horizontal, 4).environment(\.locale, Locale(identifier: "ja_JP"))
            }
            if let filter { Button("\(filter.label)のみ · 解除") { self.filter = nil }.font(.writerCaption).padding(.bottom, 5) }
            Divider().opacity(0.35)
        }
    }

    private func openWidgetTasksIfNeeded() {
        guard store.widgetTasksRequested else { return }
        store.widgetTasksRequested = false
        tasksOpen = true
    }

    private func showTagSearch() {
        browsingAll = true; tasksOnly = false; selectedTag = nil; query = ""; searching = false; filter = nil
    }

    private func selectTag(_ tag: String?) {
        selectedTag = tag; tasksOnly = false; browsingAll = true
    }

    private func tagFilter(_ label: String, tag: String?) -> some View {
        let active = tag.map { NoteTags.key($0) == selectedTag.map(NoteTags.key) } ?? (selectedTag == nil && !tasksOnly)
        return Button { selectTag(tag) } label: {
            Text(label).font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? WriterPalette.text : WriterPalette.secondary).padding(.vertical, 4)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(WriterPalette.text.opacity(0.65)).frame(height: 1) } }
        }.buttonStyle(.plain).accessibilityValue(active ? "選択中" : "")
    }

    private var timelineTimeWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        52
        #else
        36
        #endif
    }

    private func timelineRow(_ event: NoteTimelineEvent) -> some View {
        let note = event.note
        return HStack(alignment: .top, spacing: 8) {
            if managing {
                Image(systemName: selection.contains(note.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor).frame(width: 24).padding(.top, 8)
            } else if !browsingAll {
                VStack(spacing: 4) {
                    Text(event.date, format: .dateTime.hour().minute()).font(.writerSmall(size: 10)).monospacedDigit()
                    if note.pinnedAt != nil { Image(systemName: "pin.fill").font(.writerSmall(size: 8)) }
                }.foregroundStyle(WriterPalette.secondary).frame(width: timelineTimeWidth, alignment: .trailing).padding(.top, 10)
            }
            Group {
                if managing {
                    Button {
                        if selection.contains(note.id) { selection.remove(note.id) } else { selection.insert(note.id) }
                    } label: { noteBlock(note, isCompletion: event.isCompletion) }.buttonStyle(.plain)
                } else {
                    noteBlock(note, isCompletion: event.isCompletion)
                        .accessibilityAction(named: "編集") { selected = note }
                }
            }.accessibilityIdentifier("note-row-" + note.id.uuidString)
                .accessibilityValue(selection.contains(note.id) ? "選択済み" : "")
                .contextMenu {
                    Button("編集", systemImage: "pencil") { selected = note }
                    ForEach(note.tags, id: \.self) { tag in Button("#" + tag + "を見る", systemImage: "number") { selectTag(tag) } }
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

    private func noteBlock(_ note: PrivateNote, isCompletion: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 4) {
                if let task = note.task {
                    HStack(spacing: 8) {
                        if !managing {
                            NoteTaskCheckButton(note: note) { store.toggleTask(note.id) }
                        }
                        Text(isCompletion ? "TODOを完了" : "TODO").font(.writerCaption.weight(.medium)).foregroundStyle(WriterPalette.secondary)
                        Spacer(minLength: 4)
                        Button { selected = note } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                            .buttonStyle(.borderless).foregroundStyle(WriterPalette.secondary).accessibilityLabel("TODOを編集")
                            .disabled(managing)
                    }
                    NoteTaskStatus(task: task)
                }
                if !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note.title).font(.subheadline).lineLimit(1)
                }
                Text(verbatim: note.displayBody.isEmpty ? (note.tags.isEmpty ? "空のメモ" : "タグのみ") : note.displayBody)
                    .font(.subheadline).foregroundStyle(note.displayBody.isEmpty ? WriterPalette.secondary : WriterPalette.text).lineSpacing(2)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("note-display-body-" + note.id.uuidString)
                if !note.tags.isEmpty {
                    Text(verbatim: note.tags.map { "#" + $0 }.joined(separator: "  "))
                        .font(.writerSmall(size: 11)).foregroundStyle(WriterPalette.secondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                        .accessibilityIdentifier("note-display-tags-" + note.id.uuidString)
                }
            }.foregroundStyle(WriterPalette.text).padding(.horizontal, 11).padding(.vertical, 8)
                .background(WriterPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            if browsingAll {
                HStack(spacing: 4) {
                    Text(note.date, format: .dateTime.year().month().day().hour().minute())
                    if note.pinnedAt != nil { Image(systemName: "pin.fill") }
                }.font(.writerSmall(size: 10)).foregroundStyle(WriterPalette.secondary).padding(.horizontal, 11)
            }
        }.contentShape(Rectangle())
    }

    private func moveDay(_ amount: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: amount, to: selectedDay) { selectedDay = day }
    }

    private func showTaskHistory() {
        browsingAll = true; tasksOnly = true; selectedTag = nil; query = ""; searching = false; filter = nil
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
                        Text("#" + tag).font(.writerCaption).padding(.horizontal, 10).frame(minHeight: 32)
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

private struct NoteTaskCheckButton: View {
    var note: PrivateNote
    var toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Image(systemName: note.task?.isCompleted == true ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 23)).frame(width: 44, height: 44)
                .foregroundStyle(note.task?.isCompleted == true ? WriterPalette.accent : WriterPalette.secondary)
                .contentShape(Rectangle())
        }.buttonStyle(.borderless)
            .accessibilityLabel(note.displayTitle + (note.task?.isCompleted == true ? "を未完了に戻す" : "を完了にする"))
            .accessibilityValue(note.task?.isCompleted == true ? "完了" : "未完了")
            .accessibilityIdentifier("note-task-toggle-" + note.id.uuidString)
    }
}

private struct NoteTaskStatus: View {
    var task: NoteTask
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let due = task.dueDate {
                Label {
                    Text("期限 ") + Text(due, format: .dateTime.year().month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
                        + Text(task.isOverdue() ? " · 期限超過" : (Calendar.current.isDateInToday(due) && !task.isCompleted ? " · 今日" : ""))
                } icon: { Image(systemName: "calendar") }
                .foregroundStyle(task.isOverdue() ? Color.orange : WriterPalette.secondary)
            } else {
                Label("期限なし", systemImage: "calendar").foregroundStyle(WriterPalette.secondary)
            }
            if let completed = task.completedAt {
                Label {
                    Text(completed, format: .dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ja_JP"))) + Text(" 完了")
                } icon: { Image(systemName: "checkmark") }
                .foregroundStyle(WriterPalette.secondary)
            }
        }.font(.writerCaption)
    }
}

private struct NoteTaskDeadlinePicker: View {
    @Binding var date: Date?
    @State private var calendarOpen = false

    var body: some View {
        HStack(spacing: 8) {
            quickDate("今日", offset: 0)
            quickDate("明日", offset: 1)
            Button { calendarOpen = true } label: {
                Label {
                    if let date {
                        Text(date, format: .dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
                    } else { Text("期限なし") }
                } icon: { Image(systemName: "calendar") }
                .padding(.horizontal, 10).frame(minHeight: 36).background(WriterPalette.selected, in: Capsule())
            }.buttonStyle(.borderless).accessibilityLabel("締め切りを選ぶ").accessibilityIdentifier("note-task-deadline")
        }.font(.writerCaption).foregroundStyle(WriterPalette.text)
            .sheet(isPresented: $calendarOpen) {
                NavigationStack {
                    VStack(spacing: 8) {
                        HStack {
                            quickDate("今日", offset: 0)
                            quickDate("明日", offset: 1)
                            quickDate("1週間後", offset: 7)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 16)
                        NoteTaskCalendar(selectedDate: date) { chosen in
                            date = Calendar.current.startOfDay(for: chosen)
                            calendarOpen = false
                        }.frame(height: 360).padding(.horizontal, 12)
                        Spacer(minLength: 0)
                    }.padding(.top, 8).writerChrome().navigationTitle("締め切り").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { calendarOpen = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("期限なし") { date = nil; calendarOpen = false } }
                        }
                }.presentationDetents([.height(510), .large]).presentationDragIndicator(.visible)
            }
    }

    private func quickDate(_ title: String, offset: Int) -> some View {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let active = date.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false
        return Button { date = day; calendarOpen = false } label: {
            Text(title).padding(.horizontal, 12).frame(minHeight: 36)
                .background(active ? WriterPalette.selected : Color.clear, in: Capsule())
                .overlay { Capsule().strokeBorder(WriterPalette.separator.opacity(0.4), lineWidth: 1) }
        }.buttonStyle(.borderless).accessibilityValue(active ? "選択中" : "").accessibilityIdentifier("note-task-due-" + String(offset))
    }
}

// Restore the deadline as the native calendar selection when reopening the picker.
private struct NoteTaskCalendar: UIViewRepresentable {
    var selectedDate: Date?
    var choose: (Date) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selectedDate: selectedDate, choose: choose) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        view.calendar = Calendar.current
        view.locale = Locale(identifier: "ja_JP")
        view.timeZone = Calendar.current.timeZone
        view.tintColor = UIColor(WriterPalette.accent)
        view.visibleDateComponents = Calendar.current.dateComponents([.era, .year, .month, .day], from: selectedDate ?? Date())
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.selectionBehavior = selection
        selection.setSelected(selectedDate.map { Calendar.current.dateComponents([.era, .year, .month, .day], from: $0) }, animated: false)
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.choose = choose
        context.coordinator.selectedDate = selectedDate
        let components = selectedDate.map { Calendar.current.dateComponents([.era, .year, .month, .day], from: $0) }
        if let selection = view.selectionBehavior as? UICalendarSelectionSingleDate,
           selection.selectedDate != components {
            selection.setSelected(components, animated: false)
        }
    }

    final class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate {
        var choose: (Date) -> Void
        var selectedDate: Date?
        init(selectedDate: Date?, choose: @escaping (Date) -> Void) {
            self.selectedDate = selectedDate
            self.choose = choose
        }
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            // Keep the current deadline if UIKit clears the selection.
            guard let date = dateComponents.flatMap({ Calendar.current.date(from: $0) }) ?? selectedDate else { return }
            choose(date)
        }
    }
}

@MainActor private struct PendingNoteTasksView: View {
    @EnvironmentObject private var store: PrivateNoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PrivateNote?
    @State private var lastCompleted: UUID?
    var showHistory: () -> Void
    private var tasks: [PrivateNote] { PrivateNoteTimeline.pendingTasks(store.notes) }

    var body: some View {
        NavigationStack {
            List {
                if let error = store.storageError { Text(error).font(.writerCaption).foregroundStyle(.red) }
                if tasks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.largeTitle)
                        Text("未完了のTODOはありません")
                        Text("メモ入力欄のチェックボタンから追加できます。").font(.writerCaption)
                    }.foregroundStyle(WriterPalette.secondary).frame(maxWidth: .infinity).padding(.vertical, 36)
                        .listRowBackground(Color.clear)
                }
                taskSection("期限超過", notes: tasks.filter { $0.task?.isOverdue() == true })
                taskSection("今日", notes: tasks.filter { $0.task?.dueDate.map { Calendar.current.isDateInToday($0) } == true })
                taskSection("これから", notes: tasks.filter { $0.task?.dueDate.map { Calendar.current.startOfDay(for: $0) > Calendar.current.startOfDay(for: Date()) } == true })
                taskSection("期限なし", notes: tasks.filter { $0.task?.dueDate == nil })
            }.writerCanvas().listStyle(.insetGrouped)
                .writerChrome().navigationTitle("未完了のTODO").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 12) {
                        if let lastCompleted, store.notes.first(where: { $0.id == lastCompleted })?.task?.isCompleted == true {
                            HStack {
                                Text("完了しました。記録に残っています。").font(.writerCaption)
                                Spacer()
                                Button("戻す") { if store.toggleTask(lastCompleted) { self.lastCompleted = nil } }.font(.subheadline)
                            }
                        }
                        Button { showHistory(); dismiss() } label: { Label("完了分を含むTODOの記録を見る", systemImage: "clock.arrow.circlepath") }
                            .font(.subheadline).accessibilityIdentifier("note-tasks-history")
                    }.padding(16).frame(maxWidth: .infinity).writerBarBackground()
                }
                .sheet(item: $selected) { note in
                    PrivateNoteEditor(note: note).environmentObject(store)
                        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
        }
    }

    @ViewBuilder private func taskSection(_ title: String, notes: [PrivateNote]) -> some View {
        if !notes.isEmpty {
            Section(title) {
                ForEach(notes) { note in
                    HStack(alignment: .top, spacing: 4) {
                        NoteTaskCheckButton(note: note) { if store.toggleTask(note.id) { lastCompleted = note.id } }
                        Button { selected = note } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: note.displayBody.isEmpty ? note.displayTitle : note.displayBody).font(.subheadline).lineLimit(4)
                                    .foregroundStyle(WriterPalette.text)
                                if let task = note.task { NoteTaskStatus(task: task) }
                                if !note.tags.isEmpty {
                                    Text(verbatim: note.tags.map { "#" + $0 }.joined(separator: "  ")).font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).contentShape(Rectangle())
                        }.buttonStyle(.borderless).accessibilityLabel("TODOを編集: " + note.displayTitle)
                    }.listRowBackground(WriterPalette.surface).accessibilityIdentifier("pending-note-task-" + note.id.uuidString)
                }
            }
        }
    }
}

private struct QuickNoteComposer: View {
    @Binding var text: String
    @Binding var isTask: Bool
    @Binding var dueDate: Date?
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
            if isTask {
                HStack(spacing: 8) {
                    Text("締め切り").font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                    NoteTaskDeadlinePicker(date: $dueDate)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            if tagChoices || writing { NoteTagSuggestions(text: $text, tags: tags, manage: manageTags, hide: hideTag).padding(.horizontal, 12).padding(.top, 7) }
            HStack(alignment: .bottom, spacing: 10) {
                Button { isTask.toggle(); writing = true } label: {
                    Image(systemName: isTask ? "checkmark.circle.fill" : "checkmark.circle").font(.body).frame(width: 32, height: 44)
                }.buttonStyle(.plain).foregroundStyle(isTask ? WriterPalette.accent : WriterPalette.secondary)
                    .accessibilityLabel(isTask ? "通常のメモに戻す" : "TODOにする").accessibilityValue(isTask ? "TODO" : "メモ")
                    .accessibilityIdentifier("quick-note-task")
                Button {
                    if #available(iOS 18.0, *) { markerRequest += 1 }
                    else { text = NoteTags.insertingMarker(in: text, at: NSRange(location: text.utf16.count, length: 0)).text }
                    tagChoices = true; writing = true
                } label: {
                    Image(systemName: "number").font(.body).frame(width: 28, height: 36)
                }.buttonStyle(.plain).foregroundStyle(WriterPalette.secondary).accessibilityLabel("#を入力").accessibilityIdentifier("quick-note-hash")
                VStack(alignment: .leading, spacing: 2) {
                    Text((isTask ? "今日のTODO" : "今日のメモ") + (selectedTag.map { " #" + $0 } ?? ""))
                        .font(.writerSmall(size: 10)).foregroundStyle(WriterPalette.secondary)
                    if #available(iOS 18.0, *) {
                        NoteComposerField(text: $text, placeholder: isTask ? "やることを書く…" : "ひとこと書く…", markerRequest: markerRequest, writing: $writing)
                    } else {
                        TextField(isTask ? "やることを書く…" : "ひとこと書く…", text: $text, prompt: Text(isTask ? "やることを書く…" : "ひとこと書く…").foregroundStyle(WriterPalette.placeholder), axis: .vertical)
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
    var placeholder: String
    var markerRequest: Int
    var writing: FocusState<Bool>.Binding
    @State private var selection: TextSelection?
    var body: some View {
        TextField(placeholder, text: $text, selection: $selection, prompt: Text(placeholder).foregroundStyle(WriterPalette.placeholder), axis: .vertical)
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
                    }.font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                    if let error = store.tagStorageError { Text(error).font(.writerCaption).foregroundStyle(.red) }
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
                    if let error = store.storageError { Text(error).font(.writerCaption).foregroundStyle(.red); Button("再保存") { store.update(note) } }
                    Text(note.date, format: .dateTime.year().month().day().hour().minute()).font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                    TextField("ふと思ったことを書いてみよう", text: $note.body, axis: .vertical)
                        .lineLimit(3...24).font(.subheadline).lineSpacing(2).accessibilityIdentifier("private-note-body")
                        .padding(.vertical, 8)
                    NoteTagSuggestions(text: $note.body, tags: store.tags, manage: { managingTags = true }, hide: { store.hideTag($0) })
                    Toggle("TODOとして残す", isOn: Binding(get: { note.task != nil }, set: { enabled in
                        note.task = enabled ? NoteTask() : nil
                    })).font(.subheadline).accessibilityIdentifier("private-note-is-task")
                    if let task = note.task {
                        NoteTaskDeadlinePicker(date: Binding(get: { note.task?.dueDate }, set: { note.task?.dueDate = $0 }))
                        HStack {
                            NoteTaskCheckButton(note: note) { note.task?.completedAt = task.isCompleted ? nil : Date() }
                            Text(task.isCompleted ? "完了 · タップで未完了に戻す" : "未完了 · タップで完了にする").font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                        }
                        if task.isCompleted { NoteTaskStatus(task: task) }
                        Text("完了しても、このメモと締め切りは日記に残ります。").font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                    }
                    DisclosureGroup("日付・タイトル") {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("タイトル（なくても大丈夫）", text: $note.title).accessibilityIdentifier("private-note-title")
                            DatePicker("記録の日時", selection: $note.date).environment(\.locale, Locale(identifier: "ja_JP"))
                            Picker("記録の種類", selection: $note.kind) { ForEach(NoteKind.allCases) { kind in Text(kind.label).tag(kind) } }
                        }.padding(.top, 12)
                    }.font(.subheadline)
                    Label("この端末に自動保存", systemImage: "lock").font(.writerCaption).foregroundStyle(WriterPalette.secondary)
                }.padding(16)
            }.background(WriterPalette.background).scrollDismissesKeyboard(.interactively)
                .writerChrome().navigationTitle("ひとことを編集").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完了") { if store.update(note) { dismiss() } } }
                }
                .interactiveDismissDisabled(store.storageError != nil)
                .onChange(of: store.notes) { _, values in
                    if let latest = values.first(where: { $0.id == note.id }) {
                        note = note.synchronizingTaskCompletion(from: latest)
                    }
                }
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
                    if let error = store.storageError { Text(error).font(.writerCaption).foregroundStyle(.red); Button("再保存") { store.persist() } }
                    if store.trash.isEmpty { Text("ゴミ箱は空です").foregroundStyle(WriterPalette.secondary) }
                    ForEach(store.trash) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.displayTitle).font(.subheadline.weight(.medium))
                            HStack { Button("復元") { store.restore(note.id) }.accessibilityIdentifier("restore-note-" + note.id.uuidString); Spacer(); Button("完全に削除", role: .destructive) { deleting = note }.accessibilityIdentifier("delete-note-" + note.id.uuidString) }.font(.writerCaption).buttonStyle(.borderless).frame(minHeight: 32)
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
    #if targetEnvironment(macCatalyst)
    Button(action: action) {
        Text(title).font(.writerCaption.weight(active ? .semibold : .regular)).fixedSize()
            .foregroundStyle(active ? WriterPalette.text : WriterPalette.secondary)
            .padding(.horizontal, 9).frame(minHeight: 29)
            .background(active ? WriterPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }.buttonStyle(.plain).accessibilityValue(active ? "選択中" : "")
    #else
    Button(action: action) { Text(title).font(.writerCaption.weight(active ? .semibold : .regular)).padding(.horizontal, 13).frame(minHeight: 34).foregroundStyle(active ? WriterPalette.onAccent : WriterPalette.text).background(active ? Color.accentColor : WriterPalette.inactiveFilter, in: Capsule()) }.buttonStyle(.plain).accessibilityValue(active ? "選択中" : "")
    #endif
}
