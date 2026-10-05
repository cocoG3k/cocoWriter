import SwiftUI
import UniformTypeIdentifiers

struct SBOMDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct DependencyInventory: Decodable {
    let specVersion: String
    let components: [Component]
    struct Component: Decodable, Identifiable {
        let name: String
        let version: String
        let licenses: [License]
        let properties: [Property]
        let externalReferences: [Reference]
        var id: String { name }
        var revision: String { properties.first { $0.name == "cocowriter:git-revision" }?.value ?? "" }
        var role: String { properties.first { $0.name == "cocowriter:dependency" }?.value == "direct" ? "直接依存" : "間接依存" }
        var licenseFile: String { properties.first { $0.name == "cocowriter:license-resource" }?.value ?? "" }
    }
    struct License: Decodable { let expression: String }
    struct Property: Decodable { let name: String; let value: String }
    struct Reference: Decodable { let url: URL }
    static var data: Data? { Bundle.main.url(forResource: "SBOM.cdx", withExtension: "json").flatMap { try? Data(contentsOf: $0) } }
    static var bundled: DependencyInventory? { data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
    static func resource(_ filename: String) -> String {
        let path = filename as NSString
        return Bundle.main.url(forResource: path.deletingPathExtension, withExtension: path.pathExtension).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "ファイルを読み込めませんでした。"
    }
}
struct DependencyInfoView: View {
    @State private var exporting = false
    @State private var message: String?
    var body: some View {
        List {
            Group {
                if let inventory = DependencyInventory.bundled {
                    Section {
                        Text("このビルドが使うライブラリとライセンスです。SBOMはCycloneDX \(inventory.specVersion)形式で書き出せます。").font(.caption).foregroundStyle(WriterPalette.secondary)
                        Button("SBOM（JSON）を書き出す", systemImage: "square.and.arrow.up") { exporting = true }.accessibilityIdentifier("export-sbom")
                    }
                    ForEach(inventory.components) { component in
                        Section {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(component.name).font(.subheadline.bold()); Spacer(); Text(component.version).font(.caption.monospaced()) }
                                Text(component.role).font(.caption).foregroundStyle(WriterPalette.secondary)
                                Text(component.licenses.map(\.expression).joined(separator: " / ")).font(.caption).textSelection(.enabled)
                                Text("commit: \(component.revision)").font(.caption2.monospaced()).foregroundStyle(WriterPalette.secondary).textSelection(.enabled)
                            }.padding(.vertical, 3)
                            NavigationLink("ライセンス全文") { ResourceTextView(title: component.name, text: DependencyInventory.resource(component.licenseFile)) }
                                .accessibilityIdentifier("dependency-license-" + component.name)
                            if component.name == "swift-markdown" { NavigationLink("著作権・NOTICE") { ResourceTextView(title: "Swift Markdown NOTICE", text: DependencyInventory.resource("SwiftMarkdown-NOTICE.txt")) }.accessibilityIdentifier("dependency-notice") }
                            if let source = component.externalReferences.first { Link("ソースを確認", destination: source.url) }
                        }
                    }
                } else { Text("SBOMを読み込めませんでした。").foregroundStyle(.red) }
                Section("Appleの標準フレームワーク") {
                    Text("SwiftUI · UIKit · WebKit · Foundation · Combine · Security · CryptoKit · UniformTypeIdentifiers").font(.caption)
                    Text("iOSに付属する機能を使用します。外部Swiftパッケージとは別に管理しています。").font(.caption2).foregroundStyle(WriterPalette.secondary)
                }
            }.listRowBackground(WriterPalette.surface)
        }.writerCanvas().writerChrome().navigationTitle("依存ライブラリ・SBOM").navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $exporting, document: SBOMDocument(data: DependencyInventory.data ?? Data()), contentType: .json, defaultFilename: "cocoWriter-SBOM.cdx.json") { result in if case .failure(let error) = result { message = error.localizedDescription } }
            .alert("書き出し", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
    }
}
private struct ResourceTextView: View {
    let title: String
    let text: String
    var body: some View { ScrollView { Text(text).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(16) }.writerChrome().navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
}
