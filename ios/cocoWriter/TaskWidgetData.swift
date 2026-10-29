import Foundation

// A projection for widgets; private-notes.json stays in its original location.
struct WidgetTask: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var dueDate: Date?
    var createdAt: Date
    var updatedAt: Date
}

enum WidgetTaskOrder: String, Codable, CaseIterable, Sendable {
    case deadline, oldest, newest

    func sorted(_ tasks: [WidgetTask]) -> [WidgetTask] {
        tasks.sorted {
            if self == .deadline {
                let lhs = $0.dueDate ?? .distantFuture, rhs = $1.dueDate ?? .distantFuture
                if lhs != rhs { return lhs < rhs }
            }
            if $0.createdAt != $1.createdAt { return self == .newest ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct TaskWidgetSnapshot: Codable, Equatable {
    var tasks: [WidgetTask]
}

struct WidgetTaskCompletion: Codable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var expectedUpdate: Date
    var completedAt = Date()
}

enum TaskWidgetData {
    static let kind = "WriterTodos"
    static var directory: URL? {
        AppConfiguration.sharedContainerURL()?.appendingPathComponent("TaskWidgets", isDirectory: true)
    }
    static var appURL: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "org.example.cocoWriter"
        let appID = bundleID.hasSuffix(".Todos") ? String(bundleID.dropLast(6)) : bundleID
        return URL(string: appID + "://todos")!
    }
    static func completions(in directory: URL) throws -> [(URL, WidgetTaskCompletion)] {
        let inbox = directory.appendingPathComponent("Completions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: inbox.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { ($0, try JSONDecoder().decode(WidgetTaskCompletion.self, from: Data(contentsOf: $0))) }
            .sorted { $0.1.completedAt < $1.1.completedAt }
    }
    static func read(from directory: URL) throws -> TaskWidgetSnapshot {
        let snapshot = try JSONDecoder().decode(TaskWidgetSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("tasks.json")))
        let pending = try completions(in: directory).map(\.1)
        return TaskWidgetSnapshot(tasks: snapshot.tasks.filter { task in
            !pending.contains { $0.taskID == task.id && $0.expectedUpdate == task.updatedAt }
        })
    }
    static func publish(_ tasks: [WidgetTask], to directory: URL) throws {
        try write(TaskWidgetSnapshot(tasks: tasks), to: directory.appendingPathComponent("tasks.json"))
    }
    static func complete(_ task: WidgetTask, in directory: URL) throws {
        let command = WidgetTaskCompletion(taskID: task.id, expectedUpdate: task.updatedAt)
        try write(command, to: directory.appendingPathComponent("Completions", isDirectory: true).appendingPathComponent(command.id.uuidString + ".json"))
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
