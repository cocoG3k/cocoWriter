import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
// Only presentation differs on Mac. Articles, credentials and publishing use the
// same stores and the same editor as the iPhone application.
private enum MacDestination: String, CaseIterable, Identifiable {
    case articles, album, music, notes, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .articles: return "記事"
        case .album: return "アルバム"
        case .music: return "曲のストック"
        case .notes: return "自分のメモ"
        case .settings: return "設定"
        }
    }
    var symbol: String {
        switch self {
        case .articles: return "doc.text"
        case .album: return "photo.on.rectangle.angled"
        case .music: return "music.note.list"
        case .notes: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

struct MacEditorActions {
    var save: () -> Void
    var preview: () -> Void
    var export: () -> Void
    var disabled: Bool
}
private struct MacInteractionKey: EnvironmentKey {
    static let defaultValue: (UUID, Bool) -> Void = { _, _ in }
}
extension EnvironmentValues {
    var writerInteractionChanged: (UUID, Bool) -> Void {
        get { self[MacInteractionKey.self] }
        set { self[MacInteractionKey.self] = newValue }
    }
}
private struct MacEditorActionsKey: FocusedValueKey { typealias Value = MacEditorActions }
private struct MacNewArticleKey: FocusedValueKey { typealias Value = () -> Void }
private struct MacSettingsKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var writerEditor: MacEditorActions? {
        get { self[MacEditorActionsKey.self] }
        set { self[MacEditorActionsKey.self] = newValue }
    }
    var writerNewArticle: (() -> Void)? {
        get { self[MacNewArticleKey.self] }
        set { self[MacNewArticleKey.self] = newValue }
    }
    var writerSettings: (() -> Void)? {
        get { self[MacSettingsKey.self] }
        set { self[MacSettingsKey.self] = newValue }
    }
}

struct MacWriterCommands: Commands {
    @FocusedValue(\.writerEditor) private var editor
    @FocusedValue(\.writerNewArticle) private var newArticle
    @FocusedValue(\.writerSettings) private var settings
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新規記事") { newArticle?() }.keyboardShortcut("n").disabled(newArticle == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { editor?.save() }.keyboardShortcut("s").disabled(editor == nil || editor?.disabled == true)
            Button("Markdownを書き出す…") { editor?.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil || editor?.disabled == true)
        }
        CommandGroup(replacing: .appSettings) {
            Button("設定…") { settings?() }.keyboardShortcut(",").disabled(settings == nil)
        }
        CommandMenu("記事") {
            Button("プレビュー") { editor?.preview() }.keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(editor == nil || editor?.disabled == true)
        }
    }
}

