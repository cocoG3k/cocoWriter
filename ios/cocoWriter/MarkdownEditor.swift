import SwiftUI
import UIKit

enum MarkdownAction {
    case heading(Int), bold, italic, bullet, numbered, quote, code, link
}

struct MarkdownEdit {
    let text: String
    let selection: NSRange
}

enum MarkdownEditing {
    static func apply(_ action: MarkdownAction, to text: String, selection: NSRange) -> MarkdownEdit {
        let source = text as NSString
        let start = min(max(selection.location, 0), source.length)
        let range = NSRange(location: start, length: min(max(selection.length, 0), source.length - start))
        switch action {
        case .bold: return wrap("**", placeholder: "太字", source: source, range: range)
        case .italic: return wrap("*", placeholder: "斜体", source: source, range: range)
        case .code: return wrap("`", placeholder: "コード", source: source, range: range)
        case .link:
            let label = range.length == 0 ? "リンクの文字" : source.substring(with: range)
            let replacement = "[\(label)](https://)"
            return MarkdownEdit(text: source.replacingCharacters(in: range, with: replacement),
                selection: NSRange(location: start + (label as NSString).length + 3, length: 8))
        default:
            let lineRange = source.lineRange(for: range)
            let original = source.substring(with: lineRange)
            let trailingNewline = original.hasSuffix("\n")
            var lines = original.components(separatedBy: "\n")
            if trailingNewline { lines.removeLast() }
            let prefix: (Int) -> String = { index in
                switch action {
                case .heading(let level): return String(repeating: "#", count: min(max(level, 1), 6)) + " "
                case .bullet: return "- "
                case .numbered: return "\(index + 1). "
                case .quote: return "> "
                default: return ""
                }
            }
            let existingPrefix: (String, Int) -> String? = { line, index in
                if case .numbered = action, let match = line.range(of: "^[0-9]+\\. +", options: .regularExpression) { return String(line[match]) }
                let expected = prefix(index)
                return line.hasPrefix(expected) ? expected : nil
            }
            let removing = lines.enumerated().allSatisfy { existingPrefix($0.element, $0.offset) != nil }
            let transformed = lines.enumerated().map { index, line -> String in
                if removing { return String(line.dropFirst(existingPrefix(line, index)!.count)) }
                var content = line
                if case .heading = action {
                    content = line.replacingOccurrences(of: "^#{1,6} +", with: "", options: .regularExpression)
                }
                if case .bullet = action { content = content.replacingOccurrences(of: "^(?:[-+*] +|[0-9]+\\. +)", with: "", options: .regularExpression) }
                if case .numbered = action { content = content.replacingOccurrences(of: "^(?:[-+*] +|[0-9]+\\. +)", with: "", options: .regularExpression) }
                return prefix(index) + content
            }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
            let changed = source.replacingCharacters(in: lineRange, with: transformed)
            if range.length == 0 {
                let delta = (transformed as NSString).length - (original as NSString).length
                return MarkdownEdit(text: changed, selection: NSRange(location: max(lineRange.location, start + delta), length: 0))
            }
            return MarkdownEdit(text: changed, selection: NSRange(location: lineRange.location, length: (transformed as NSString).length - (trailingNewline ? 1 : 0)))
        }
    }

    private static func wrap(_ marker: String, placeholder: String, source: NSString, range: NSRange) -> MarkdownEdit {
        let length = (marker as NSString).length
        func hasItalic(_ left: Int, _ right: Int) -> Bool {
            guard marker == "*" else { return true }
            var before = 0, after = 0
            var i = left - 1
            while i >= 0 && source.character(at: i) == 42 { before += 1; i -= 1 }
            i = right
            while i < source.length && source.character(at: i) == 42 { after += 1; i += 1 }
            return before % 2 == 1 && after % 2 == 1
        }
        if range.location >= length, NSMaxRange(range) + length <= source.length,
           source.substring(with: NSRange(location: range.location - length, length: length)) == marker,
           source.substring(with: NSRange(location: NSMaxRange(range), length: length)) == marker,
           hasItalic(range.location, NSMaxRange(range)) {
            let expanded = NSRange(location: range.location - length, length: range.length + length * 2)
            return MarkdownEdit(text: source.replacingCharacters(in: expanded, with: source.substring(with: range)),
                selection: NSRange(location: expanded.location, length: range.length))
        }
        let selected = source.substring(with: range)
        let leadingStars = selected.prefix(while: { $0 == "*" }).count
        let trailingStars = selected.reversed().prefix(while: { $0 == "*" }).count
        let selectedHasItalic = marker != "*" || (leadingStars % 2 == 1 && trailingStars % 2 == 1)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), range.length >= length * 2, selectedHasItalic {
            let inner = (selected as NSString).substring(with: NSRange(location: length, length: range.length - length * 2))
            return MarkdownEdit(text: source.replacingCharacters(in: range, with: inner), selection: NSRange(location: range.location, length: (inner as NSString).length))
        }
        let content = range.length == 0 ? placeholder : selected
        return MarkdownEdit(text: source.replacingCharacters(in: range, with: marker + content + marker),
            selection: NSRange(location: range.location + length, length: (content as NSString).length))
    }
}

