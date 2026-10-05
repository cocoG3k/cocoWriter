import SwiftUI

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
    var body: some View {
        List {
            Group {
                if let inventory = DependencyInventory.bundled {
                    Section {
                        Text("このアプリで使用しているライブラリのライセンスです。").font(.caption).foregroundStyle(WriterPalette.secondary)
                    }
                    ForEach(inventory.components) { component in
                        Section {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(component.name).font(.subheadline.bold()); Spacer(); Text(component.version).font(.caption.monospaced()) }
                                Text(component.licenses.map(\.expression).joined(separator: " / ")).font(.caption).textSelection(.enabled)
                            }.padding(.vertical, 3)
                            NavigationLink("ライセンス全文") { ResourceTextView(title: component.name, text: DependencyInventory.resource(component.licenseFile)) }
                                .accessibilityIdentifier("dependency-license-" + component.name)
                            if component.name == "swift-markdown" { NavigationLink("著作権・NOTICE") { ResourceTextView(title: "Swift Markdown NOTICE", text: DependencyInventory.resource("SwiftMarkdown-NOTICE.txt")) }.accessibilityIdentifier("dependency-notice") }
                            if let source = component.externalReferences.first { Link("ソースを確認", destination: source.url) }
                        }
                    }
                } else { Text("ライセンス情報を読み込めませんでした。").foregroundStyle(.red) }
            }.listRowBackground(WriterPalette.surface)
        }.writerCanvas().writerChrome().navigationTitle("ライセンス").navigationBarTitleDisplayMode(.inline)
    }
}
private struct ResourceTextView: View {
    let title: String
    let text: String
    var body: some View { ScrollView { Text(text).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(16) }.writerChrome().navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
}
