import SwiftUI
import WebKit
import Markdown

enum BlogPreviewHTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func renderMarkdown(_ text: String, imageSources: [String: String] = [:], configuration: SiteConfiguration = .current) -> String {
        var renderer = Renderer(imageSources: imageSources, configuration: configuration)
        return renderer.visit(Document(parsing: text, options: [.disableSmartOpts]))
    }
    static func document(_ draft: Draft, imageFiles: ArticleImageFiles = ArticleImageFiles(), configuration: SiteConfiguration = .current, template: String? = nil) -> String {
        let css = Bundle.main.url(forResource: "BlogPreview", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy.MM.dd"
        let tags = draft.tags.components(separatedBy: CharacterSet(charactersIn: ",、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { "<span>\(escape($0))</span>" }.joined()
        var imageSources: [String: String] = [:]
        for image in draft.referencedImages {
            if let data = try? imageFiles.read(image) {
                imageSources[image.publicPath] = "data:image/jpeg;base64," + data.base64EncodedString()
            }
        }
        var content = renderMarkdown(draft.body, imageSources: imageSources, configuration: configuration)
        if draft.kind == .music {
            for item in draft.music {
                let heading = [item.artist, item.title].filter { !$0.isEmpty }.joined(separator: " - ")
                content += "<h3>\(escape(heading))</h3>"
                if let link = SpotifyLink(item.spotifyURL), item.confirmed {
                    content += "<iframe title=\"Spotify \(escape(item.title))\" src=\"\(link.embedURL.absoluteString)\" width=\"100%\" height=\"352\" style=\"border-radius:12px\" frameborder=\"0\" loading=\"lazy\" allow=\"encrypted-media\"></iframe>"
                } else {
                    content += "<div class=\"preview-placeholder\">Spotifyのリンクを確認すると、ここにプレイヤーが表示されます。</div>"
                }
                content += renderMarkdown(item.comment, imageSources: imageSources, configuration: configuration)
            }
        }
        let theme = template ?? Bundle.main.url(forResource: "BlogPreviewTemplate", withExtension: "html")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if !theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return themedDocument(theme, values: [
                "content": content, "title": escape(draft.title), "description": escape(draft.description),
                "date": escape(draft.profile.formatter("yyyy-MM-dd").string(from: draft.date)),
                "dateJapanese": escape(draft.profile.formatter("yyyy/M/d").string(from: draft.date)),
                "dateISO8601": escape(draft.profile.formatter("yyyy-MM-dd'T'HH:mm:ssXXXXX").string(from: draft.date)),
                "tags": tags, "tagText": escape(draft.tags), "siteTitle": escape(configuration.title), "siteDescription": escape(configuration.tagline)
            ])
        }
        return """
        <!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src https: data:; frame-src https://open.spotify.com; script-src 'none'; form-action 'none'; base-uri 'none'">
        <title>\(escape(draft.title)) | \(escape(configuration.title))</title><style>\(css)</style></head><body><div class="page">
        <header class="site-header"><p class="site-name">\(escape(configuration.title))</p><p class="tagline">\(escape(configuration.tagline))</p></header>
        <nav class="site-nav" aria-label="メインナビゲーション"><span>記事一覧</span><span>このブログについて</span><span>GitHub</span></nav>
        <main id="main" class="reading-layout"><header class="article-header"><div class="article-meta"><time class="date">\(formatter.string(from: draft.date))</time><div class="tag-list">\(tags)</div></div>
        <h1>\(escape(draft.title))</h1><p class="description">\(escape(draft.description))</p></header><article class="prose">\(content)</article>
        </main><footer class="site-footer"><span>© \(escape(configuration.title))</span><span>下書きプレビュー · 未公開</span></footer></div></body></html>
        """
    }

    private static func themedDocument(_ template: String, values: [String: String]) -> String {
        let output = NSMutableString(string: template)
        let tokens = try! NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9]*)\}\}"#)
        // One pass: text entered by the author must never become another placeholder.
        for match in tokens.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let key = (template as NSString).substring(with: match.range(at: 1))
            output.replaceCharacters(in: match.range, with: values[key] ?? "")
        }
        let html = output as String
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline' https:; font-src https: data:; img-src https: data:; frame-src https://open.spotify.com; script-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'\">"
        guard let head = html.range(of: #"<head(?:\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) else { return html }
        var secured = html; secured.insert(contentsOf: policy, at: head.upperBound)
        return secured
    }

    private struct Renderer: MarkupVisitor {
        typealias Result = String
        var imageSources: [String: String] = [:]
        var configuration: SiteConfiguration
        mutating func children(_ node: Markup) -> String { node.children.map { visit($0) }.joined() }
        mutating func tag(_ name: String, _ node: Markup) -> String { "<\(name)>\(children(node))</\(name)>" }
        mutating func defaultVisit(_ markup: Markup) -> String { children(markup) }
        mutating func visitText(_ text: Markdown.Text) -> String { escape(text.string) }
        mutating func visitHeading(_ node: Heading) -> String { tag("h\(node.level)", node) }
        mutating func visitParagraph(_ node: Paragraph) -> String { tag("p", node) }
        mutating func visitStrong(_ node: Strong) -> String { tag("strong", node) }
        mutating func visitEmphasis(_ node: Emphasis) -> String { tag("em", node) }
        mutating func visitStrikethrough(_ node: Strikethrough) -> String { tag("del", node) }
        mutating func visitBlockQuote(_ node: BlockQuote) -> String { tag("blockquote", node) }
        mutating func visitUnorderedList(_ node: UnorderedList) -> String { tag("ul", node) }
        mutating func visitOrderedList(_ node: OrderedList) -> String { "<ol start=\"\(node.startIndex)\">\(children(node))</ol>" }
        mutating func visitListItem(_ node: ListItem) -> String {
            let checkbox = node.checkbox.map { "<input type=\"checkbox\" disabled \($0 == .checked ? "checked" : "")> " } ?? ""
            let content = node.childCount == 1 && node.child(at: 0) is Paragraph ? children(node.child(at: 0)!) : children(node)
            return "<li>\(checkbox)\(content)</li>"
        }
        mutating func visitInlineCode(_ node: InlineCode) -> String { "<code>\(escape(node.code))</code>" }
        mutating func visitCodeBlock(_ node: CodeBlock) -> String { "<pre><code>\(escape(node.code))</code></pre>" }
        mutating func visitThematicBreak(_ node: ThematicBreak) -> String { "<hr>" }
        mutating func visitSoftBreak(_ node: SoftBreak) -> String { "\n" }
        mutating func visitLineBreak(_ node: LineBreak) -> String { "<br>" }
        mutating func visitLink(_ node: Markdown.Link) -> String {
            guard let destination = node.destination, let url = URL(string: destination), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return children(node) }
            return "<a href=\"\(escape(destination))\">\(children(node))</a>"
        }
        mutating func visitImage(_ node: Markdown.Image) -> String {
            guard let source = node.source else { return escape(node.plainText) }
            let resolved: String
            if let local = imageSources[source] { resolved = local }
            else if let url = configuration.previewAssetURL(for: source) { resolved = url.absoluteString }
            else { return escape(node.plainText) }
            return "<img src=\"\(escape(resolved))\" alt=\"\(escape(node.plainText))\">"
        }
        mutating func visitHTMLBlock(_ node: HTMLBlock) -> String {
            if let breaks = breakHTML(node.rawHTML) { return breaks }
            // Imported articles retain their HTML bytes. Only render a single
            // validated Spotify iframe; never execute arbitrary imported HTML.
            let html = node.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = #"^<iframe\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>\s*</iframe>$"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html), let link = SpotifyLink(String(html[range])) {
                return "<iframe title=\"Spotify\" src=\"\(link.embedURL.absoluteString)\" width=\"100%\" height=\"352\" style=\"border-radius:12px\" frameborder=\"0\" loading=\"lazy\" allow=\"encrypted-media\"></iframe>"
            }
            return "<pre>\(escape(node.rawHTML))</pre>"
        }
        private func breakHTML(_ text: String) -> String? {
            let html = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return html.range(of: #"^(?:<(?:br|hr)\s*/?>\s*)+$"#, options: [.regularExpression, .caseInsensitive]) != nil ? html : nil
        }
        mutating func visitInlineHTML(_ node: InlineHTML) -> String { breakHTML(node.rawHTML) ?? escape(node.rawHTML) }
        mutating func visitTable(_ node: Markdown.Table) -> String { tag("table", node) }
        mutating func visitTableHead(_ node: Markdown.Table.Head) -> String { "<thead><tr>\(children(node))</tr></thead>" }
        mutating func visitTableBody(_ node: Markdown.Table.Body) -> String { tag("tbody", node) }
        mutating func visitTableRow(_ node: Markdown.Table.Row) -> String { tag("tr", node) }
        mutating func visitTableCell(_ node: Markdown.Table.Cell) -> String { tag(node.parent is Markdown.Table.Head ? "th" : "td", node) }
    }
}

