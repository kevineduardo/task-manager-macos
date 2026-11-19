import AppKit
import SwiftUI

struct UsersPage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var preferences: Preferences
    @StateObject private var widths = ColumnWidths(table: "users")
    @State private var sort = SortDescriptor(column: "cpu", ascending: false)

    private var commands: ProcessCommands { ProcessCommands(state: state, monitor: monitor, preferences: preferences) }

    private var columns: [TableColumnDef] {
        let s = monitor.snapshot
        return [
            TableColumnDef(id: "name", title: "User", width: nil, minWidth: 200),
            TableColumnDef(id: "status", title: "Status", width: 110),
            TableColumnDef(id: "processes", title: "Processes", width: 90, trailing: true),
            TableColumnDef(id: "cpu", title: "CPU", width: 80, trailing: true,
                           headerValue: Format.wholePercent(s.cpu.total), headerHeat: s.cpu.total / 100),
            TableColumnDef(id: "memory", title: "Memory", width: 110, trailing: true,
                           headerValue: Format.wholePercent(s.memory.percent), headerHeat: s.memory.percent / 100),
            TableColumnDef(id: "disk", title: "Disk", width: 90, trailing: true,
                           headerValue: Format.wholePercent(s.diskActiveTime)),
        ]
    }

    var body: some View {
        let users = currentUsers()
        VStack(spacing: 0) {
            CommandBar(title: "Users") {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { state.runTaskShown = true }
                CommandButton(title: "Users & Groups settings", symbol: "person.crop.circle.badge.gearshape") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            TableHeader(columns: columns, sort: $sort, widths: widths, tall: true) {
                Button("Reset column widths") { widths.reset() }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(users) { user in
                        userRow(user)
                        if state.expandedNodes.contains(user.id) || !state.search.isEmpty {
                            ForEach(user.members) { record in processRow(record, parent: user.id) }
                        }
                    }
                }
            }
        }
        .onAppear { KeyboardRouter.shared.handler = nil }
    }

    private func currentUsers() -> [ProcessNode] {
        var nodes = ProcessGrouping.byUser(monitor.processes)
        let query = state.search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { nodes = ProcessTableBuilder.filter(nodes, query: query) }
        let current = getuid()
        let column: ProcessColumn = ["name": .name, "memory": .memory, "disk": .disk, "processes": .threads][sort.column] ?? .cpu
        return nodes.map { node in
            var copy = node
            copy.members.sort { $0.cpu > $1.cpu }
            return copy
        }
        .sorted { a, b in
            // The signed-in user always comes first, like Windows.
            if a.primary.uid == current, b.primary.uid != current { return true }
            if b.primary.uid == current, a.primary.uid != current { return false }
            let result: ComparisonResult = sort.column == "processes"
                ? (a.members.count < b.members.count ? .orderedAscending : (a.members.count > b.members.count ? .orderedDescending : .orderedSame))
                : ProcessTableBuilder.compare(a, b, by: column)
            if result == .orderedSame { return a.name < b.name }
            return (result == .orderedAscending) == sort.ascending
        }
    }

    private func displayName(_ node: ProcessNode) -> String {
        guard preferences.showFullAccountName, let entry = getpwuid(node.primary.uid), let gecos = entry.pointee.pw_gecos else {
            return node.name
        }
        let full = String(cString: gecos).split(separator: ",").first.map(String.init) ?? ""
        return full.isEmpty ? node.name : "\(full) (\(node.name))"
    }

    private func userRow(_ node: ProcessNode) -> some View {
        let expanded = state.expandedNodes.contains(node.id) || !state.search.isEmpty
        let isCurrent = node.primary.uid == getuid()
        return HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths, heat: heat(column.id, cpu: node.cpu, memory: node.memory)) {
                    switch column.id {
                    case "name":
                        HStack(spacing: 6) {
                            Disclosure(expanded: expanded) { toggle(node.id) }
                            Image(systemName: isCurrent ? "person.crop.circle.fill" : "person.crop.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(isCurrent ? Color.accentColor : Theme.secondaryText)
                            Text("\(displayName(node)) (\(node.members.count))").font(.tmBody)
                        }
                    case "status":
                        Text(isCurrent ? "Active" : (node.primary.uid == 0 ? "System" : "Service")).font(.tmBody).foregroundStyle(Theme.secondaryText)
                    case "processes": Text(Format.grouped(node.members.count)).font(.tmNumber)
                    case "cpu": Text(Format.percent(node.cpu)).font(.tmNumber)
                    case "memory": Text(Format.memoryMB(node.memory)).font(.tmNumber)
                    default: Text(Format.diskRate(node.disk)).font(.tmNumber)
                    }
                }
            }
        }
        .tableRow(selected: state.selection == node.id)
        .onTapGesture { state.selection = node.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { toggle(node.id) })
    }

    private func processRow(_ record: ProcessRecord, parent: String) -> some View {
        let id = "\(parent)/\(record.pid)"
        return HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths, heat: heat(column.id, cpu: record.cpu, memory: record.memory)) {
                    switch column.id {
                    case "name":
                        HStack(spacing: 6) {
                            FileIcon(path: record.bundlePath ?? record.path)
                            Text(record.name).font(.tmBody)
                        }
                        .padding(.leading, 44)
                    case "status": ProcessStatusLabel(status: record.status)
                    case "processes": Text(String(record.pid)).font(.tmNumber).foregroundStyle(Theme.tertiaryText)
                    case "cpu": Text(Format.percent(record.cpu)).font(.tmNumber)
                    case "memory": Text(Format.memoryMB(record.memory)).font(.tmNumber)
                    default: Text(record.hasDetails ? Format.diskRate(record.disk) : "—").font(.tmNumber)
                    }
                }
            }
        }
        .tableRow(selected: state.selection == id)
        .onTapGesture { state.selection = id }
        .contextMenu { commands.menu(records: [record], primary: record) }
    }

    private func heat(_ column: String, cpu: Double, memory: UInt64) -> Double {
        switch column {
        case "cpu": return cpu / 50
        case "memory": return Double(memory) / Double(max(1, MachineInfo.current.totalMemory)) * 3
        default: return 0
        }
    }

    private func toggle(_ id: String) {
        if state.expandedNodes.contains(id) { state.expandedNodes.remove(id) } else { state.expandedNodes.insert(id) }
    }
}