@MainActor final class MarkdownEditorControl: ObservableObject {
    weak var textView: UITextView?
    func apply(_ action: MarkdownAction) {
        guard let view = textView else { return }
        view.becomeFirstResponder()
        let edit = MarkdownEditing.apply(action, to: view.text ?? "", selection: view.selectedRange)
        restore(edit.text, selection: edit.selection)
    }
    private func restore(_ text: String, selection: NSRange) {
        guard let view = textView else { return }
        let previous = view.text ?? ""
        let previousSelection = view.selectedRange
        view.undoManager?.registerUndo(withTarget: self) { control in
            control.restore(previous, selection: previousSelection)
        }
        view.text = text
        view.selectedRange = selection
        view.delegate?.textViewDidChange?(view)
        view.scrollRangeToVisible(selection)
    }
    func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

struct MarkdownEditor: View {
    @Binding var text: String
    var identifier = "body-editor"
    var minHeight: CGFloat = 240
    var onAddMusic: (() -> Void)?
    var onChooseMusic: (() -> Void)?
    var onAddPhoto: (() -> Void)?
    var onAddImageFile: (() -> Void)?
    @StateObject private var control = MarkdownEditorControl()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    Button("大見出し · H1") { control.apply(.heading(1)) }
                    Button("見出し · H2") { control.apply(.heading(2)) }
                    Button("小見出し · H3") { control.apply(.heading(3)) }
                } label: { Text("H").font(.headline).frame(width: 38, height: 40) }
                    .accessibilityLabel("見出し").accessibilityIdentifier(identifier + "-heading")
                tool("B", label: "太字", action: .bold, font: .body.bold())
                tool("I", label: "斜体", action: .italic, font: .body.italic())
                if onAddMusic == nil && onAddPhoto == nil {
                    icon("list.bullet", label: "箇条書き", action: .bullet)
                    icon("list.number", label: "番号付きリスト", action: .numbered)
                }
                Menu {
                    if onAddMusic != nil || onAddPhoto != nil {
                        Button("箇条書き") { control.apply(.bullet) }
                        Button("番号付きリスト") { control.apply(.numbered) }
                    }
                    Button("引用") { control.apply(.quote) }
                    Button("コード") { control.apply(.code) }
                    Button("リンク") { control.apply(.link) }
                } label: { Image(systemName: "ellipsis").frame(width: 36, height: 40) }.accessibilityLabel("その他の書式")
                if let onAddMusic {
                    Menu {
                        Button("曲紹介を書く") { control.dismissKeyboard(); onAddMusic() }
                        if let onChooseMusic { Button("ストックから選ぶ") { control.dismissKeyboard(); onChooseMusic() } }
                    } label: { Image(systemName: "music.note").frame(width: 36, height: 40) }
                        .accessibilityLabel("曲紹介を追加").accessibilityIdentifier(identifier + "-music")
                }
                if let onAddPhoto {
                    Menu {
                        Button("写真から追加") { control.dismissKeyboard(); onAddPhoto() }
                        if let onAddImageFile { Button("画像ファイルから追加") { control.dismissKeyboard(); onAddImageFile() } }
                    } label: { Image(systemName: "photo").frame(width: 36, height: 40) }
                        .accessibilityLabel("画像を追加").accessibilityIdentifier(identifier + "-image")
                }
                Spacer(minLength: 0)
                Button { control.dismissKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down").frame(width: 34, height: 40) }
                    .accessibilityLabel("キーボードを閉じる")
            }.foregroundStyle(Color.accentColor).padding(.horizontal, 4).background(WriterPalette.surface)
            Divider()
            MarkdownTextView(text: $text, control: control, identifier: identifier)
                .frame(minHeight: minHeight)
                .background(WriterPalette.surface)
        }.buttonStyle(.borderless).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WriterPalette.separator.opacity(0.35)))
    }
    private func tool(_ title: String, label: String, action: MarkdownAction, font: Font) -> some View {
        Button { control.apply(action) } label: { Text(title).font(font).frame(width: 34, height: 40) }
            .accessibilityLabel(label).accessibilityIdentifier(identifier + "-" + label)
    }
    private func icon(_ symbol: String, label: String, action: MarkdownAction) -> some View {
        Button { control.apply(action) } label: { Image(systemName: symbol).frame(width: 36, height: 40) }
            .accessibilityLabel(label).accessibilityIdentifier(identifier + "-" + label)
    }
}

private struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    let control: MarkdownEditorControl
    let identifier: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = UIColor(WriterPalette.text)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 10, bottom: 20, right: 10)
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = identifier.hasPrefix("music-comment") ? "曲のコメント" : "本文"
        view.delegate = context.coordinator
        view.text = text
        control.textView = view
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.textColor = UIColor(WriterPalette.text)
        control.textView = view
        if view.text != text { view.text = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        init(parent: MarkdownTextView) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text ?? "" }
    }
}
