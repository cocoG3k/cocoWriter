import SwiftUI
import UIKit

// Keep the existing system colors in light mode; the dark palette matches the
// charcoal/mint design, including readable text on filled mint controls.
enum WriterPalette {
    #if targetEnvironment(macCatalyst)
    // The Mac workspace uses neutral surfaces and restrained contrast. The
    // iPhone palette remains independent of these desktop-specific colors.
    static let background = adaptive(light: .systemGroupedBackground, dark: 0x111111)
    static let surface = adaptive(light: .secondarySystemGroupedBackground, dark: 0x1A1A1A)
    static let chrome = adaptive(light: .systemBackground, dark: 0x0D0D0D)
    static let selected = adaptive(light: .label.withAlphaComponent(0.08), dark: 0x292929)
    static let text = adaptive(light: .label, dark: 0xECECEC)
    static let secondary = adaptive(light: .secondaryLabel, dark: 0xA2A2A2)
    static let placeholder = adaptive(light: .placeholderText, dark: 0x858585)
    static let separator = adaptive(light: .separator, dark: 0x363636)
    static let accent = adaptive(light: UIColor(white: 0.16, alpha: 1), dark: 0xE8E8E8)
    static let onAccent = adaptive(light: .white, dark: 0x151515)
    static let selectedText = adaptive(light: .label, dark: 0xF2F2F2)
    static let inactiveFilter = adaptive(light: .tertiarySystemGroupedBackground, dark: 0x202020)
    #else
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
    #endif

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

extension Font {
    // Supporting text remains legible on a desktop without changing iPhone typography.
    static var writerCaption: Font {
        #if targetEnvironment(macCatalyst)
        .system(size: 13)
        #else
        .caption
        #endif
    }
    static var writerCaption2: Font {
        #if targetEnvironment(macCatalyst)
        .system(size: 12)
        #else
        .caption2
        #endif
    }
    static var writerCode: Font {
        #if targetEnvironment(macCatalyst)
        .system(size: 13, design: .monospaced)
        #else
        .system(.caption, design: .monospaced)
        #endif
    }
    static func writerSmall(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        #if targetEnvironment(macCatalyst)
        .system(size: max(size, 12), weight: weight, design: design)
        #else
        .system(size: size, weight: weight, design: design)
        #endif
    }
}

@main @MainActor struct cocoWriterApp: App {
    @StateObject private var store = DraftStore()
    @StateObject private var notes = PrivateNoteStore()
    @StateObject private var musicLibrary = MusicLibraryStore()
    #if targetEnvironment(macCatalyst)
    @AppStorage("mac-appearance") private var macAppearance = "dark"
    private var macColorScheme: ColorScheme? {
        switch macAppearance {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }
    private var macControlTint: Color {
        switch macAppearance {
        case "light": return .black
        case "system": return .primary
        default: return .white
        }
    }
    #endif
    var body: some Scene {
        WindowGroup {
            DraftListView().environmentObject(store).environmentObject(notes).environmentObject(musicLibrary)
                #if targetEnvironment(macCatalyst)
                .tint(macControlTint).accentColor(macControlTint)
                .preferredColorScheme(macColorScheme)
                #else
                .tint(WriterPalette.accent).accentColor(WriterPalette.accent)
                #endif
        }
        #if targetEnvironment(macCatalyst)
        .commands { MacWriterCommands() }
        #endif
    }
}
