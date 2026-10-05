import SwiftUI
import UIKit

// Keep the existing system colors in light mode; the dark palette matches the
// charcoal/mint design, including readable text on filled mint controls.
enum WriterPalette {
    static let background = adaptive(light: .systemGroupedBackground, dark: 0x151B1A)
    static let surface = adaptive(light: .secondarySystemGroupedBackground, dark: 0x232C29)
    static let chrome = adaptive(light: .systemBackground, dark: 0x1B2321)
    static let selected = adaptive(light: .label.withAlphaComponent(0.09), dark: 0x30473D)
    static let text = adaptive(light: .label, dark: 0xE6EBE7)
    static let secondary = adaptive(light: .secondaryLabel, dark: 0xA4AFA9)
    static let placeholder = adaptive(light: .placeholderText, dark: 0xA4AFA9)
    static let separator = adaptive(light: .separator, dark: 0x35403B)
    static let accent = adaptive(light: UIColor(red: 0.13, green: 0.37, blue: 0.32, alpha: 1), dark: 0x99C7B2)
    static let onAccent = adaptive(light: .white, dark: 0x151B1A)
    static let selectedText = adaptive(light: .label, dark: 0x99C7B2)
    static let inactiveFilter = adaptive(light: .tertiarySystemGroupedBackground, dark: 0x232C29)

    private static func adaptive(light: UIColor, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            guard traits.userInterfaceStyle == .dark else { return light }
            return UIColor(red: CGFloat((dark >> 16) & 0xFF) / 255,
                           green: CGFloat((dark >> 8) & 0xFF) / 255,
                           blue: CGFloat(dark & 0xFF) / 255, alpha: 1)
        })
    }
}

private struct WriterCanvas: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
            .background(colorScheme == .dark ? WriterPalette.background : Color.clear)
    }
}

private struct WriterChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.background(WriterPalette.background)
                .toolbarBackground(WriterPalette.background, for: .navigationBar)
                .toolbarBackground(WriterPalette.chrome, for: .tabBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

private struct WriterBar: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.background(colorScheme == .dark ? AnyShapeStyle(WriterPalette.chrome) : AnyShapeStyle(.bar))
    }
}

extension View {
    func writerCanvas() -> some View { modifier(WriterCanvas()) }
    func writerChrome() -> some View { modifier(WriterChrome()) }
    func writerBarBackground() -> some View { modifier(WriterBar()) }
}

@main @MainActor struct cocoWriterApp: App {
    @StateObject private var store = DraftStore()
    @StateObject private var notes = PrivateNoteStore()
    @StateObject private var musicLibrary = MusicLibraryStore()
    var body: some Scene {
        WindowGroup {
            DraftListView().environmentObject(store).environmentObject(notes).environmentObject(musicLibrary)
                .tint(WriterPalette.accent).accentColor(WriterPalette.accent)
        }
    }
}
