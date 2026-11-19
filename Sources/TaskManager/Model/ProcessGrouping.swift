import Foundation

/// A row in the Processes tree: either one process or an app/bundle with its helpers.
struct ProcessNode: Identifiable, Equatable {
    let id: String
    var name: String
    var kind: ProcessKind
    /// Bundle or executable path used to look up the icon.
    var iconPath: String?
    var primary: ProcessRecord
    /// All member processes, primary included. One element for a plain process.
    var members: [ProcessRecord]

    var cpu: Double = 0
    var memory: UInt64 = 0
    var disk: Double = 0
    var network: Double?
    var gpu: Double?
    var watts: Double?
    var threads: Int = 0

    var isGroup: Bool { members.count > 1 }
    var pids: [Int32] { members.map(\.pid) }
    var power: PowerLevel {
        PowerLevel.estimate(watts: watts, cpuPercent: cpu)
    }

    /// Status shown on the group row: suspended/efficiency only if every member is.
    var status: ProcessStatus {
        guard let first = members.first?.status else { return .running }
        return members.allSatisfy { $0.status == first } ? first : .running
    }

    init(id: String, name: String, kind: ProcessKind, iconPath: String?, members: [ProcessRecord], primary: ProcessRecord) {
        self.id = id
        self.name = name
        self.kind = kind
        self.iconPath = iconPath
        self.members = members
        self.primary = primary
        aggregate()
    }

    mutating func aggregate() {
        cpu = 0; memory = 0; disk = 0; threads = 0
        var net: Double?
        var gpuSum: Double?
        var energy: Double?
        for m in members {
            cpu += m.cpu
            memory += m.memory
            disk += m.disk
            threads += m.threads
            if let n = m.network { net = (net ?? 0) + n }
            if let g = m.gpu { gpuSum = (gpuSum ?? 0) + g }
            if let w = m.watts { energy = (energy ?? 0) + w }
        }
        network = net
        gpu = gpuSum.map { min(100, $0) }
        watts = energy
    }
}

enum ProcessGrouping {
    /// Groups processes the way Windows 11 does: each app with the helpers it
    /// owns (same bundle, responsible process or parent chain), then background
    /// processes that share a bundle or an executable name.
    static func build(_ records: [ProcessRecord]) -> [ProcessNode] {
        let byPid = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var groupOf: [Int32: String] = [:]
        var appGroups: [String: (primary: ProcessRecord, members: [ProcessRecord])] = [:]
        var appByBundle: [String: String] = [:]
        var order: [String] = []

        // 1. Dock apps are group roots.
        for record in records where record.isRegularApp {
            let key = "app:" + (record.bundlePath ?? "\(record.pid)")
            if appGroups[key] == nil {
                appGroups[key] = (record, [])
                order.append(key)
            }
            appGroups[key]?.members.append(record)
            groupOf[record.pid] = key
            if let bundle = record.bundlePath { appByBundle[bundle] = key }
        }

        // 2. Helpers inside the bundle or made responsible by the app.
        for record in records where groupOf[record.pid] == nil {
            if let bundle = record.bundlePath, let key = appByBundle[bundle] {
                groupOf[record.pid] = key
            } else if record.responsiblePid != record.pid, record.responsiblePid > 1,
                      let key = groupOf[record.responsiblePid], key.hasPrefix("app:") {
                groupOf[record.pid] = key
            }
        }

        // 3. Children of app processes (e.g. a shell launched by a terminal app).
        for record in records where groupOf[record.pid] == nil && record.kind != .system {
            var parent = record.ppid
            var depth = 0
            while parent > 1, depth < 6 {
                if let key = groupOf[parent], key.hasPrefix("app:") {
                    groupOf[record.pid] = key
                    break
                }
                guard let next = byPid[parent] else { break }
                parent = next.ppid
                depth += 1
            }
        }

        for record in records {
            guard let key = groupOf[record.pid], key.hasPrefix("app:"), record.isRegularApp == false else { continue }
            appGroups[key]?.members.append(record)
        }

        var nodes: [ProcessNode] = []
        nodes.reserveCapacity(records.count)
        for key in order {
            guard let group = appGroups[key] else { continue }
            let primary = group.primary
            nodes.append(ProcessNode(
                id: key,
                name: primary.name,
                kind: .app,
                iconPath: primary.bundlePath ?? primary.path,
                members: group.members,
                primary: primary
            ))
        }

        // 4. Everything else: group by bundle, then by identical name.
        var buckets: [String: [ProcessRecord]] = [:]
        var bucketOrder: [String] = []
        for record in records where groupOf[record.pid] == nil {
            let key: String
            if let bundle = record.bundlePath {
                key = "bundle:\(record.kind.rawValue):" + bundle
            } else {
                key = "name:\(record.kind.rawValue):" + record.name
            }
            if buckets[key] == nil { bucketOrder.append(key) }
            buckets[key, default: []].append(record)
        }
        for key in bucketOrder {
            guard let members = buckets[key], let first = members.min(by: { $0.pid < $1.pid }) else { continue }
            if members.count == 1 {
                nodes.append(ProcessNode(id: "pid:\(first.pid)", name: first.name, kind: first.kind,
                                         iconPath: first.bundlePath ?? first.path, members: members, primary: first))
            } else {
                let name = key.hasPrefix("bundle:") ? ProcessClassifier.bundleName(first.bundlePath ?? first.name) : first.name
                nodes.append(ProcessNode(id: key, name: name, kind: first.kind,
                                         iconPath: first.bundlePath ?? first.path, members: members, primary: first))
            }
        }
        return nodes
    }

    /// Groups processes by owning user, for the Users page.
    static func byUser(_ records: [ProcessRecord]) -> [ProcessNode] {
        var buckets: [UInt32: [ProcessRecord]] = [:]
        for record in records { buckets[record.uid, default: []].append(record) }
        return buckets.compactMap { uid, members in
            guard let first = members.min(by: { $0.pid < $1.pid }) else { return nil }
            return ProcessNode(id: "user:\(uid)", name: first.user, kind: .background,
                               iconPath: nil, members: members, primary: first)
        }
    }
}
