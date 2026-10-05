import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: MusicShareView(context: extensionContext))
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

@MainActor private struct MusicShareView: View {
    let context: NSExtensionContext?
    @State private var item = MusicItem()
    @State private var articleTitle = ""
    @State private var introduction = ""
    @State private var createArticle = false
    @State private var loading = true
    @State private var saved = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("共有された曲を読み込んでいます…") }
                if let error { Text(error).foregroundStyle(.red) }
                if !saved {
                    Section("保存する曲") {
                        TextField("YouTube Musicの曲・アルバムURL", text: $item.youtubeURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("曲・アルバム名（後から入力できます）", text: $item.title)
                        TextField("アーティスト（任意）", text: $item.artist)
                        TextField("この音についての紹介文", text: $item.comment, axis: .vertical).lineLimit(4...8)
                    }
                    Section {
                        Picker("保存方法", selection: $createArticle) {
                            Text("曲をストックに保存").tag(false)
                            Text("記事の下書きも作成").tag(true)
                        }.pickerStyle(.inline)
                    }
                    if createArticle {
                        Section("記事を書き始める") {
                            TextField("記事タイトル", text: $articleTitle)
                            TextField("はじめに", text: $introduction, axis: .vertical).lineLimit(4...8)
                        }
                    }
                    Section {
                        Button(createArticle ? "曲と記事の下書きを保存" : "曲を保存") { save() }
                            .disabled(loading || SharedMusicLink.youtube(item.youtubeURL) == nil)
                    } footer: { Text("保存後にcocoWriterを開くと取り込まれます。Spotifyの選択や記事の続きはアプリで編集できます。") }
                } else {
                    Section {
                        Label("保存しました", systemImage: "checkmark.circle.fill")
                        Text(createArticle ? "cocoWriterを開き、「続きを書く」から記事を編集してください。曲はストックにも保存されます。" : "cocoWriterを開くと「曲のストック」に追加されます。")
                        Button("完了") { context?.completeRequest(returningItems: nil) }
                    }
                }
            }.navigationTitle("cocoWriter").navigationBarTitleDisplayMode(.inline)
                .toolbar { if !saved { Button("キャンセル") { context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) } } }
                .task { await readShare() }
        }
    }
    private func save() {
        guard let url = SharedMusicLink.youtube(item.youtubeURL) else { return }
        guard let directory = MusicShareInbox.directory() else {
            error = "共有用の保存先を開けません。アプリと共有拡張のApp Groups設定を確認してください。"; return
        }
        do {
            item.youtubeURL = url.absoluteString
            let request = SharedMusicRequest(item: item, createArticle: createArticle, articleTitle: articleTitle, introduction: introduction)
            try MusicShareInbox.save(request, to: directory)
            error = nil; saved = true
        } catch { self.error = "保存できませんでした。\(error.localizedDescription)" }
    }
    private func readShare() async {
        defer { loading = false }
        let inputs = context?.inputItems as? [NSExtensionItem] ?? []
        for input in inputs {
            for provider in input.attachments ?? [] {
                for type in [UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                    do {
                        let value = try await provider.loadItem(forTypeIdentifier: type, options: nil)
                        let text = (value as? URL)?.absoluteString ?? (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        if let url = SharedMusicLink.extract(text) { item.youtubeURL = url.absoluteString; return }
                    } catch { continue }
                }
            }
            if let text = input.attributedContentText?.string, let url = SharedMusicLink.extract(text) { item.youtubeURL = url.absoluteString; return }
        }
        error = "YouTube Musicの共有URLを読み取れませんでした。曲の共有URLを入力してください。"
    }
}
