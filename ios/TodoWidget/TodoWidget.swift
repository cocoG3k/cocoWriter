import SwiftUI
import WidgetKit
import AppIntents

extension WidgetTaskOrder: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "並び順"
    static let caseDisplayRepresentations: [WidgetTaskOrder: DisplayRepresentation] = [
        .deadline: "期限が早い順", .oldest: "追加が古い順", .newest: "追加が新しい順"
    ]
    var label: String {
        switch self {
        case .deadline: return "期限順"
        case .oldest: return "追加順"
        case .newest: return "新しい順"
        }
    }
}

struct TodoWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "TODOの表示"
    static let description = IntentDescription("未完了のTODOの並び順を選べます。")
    @Parameter(title: "並び順", default: .deadline) var order: WidgetTaskOrder
}

struct CompleteWidgetTask: AppIntent {
    static let title: LocalizedStringResource = "TODOを完了"
    static var isDiscoverable: Bool = false
    @Parameter(title: "タスク") var taskID: String
    @Parameter(title: "更新日時") var revision: Double
    init() {}
    init(task: WidgetTask) {
        taskID = task.id.uuidString
        revision = task.updatedAt.timeIntervalSinceReferenceDate
    }
    func perform() async throws -> some IntentResult {
        guard let directory = TaskWidgetData.directory else { throw TodoWidgetError.unavailable }
        let snapshot = try TaskWidgetData.read(from: directory)
        if let task = snapshot.tasks.first(where: { $0.id.uuidString == taskID && $0.updatedAt.timeIntervalSinceReferenceDate == revision }) {
            try TaskWidgetData.complete(task, in: directory)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: TaskWidgetData.kind)
        return .result()
    }
}

private enum TodoWidgetError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    var localizedStringResource: LocalizedStringResource { "アプリを開いてTODOを確認してください。" }
}

struct TodoWidgetEntry: TimelineEntry {
    var date: Date
    var tasks: [WidgetTask]
    var order: WidgetTaskOrder = .deadline
    var needsApp = false
    static var sample: Self {
        let now = Date()
        return Self(date: now, tasks: ["買い物をする", "原稿を仕上げる", "本を返す", "予約を確認"].enumerated().map { offset, title in
            WidgetTask(id: UUID(), title: title, dueDate: Calendar.current.date(byAdding: .day, value: offset, to: now), createdAt: now, updatedAt: now)
        })
    }
}

struct TodoWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodoWidgetEntry { .sample }
    func snapshot(for configuration: TodoWidgetConfiguration, in context: Context) async -> TodoWidgetEntry {
        context.isPreview ? .sample : entry(configuration)
    }
    func timeline(for configuration: TodoWidgetConfiguration, in context: Context) async -> Timeline<TodoWidgetEntry> {
        let value = entry(configuration)
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: value.date) ?? value.date.addingTimeInterval(1800)
        return Timeline(entries: [value], policy: .after(next))
    }
    private func entry(_ configuration: TodoWidgetConfiguration) -> TodoWidgetEntry {
        guard let directory = TaskWidgetData.directory, let snapshot = try? TaskWidgetData.read(from: directory) else {
            return TodoWidgetEntry(date: Date(), tasks: [], order: configuration.order, needsApp: true)
        }
        return TodoWidgetEntry(date: Date(), tasks: configuration.order.sorted(snapshot.tasks), order: configuration.order)
    }
}

struct TodoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TodoWidgetEntry
    private var small: Bool { family == .systemSmall }
    var body: some View {
        GeometryReader { geometry in
            let limit = max(1, min(5, Int((geometry.size.height - 34) / 23)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("TODO").font(.system(size: 13, weight: .semibold))
                    Text("\(entry.tasks.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !small { Text(entry.order.label).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if entry.needsApp {
                    Spacer(minLength: 0)
                    Text("アプリを開いて\nTODOを表示").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if entry.tasks.isEmpty {
                    Spacer(minLength: 0)
                    Label("TODOはありません", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(entry.tasks.prefix(limit))) { task in
                        HStack(spacing: 5) {
                            Button(intent: CompleteWidgetTask(task: task)) {
                                Image(systemName: "square").font(.system(size: 17, weight: .regular))
                                    .frame(width: 20, height: 20).contentShape(Rectangle())
                            }.buttonStyle(.plain).tint(.primary)
                                .accessibilityLabel("完了: " + task.title)
                            Text(task.title).font(.system(size: small ? 12 : 13)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(deadline(task.dueDate)).font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(overdue(task.dueDate) ? Color.red : Color.secondary)
                                .fixedSize().accessibilityLabel(task.dueDate?.formatted(date: .complete, time: .omitted) ?? "期限なし")
                        }.frame(height: 20).privacySensitive()
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Text(entry.tasks.count > limit ? "ほか\(entry.tasks.count - limit)件" : entry.order.label)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward").accessibilityLabel("アプリで開く")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .widgetURL(TaskWidgetData.appURL)
        .containerBackground(.background, for: .widget)
    }
    private func overdue(_ date: Date?) -> Bool {
        date.map { Calendar.current.startOfDay(for: $0) < Calendar.current.startOfDay(for: entry.date) } ?? false
    }
    private func deadline(_ date: Date?) -> String {
        guard let date else { return "—" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: entry.date) { return "今日" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: entry.date), calendar.isDate(date, inSameDayAs: tomorrow) { return "明日" }
        return date.formatted(.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "ja_JP")))
    }
}

@main struct WriterTodoWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: TaskWidgetData.kind, intent: TodoWidgetConfiguration.self, provider: TodoWidgetProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("TODO")
        .description("チェックで完了。タスク名と期限をコンパクトに表示します。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