@MainActor struct MacWorkspaceView: View {
    @EnvironmentObject private var privateNotes: PrivateNoteStore
    @EnvironmentObject private var store: DraftStore
    @AppStorage("mac-appearance") private var macAppearance = "dark"
    @Binding var sharedArticle: Draft?
    @State private var destination: MacDestination = .articles
    @State private var article: Draft?
    @State private var editorBusy = false
    @State private var modalEditors = Set<UUID>()
    @State private var detailExpanded = false
    @State private var message: String?
    private var interactionLocked: Bool { editorBusy || !modalEditors.isEmpty || store.remoteOperations > 0 }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200).disabled(interactionLocked)
            Divider()
            Group {
                switch destination {
                case .articles: articleWorkspace
                case .album: ArticleAlbumView()
                case .music: MusicLibraryView()
                case .notes: PrivateNotesView().frame(maxWidth: 1000).frame(maxWidth: .infinity)
                case .settings: SettingsView().frame(maxWidth: 920).frame(maxWidth: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WriterPalette.background)
        .background(MacWindowConfiguration(appearance: macAppearance))
        .environment(\.writerInteractionChanged, { id, busy in
            if busy { modalEditors.insert(id) } else { modalEditors.remove(id) }
        })
        .focusedSceneValue(\.writerNewArticle, interactionLocked || destination != .articles ? nil : { createArticle() })
        .focusedSceneValue(\.writerSettings, interactionLocked ? nil : { destination = .settings })
        .onChange(of: privateNotes.widgetTasksRequested) { _, requested in
            if requested && !interactionLocked { destination = .notes }
        }
        .onChange(of: sharedArticle?.id) { _, _ in
            openSharedArticle()
        }
        .onChange(of: interactionLocked) { _, busy in if !busy { openSharedArticle() } }
        .onChange(of: article?.id) { _, _ in detailExpanded = false }
        .alert("記事", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(WriterPalette.text)
                    .frame(width: 20)
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "cocoWriter")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WriterPalette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 20)

            sidebarDivider
            Text("ライブラリ")
                .font(.writerCaption2.weight(.medium)).foregroundStyle(WriterPalette.secondary)
                .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 8)
            VStack(spacing: 3) {
                ForEach(MacDestination.allCases.filter { $0 != .settings }) { item in sidebarItem(item) }
            }
            sidebarDivider.padding(.top, 18)
            Text("アプリ")
                .font(.writerCaption2.weight(.medium)).foregroundStyle(WriterPalette.secondary)
                .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 8)
            sidebarItem(.settings)
            Spacer()
            sidebarDivider.padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 7) {
                Label("このMacに保存", systemImage: "internaldrive")
                    .font(.writerCaption.weight(.medium)).foregroundStyle(WriterPalette.text)
                Text("iPhoneと自動同期なし")
                    .font(.writerCaption2).foregroundStyle(WriterPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = store.site.websiteURL {
                    Link(destination: url) {
                        Label("公開サイトを開く", systemImage: "arrow.up.right.square")
                            .font(.writerCaption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(.horizontal, 12)
        }.padding(.horizontal, 10).padding(.bottom, 18)
            .background(WriterPalette.chrome)
    }
    private var sidebarDivider: some View {
        Rectangle().fill(WriterPalette.separator.opacity(0.45)).frame(height: 1)
    }
    private func sidebarItem(_ item: MacDestination) -> some View {
        Button { destination = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .regular)).frame(width: 18)
                Text(item.title).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if item == .articles {
                    Text("\(store.drafts.filter { $0.deletedAt == nil && !$0.isPublished }.count)")
                        .font(.writerCaption.monospacedDigit()).foregroundStyle(WriterPalette.secondary)
                }
            }
            .font(.subheadline.weight(destination == item ? .medium : .regular))
            .foregroundStyle(destination == item ? WriterPalette.selectedText : WriterPalette.secondary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(destination == item ? WriterPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("mac-sidebar-" + item.rawValue)
            .accessibilityAddTraits(destination == item ? .isSelected : [])
    }
    private var articleWorkspace: some View {
        GeometryReader { geometry in
            let showLibrary = !detailExpanded || geometry.size.width > 1050
            HStack(spacing: 0) {
                ArticleLibraryView(selectedArticleID: article?.id, onOpenArticle: { article = $0 })
                    .frame(width: 308).frame(width: showLibrary ? 308 : 0).clipped()
                    .opacity(showLibrary ? 1 : 0).accessibilityHidden(!showLibrary)
                    .allowsHitTesting(showLibrary).disabled(interactionLocked)
                if showLibrary { Divider() }
                NavigationStack {
                    if let article {
                        EditorView(draft: store.drafts.first(where: { $0.id == article.id }) ?? article,
                                   embedded: true, onBusyChange: { editorBusy = $0 }, onClose: { self.article = nil },
                                   onPanelChange: { detailExpanded = $0 })
                            .id(article.id)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 25, weight: .light)).foregroundStyle(WriterPalette.secondary)
                                .padding(.bottom, 2)
                            Text("今日のことばを、ここから。").font(.title3.weight(.medium))
                                .foregroundStyle(WriterPalette.text).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("記事を選んで続きを書くか、新しい記事を作成できます。")
                                .font(.subheadline).foregroundStyle(WriterPalette.secondary).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button { createArticle() } label: {
                                Label("新しい記事を書く", systemImage: "plus")
                                    .font(.subheadline.weight(.semibold)).fixedSize()
                                    .foregroundStyle(WriterPalette.onAccent)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(WriterPalette.accent, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).padding(.top, 4)
                            Text("⌘N 新規記事  ·  編集内容は自動保存")
                                .font(.writerCaption).foregroundStyle(WriterPalette.secondary).multilineTextAlignment(.center)
                        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .navigationTitle("ワークスペース").navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
    }
    private func createArticle() {
        guard !interactionLocked, store.loaded, store.storageError == nil else { message = store.storageError; return }
        if let error = store.categorySettingsError { message = error; return }
        destination = .articles; article = store.newDraft()
    }
    private func openSharedArticle() {
        guard !interactionLocked, let sharedArticle else { return }
        destination = .articles; article = sharedArticle; self.sharedArticle = nil
    }
}

private struct MacWindowConfiguration: UIViewRepresentable {
    var appearance: String
    private var interfaceStyle: UIUserInterfaceStyle {
        switch appearance {
        case "light": return .light
        case "system": return .unspecified
        default: return .dark
        }
    }
    func makeUIView(context: Context) -> SizingView {
        let view = SizingView()
        view.interfaceStyle = interfaceStyle
        return view
    }
    func updateUIView(_ uiView: SizingView, context: Context) { uiView.interfaceStyle = interfaceStyle }
    final class SizingView: UIView {
        var interfaceStyle: UIUserInterfaceStyle = .unspecified {
            didSet { if oldValue != interfaceStyle { window?.overrideUserInterfaceStyle = interfaceStyle } }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 1060, height: 680)
            window?.overrideUserInterfaceStyle = interfaceStyle
        }
    }
}
#endif
