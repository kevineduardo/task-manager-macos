import SwiftUI

/// Flat list of every process, like the Windows Details tab.
struct DetailsPage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var preferences: Preferences
    @StateObject private var widths = ColumnWidths(table: "details")
    @State private var sort = SortDescriptor(column: "cpu", ascending: false)

    private var commands: ProcessCommands { ProcessCommands(state: state, monitor: monitor, preferences: preferences) }

    private let columns: [TableColumnDef] = [
        TableColumnDef(id: "name", title: "Name", width: nil, minWidth: 180),
        TableColumnDef(id: "pid", title: "PID", width: 70, trailing: true),
        TableColumnDef(id: "status", title: "Status", width: 110),
        TableColumnDef(id: "user", title: "User name", width: 120),
        TableColumnDef(id: "cpu", title: "CPU", width: 70, trailing: true),
        TableColumnDef(id: "memory", title: "Memory", width: 100, trailing: true),
        TableColumnDef(id: "threads", title: "Threads", width: 70, trailing: true),
        TableColumnDef(id: "arch", title: "Architecture", width: 95),
        TableColumnDef(id: "priority", title: "Priority", width: 100),
        TableColumnDef(id: "path", title: "Path", width: 320),
    ]

    var body: some View {
        let records = currentRecords()
        let selected = records.first { "pid:\($0.pid)" == state.selection }
        VStack(spacing: 0) {
            CommandBar(title: "Details", subtitle: "\(Format.grouped(records.count)) processes") {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { state.runTaskShown = true }
                CommandButton(title: "End task", symbol: "xmark.circle", isEnabled: selected != nil) {
                    if let selected { commands.endTask([selected]) }
                }
                CommandButton(title: "Properties", symbol: "info.circle", isEnabled: selected != nil) {
                    state.properties = selected
                }
            }
            TableHeader(columns: columns, sort: $sort, widths: widths) {
                Button("Reset column widths") { widths.reset() }
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            row(record).id("pid:\(record.pid)")
                        }
                    }
                }
                .onChange(of: state.selection) { id in if let id { proxy.scrollTo(id) } }
            }
        }
        .onAppear {
            KeyboardRouter.shared.handler = { key in
                handleKey(key, records: currentRecords())
            }
        }
    }

    private func currentRecords() -> [ProcessRecord] {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        var list = monitor.processes
        if !query.isEmpty {
            list = list.filter { ProcessTableBuilder.matches($0, query: query) || ($0.path?.localizedCaseInsensitiveContains(query) ?? false) }
        }
        let column: ProcessColumn
        switch sort.column {
        case "name": column = .name
        case "pid": column = .pid
        case "status": column = .status
        case "user": column = .user
        case "memory": column = .memory
        case "threads": column = .threads
        case "arch": column = .architecture
        case "priority", "path": column = .name
        default: column = .cpu
        }
        return list.sorted { a, b in
            let result: ComparisonResult
            switch sort.column {
            case "priority": result = a.nice < b.nice ? .orderedAscending : (a.nice > b.nice ? .orderedDescending : .orderedSame)
            case "path": result = (a.path ?? "").localizedStandardCompare(b.path ?? "")
            default: result = ProcessTableBuilder.compare(a, b, by: column)
            }
            if result == .orderedSame { return a.pid < b.pid }
            return (result == .orderedAscending) == sort.ascending
        }
    }

    private func row(_ record: ProcessRecord) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths) { cell(column.id, record) }
            }
        }
        .tableRow(selected: state.selection == "pid:\(record.pid)")
        .onTapGesture { state.selection = "pid:\(record.pid)" }
        .simultaneousGesture(TapGesture(count: 2).onEnded { state.properties = record })
        .contextMenu { commands.menu(records: [record], primary: record, includeDetails: false) }
    }

    @ViewBuilder
    private func cell(_ id: String, _ record: ProcessRecord) -> some View {
        switch id {
        case "name":
            HStack(spacing: 6) {
                FileIcon(path: ProcessClassifier.innerBundle(of: record.path) ?? record.path)
                Text(record.executableName).font(.tmBody)
            }
        case "pid": Text(String(record.pid)).font(.tmNumber)
        case "status":
            if record.status == .running {
                Text("Running").font(.tmBody).foregroundStyle(Theme.secondaryText)
            } else {
                ProcessStatusLabel(status: record.status)
            }
        case "user": Text(record.user).font(.tmBody).foregroundStyle(Theme.secondaryText)
        case "cpu": Text(String(format: "%02.0f", record.cpu.rounded())).font(.tmNumber)
        case "memory": Text(Format.memoryMB(record.memory)).font(.tmNumber)
        case "threads": Text(record.threads > 0 ? Format.grouped(record.threads) : "—").font(.tmNumber)
        case "arch": Text(record.architecture.rawValue).font(.tmBody).foregroundStyle(Theme.secondaryText)
        case "priority": Text(record.priorityLabel).font(.tmBody).foregroundStyle(Theme.secondaryText)
        default:
            Text(record.path ?? "—").font(.tmBody).foregroundStyle(Theme.secondaryText).truncationMode(.middle)
        }
    }

    private func handleKey(_ key: KeyAction, records: [ProcessRecord]) -> Bool {
        guard !records.isEmpty else { return false }
        let index = records.firstIndex { "pid:\($0.pid)" == state.selection }
        func select(_ i: Int) { state.selection = "pid:\(records[max(0, min(records.count - 1, i))].pid)" }
        switch key {
        case .down: select((index ?? -1) + 1)
        case .up: select((index ?? 1) - 1)
        case .pageDown: select((index ?? 0) + 15)
        case .pageUp: select((index ?? 0) - 15)
        case .home: select(0)
        case .end: select(records.count - 1)
        case .delete:
            if let index { commands.endTask([records[index]]) }
        case .enter:
            if let index { state.properties = records[index] }
        case .escape: state.selection = nil
        default: return false
        }
        return true
    }
}