struct BlogWebPreview: UIViewRepresentable {
    let draft: Draft
    @Binding var loading: Bool
    @Binding var error: String?
    var imageFiles = ArticleImageFiles()
    var configuration: SiteConfiguration = .current
    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading, error: $error) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 1, green: 0.996, blue: 0.98, alpha: 1)
        view.accessibilityIdentifier = "blog-web-preview"
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.loading = $loading
        context.coordinator.error = $error
        let html = BlogPreviewHTML.document(draft, imageFiles: imageFiles, configuration: configuration)
        guard html != context.coordinator.loadedHTML else { return }
        context.coordinator.loadedHTML = html
        DispatchQueue.main.async { loading = true; error = nil }
        view.loadHTMLString(html, baseURL: configuration.websiteURL)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML = ""
        var loading: Binding<Bool>
        var error: Binding<String?>
        init(loading: Binding<Bool>, error: Binding<String?>) { self.loading = loading; self.error = error }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.wrappedValue = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) {
            loading.wrappedValue = false; error.wrappedValue = "プレビューを表示できませんでした。閉じて、もう一度開いてください。"
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
            self.webView(webView, didFail: navigation, withError: failure)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The preview remains in the draft. No live blog navigation or form submission.
            if action.navigationType == .linkActivated || action.navigationType == .formSubmitted { decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        }
    }
}
