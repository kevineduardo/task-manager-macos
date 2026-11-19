import Foundation

struct AppUsage: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var iconPath: String?
    var isApp: Bool
    var cpuTime: Double = 0
    var networkBytes: UInt64 = 0
    var diskBytes: UInt64 = 0
    var lastSeen = Date()
}

/// Accumulates CPU time, network and disk traffic per app across sessions,
/// like the App history page on Windows. Stored as JSON in Application Support.
final class AppHistoryStore: ObservableObject {
    @Published private(set) var entries: [String: AppUsage] = [:]
    @Published private(set) var since = Date()

    private struct Last {
        var cpu: Double
        var network: UInt64
        var disk: UInt64
    }

    private struct Stored: Codable {
        var since: Date
        var entries: [AppUsage]
    }

    private var last: [Int32: Last] = [:]
    private var dirty = false
    private var lastSave = Date()
    private let fileURL: URL?

    init(fileURL: URL? = AppHistoryStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("TaskManager", isDirectory: true).appendingPathComponent("app-history.json")
    }

    static func key(for node: ProcessNode) -> String {
        if node.id.hasPrefix("app:") { return node.id }
        if let bundle = node.primary.bundlePath { return "bundle:" + bundle }
        return "proc:" + node.primary.executableName
    }

    func ingest(_ nodes: [ProcessNode]) {
        var next: [Int32: Last] = [:]
        var changed = entries
        for node in nodes {
            var cpu: Double = 0
            var network: UInt64 = 0
            var disk: UInt64 = 0
            for member in node.members {
                let now = Last(cpu: member.cpuTime, network: member.networkTotal,
                               disk: member.diskReadTotal &+ member.diskWriteTotal)
                next[member.pid] = now
                // Only count growth seen while we were watching; the first sighting sets the baseline.
                guard let before = last[member.pid] else { continue }
                if now.cpu > before.cpu { cpu += now.cpu - before.cpu }
                if now.network > before.network { network += now.network - before.network }
                if now.disk > before.disk { disk += now.disk - before.disk }
            }
            guard cpu > 0 || network > 0 || disk > 0 else { continue }
            let key = Self.key(for: node)
            var usage = changed[key] ?? AppUsage(
                id: key, name: node.name, iconPath: node.iconPath,
                isApp: node.kind == .app || (node.kind == .background && node.primary.bundlePath != nil)
            )
            usage.name = node.name
            usage.cpuTime += cpu
            usage.networkBytes += network
            usage.diskBytes += disk
            usage.lastSeen = Date()
            changed[key] = usage
        }
        last = next
        if changed != entries {
            entries = changed
            dirty = true
        }
        if dirty, Date().timeIntervalSince(lastSave) > 60 { save() }
    }

    func reset() {
        entries = [:]
        since = Date()
        dirty = true
        save()
    }

    func save() {
        guard let fileURL else { return }
        dirty = false
        lastSave = Date()
        let stored = Stored(since: since, entries: Array(entries.values))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("TaskManager: could not save app history: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        since = stored.since
        entries = Dictionary(stored.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
