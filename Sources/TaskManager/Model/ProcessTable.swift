import Foundation

/// Columns available on the Processes page. Right-click the header to toggle them.
enum ProcessColumn: String, CaseIterable, Identifiable, Codable {
    case name, status, pid, processName, user, architecture, cpu, memory, disk, network, gpu, power, threads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .status: return "Status"
        case .pid: return "PID"
        case .processName: return "Process name"
        case .user: return "User name"
        case .architecture: return "Architecture"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .power: return "Power usage"
        case .threads: return "Threads"
        }
    }

    var isNumeric: Bool {
        switch self {
        case .pid, .cpu, .memory, .disk, .network, .gpu, .threads: return true
        default: return false
        }
    }

    /// Right-aligned, heat-shaded resource columns.
    var isResource: Bool {
        switch self {
        case .cpu, .memory, .disk, .network, .gpu, .power: return true
        default: return false
        }
    }

    var defaultWidth: Double {
        switch self {
        case .name: return 280
        case .status: return 110
        case .pid: return 70
        case .processName: return 170
        case .user: return 110
        case .architecture: return 95
        case .cpu: return 78
        case .memory: return 100
        case .disk: return 86
        case .network: return 90
        case .gpu: return 72
        case .power: return 110
        case .threads: return 72
        }
    }

    static let defaultVisible: [ProcessColumn] = [.name, .status, .cpu, .memory, .disk, .network, .gpu, .power]
}

struct SortDescriptor: Equatable, Codable {
    var column: String
    var ascending: Bool
}

enum ProcessRow: Identifiable, Equatable {
    case section(ProcessKind, count: Int)
    case node(ProcessNode, expanded: Bool)
    case member(ProcessRecord, parentID: String)

    var id: String {
        switch self {
        case .section(let kind, _): return "section:\(kind.rawValue)"
        case .node(let node, _): return node.id
        case .member(let record, let parent): return "\(parent)/\(record.pid)"
        }
    }
}

enum ProcessTableBuilder {
    static func matches(_ record: ProcessRecord, query: String) -> Bool {
        if record.name.localizedCaseInsensitiveContains(query) { return true }
        if record.executableName.localizedCaseInsensitiveContains(query) { return true }
        if String(record.pid) == query { return true }
        if let id = record.bundleIdentifier, id.localizedCaseInsensitiveContains(query) { return true }
        if record.user.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    /// Applies the search filter. A group stays visible when any member matches,
    /// and then only shows the matching members.
    static func filter(_ nodes: [ProcessNode], query: String) -> [ProcessNode] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.name.localizedCaseInsensitiveContains(q) { return node }
            let members = node.members.filter { matches($0, query: q) }
            guard !members.isEmpty else { return nil }
            var copy = node
            copy.members = members
            copy.aggregate()
            return copy
        }
    }

    static func compare(_ a: ProcessRecord, _ b: ProcessRecord, by column: ProcessColumn) -> ComparisonResult {
        switch column {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .status: return a.status.label.compare(b.status.label)
        case .pid: return number(a.pid, b.pid)
        case .processName: return a.executableName.localizedStandardCompare(b.executableName)
        case .user: return a.user.localizedStandardCompare(b.user)
        case .architecture: return a.architecture.rawValue.compare(b.architecture.rawValue)
        case .cpu: return number(a.cpu, b.cpu)
        case .memory: return number(a.memory, b.memory)
        case .disk: return number(a.disk, b.disk)
        case .network: return number(a.network ?? -1, b.network ?? -1)
        case .gpu: return number(a.gpu ?? -1, b.gpu ?? -1)
        case .power: return number(a.watts ?? a.cpu / 100, b.watts ?? b.cpu / 100)
        case .threads: return number(a.threads, b.threads)
        }
    }

    static func compare(_ a: ProcessNode, _ b: ProcessNode, by column: ProcessColumn) -> ComparisonResult {
        switch column {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .status: return a.status.label.compare(b.status.label)
        case .pid: return number(a.primary.pid, b.primary.pid)
        case .processName: return a.primary.executableName.localizedStandardCompare(b.primary.executableName)
        case .user: return a.primary.user.localizedStandardCompare(b.primary.user)
        case .architecture: return a.primary.architecture.rawValue.compare(b.primary.architecture.rawValue)
        case .cpu: return number(a.cpu, b.cpu)
        case .memory: return number(a.memory, b.memory)
        case .disk: return number(a.disk, b.disk)
        case .network: return number(a.network ?? -1, b.network ?? -1)
        case .gpu: return number(a.gpu ?? -1, b.gpu ?? -1)
        case .power: return number(a.watts ?? a.cpu / 100, b.watts ?? b.cpu / 100)
        case .threads: return number(a.threads, b.threads)
        }
    }

    private static func number<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    static func sorted(_ nodes: [ProcessNode], column: ProcessColumn, ascending: Bool) -> [ProcessNode] {
        func ordered(_ result: ComparisonResult, _ tieA: String, _ tieB: String) -> Bool {
            switch result {
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            case .orderedSame: return tieA.localizedStandardCompare(tieB) == .orderedAscending
            }
        }
        return nodes.map { node -> ProcessNode in
            guard node.isGroup else { return node }
            var copy = node
            copy.members.sort { ordered(compare($0, $1, by: column), $0.name + "\($0.pid)", $1.name + "\($1.pid)") }
            return copy
        }
        .sorted { ordered(compare($0, $1, by: column), $0.name + $0.id, $1.name + $1.id) }
    }

    /// Flattens nodes into display rows, with optional "Apps / Background / System" sections.
    static func rows(nodes: [ProcessNode], groupByType: Bool, expanded: Set<String>,
                     collapsedSections: Set<ProcessKind>, forceExpand: Bool) -> [ProcessRow] {
        var rows: [ProcessRow] = []
        rows.reserveCapacity(nodes.count + 8)
        func append(_ node: ProcessNode) {
            let isOpen = node.isGroup && (forceExpand || expanded.contains(node.id))
            rows.append(.node(node, expanded: isOpen))
            if isOpen {
                for member in node.members { rows.append(.member(member, parentID: node.id)) }
            }
        }
        if groupByType {
            for kind in ProcessKind.allCases {
                let section = nodes.filter { $0.kind == kind }
                guard !section.isEmpty else { continue }
                rows.append(.section(kind, count: section.count))
                if collapsedSections.contains(kind) && !forceExpand { continue }
                section.forEach(append)
            }
        } else {
            nodes.forEach(append)
        }
        return rows
    }
}
