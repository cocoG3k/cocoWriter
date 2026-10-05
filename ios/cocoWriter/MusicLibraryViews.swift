import SwiftUI

@MainActor struct MusicLibraryView: View {
    @EnvironmentObject private var library: MusicLibraryStore
    @EnvironmentObject private var drafts: DraftStore
    @State private var editing: MusicItem?
    @State private var article: Draft?
    @State private var picking = false
    @State private var pendingArticle: Draft?
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                if let error = library.storageError ?? drafts.storageError { Text(error).font(.caption).foregroundStyle(.red) }
                Section {
                    Button { picking = true } label: { Label("ストックから曲紹介を書く", systemImage: "square.and.pencil") }
                        .disabled(library.items.isEmpty || !drafts.loaded || drafts.storageError != nil)
                        .accessibilityIdentifier("music-library-create-article")
                } footer: { Text("投稿した曲はストックから外れ、記事を下書きに戻すと再び表示されます。記事内での編集は、その記事にだけ反映されます。") }
                Section("保存した曲・アルバム（\(library.items.count)件）") {
                    if library.items.isEmpty { Text("共有画面から保存するか、＋で曲を追加できます。").foregroundStyle(WriterPalette.secondary) }
                    ForEach(library.items.filter { musicMatches($0, search: search) }) { item in
                        Button { editing = item } label: { MusicLibraryRow(item: item).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                            .accessibilityIdentifier("music-library-row-" + item.id.uuidString)
                    }
                }
            }.writerCanvas().writerChrome().navigationTitle("曲のストック").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "曲名・アーティスト・紹介文")
                .toolbar { Button { let item = MusicItem(); if library.update(item) { editing = item } } label: { Image(systemName: "plus") }.disabled(!library.loaded).accessibilityLabel("曲をストックに追加").accessibilityIdentifier("music-library-add") }
                .sheet(item: $editing) { item in MusicLibraryEditor(item: item) }
                .sheet(item: $article) { draft in NavigationStack { EditorView(draft: draft) } }
                .sheet(isPresented: $picking, onDismiss: { article = pendingArticle; pendingArticle = nil }) {
                    MusicLibraryPicker(existing: []) { items in
                        var draft = Draft(kind: .music); draft.tags = "曲紹介"; draft.music = MusicLibraryStore.articleCopies(items)
                        if drafts.update(draft) { pendingArticle = draft }
                    }
                }
        }
    }
}

@MainActor struct MusicLibraryEditor: View {
    @EnvironmentObject private var library: MusicLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var item: MusicItem
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                if let error = library.storageError { Section { Text(error).foregroundStyle(.red); Button("再保存") { library.update(item) } } }
                Section { MusicItemEditor(item: $item) { deleting = true } }
                Section { Text("書きかけのまま保存できます。Spotifyの確認は記事を公開するまでに行ってください。").font(.caption).foregroundStyle(WriterPalette.secondary) }
            }.writerCanvas().writerChrome().navigationTitle("曲をストックに保存").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完了") { if library.update(item) { dismiss() } } }
                .onChange(of: item) { _, value in library.update(value) }
                .interactiveDismissDisabled(library.storageError != nil)
                .confirmationDialog("ストックから削除しますか？記事に入れた曲は残ります。", isPresented: $deleting, titleVisibility: .visible) {
                    Button("ストックから削除", role: .destructive) { if library.remove(item.id) { dismiss() } }
                }
        }
    }
}

@MainActor struct MusicLibraryPicker: View {
    @EnvironmentObject private var library: MusicLibraryStore
    @Environment(\.dismiss) private var dismiss
    let existing: [MusicItem]
    let onSelect: ([MusicItem]) -> Void
    @State private var selected = Set<UUID>()
    @State private var search = ""
    private var used: Set<UUID> { Set(existing.map { $0.sourceID ?? $0.id }) }
    var body: some View {
        NavigationStack {
            List {
                if let error = library.storageError { Text(error).foregroundStyle(.red) }
                if library.items.isEmpty { Text("「曲のストック」で先に曲を保存してください。") }
                ForEach(library.items.filter { musicMatches($0, search: search) }) { item in
                    Button {
                        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                    } label: {
                        HStack {
                            MusicLibraryRow(item: item)
                            Spacer()
                            if used.contains(item.id) { Text("追加済み").font(.caption) }
                            else { Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle") }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(used.contains(item.id))
                        .accessibilityIdentifier("music-stock-select-" + item.id.uuidString)
                        .accessibilityValue(used.contains(item.id) ? "追加済み" : selected.contains(item.id) ? "選択済み" : "未選択")
                }
            }.writerCanvas().writerChrome().navigationTitle("掲載する曲を選ぶ").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "曲名・アーティスト・紹介文")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("追加（\(selected.count)）") {
                            let items = library.items.filter { selected.contains($0.id) && !used.contains($0.id) }
                            dismiss(); onSelect(items)
                        }.disabled(selected.isEmpty).accessibilityIdentifier("music-stock-add-selected")
                    }
                }
        }
    }
}

private struct MusicLibraryRow: View {
    let item: MusicItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title.isEmpty ? "曲名は未入力" : item.title).font(.headline)
            if !item.artist.isEmpty { Text(item.artist).font(.caption).foregroundStyle(WriterPalette.secondary) }
            if !item.comment.isEmpty { Text(item.comment).font(.caption).lineLimit(2).foregroundStyle(WriterPalette.secondary) }
            if item.title.isEmpty, !item.youtubeURL.isEmpty { Text(item.youtubeURL).font(.caption2).lineLimit(1).foregroundStyle(WriterPalette.secondary) }
        }.padding(.vertical, 4)
    }
}
private func musicMatches(_ item: MusicItem, search: String) -> Bool {
    search.isEmpty || [item.title, item.artist, item.comment].contains { $0.localizedStandardContains(search) }
}
