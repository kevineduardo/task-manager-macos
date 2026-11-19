import SwiftUI

struct AppHistoryPage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var preferences: Preferences
    @StateObject private var widths = ColumnWidths(table: "appHistory")
    @State private var sort = SortDescriptor(column: "cpu", ascending: false)
    @State private var confirmReset = false

    private let columns: [TableColumnDef] = [
        TableColumnDef(id: "name", title: "Name", width: nil, minWidth: 220),
        TableColumnDef(id: "cpu", title: "CPU time", width: 110, trailing: true),
        TableColumnDef(id: "network", title: "Network", width: 110, trailing: true),
        TableColumnDef(id: "disk", title: "Disk", width: 110, trailing: true),
        TableColumnDef(id: "seen", title: "Last used", width: 160),
    ]

    var body: some View {
        AppHistoryContent(store: monitor.appHistory, columns: columns, widths: widths, sort: $sort, confirmReset: $confirmReset)
            .onAppear { KeyboardRouter.shared.handler = nil }
    }
}

/// Observes the history store directly so the page refreshes as usage accrues.
private struct AppHistoryContent: View {
    @ObservedObject var store: AppHistoryStore
    var columns: [TableColumnDef]
    @ObservedObject var widths: ColumnWidths
    @Binding var sort: SortDescriptor
    @Binding var confirmReset: Bool
    @EnvironmentObject var state: AppState
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        let entries = currentEntries()
        let maxCPU = entries.map(\.cpuTime).max() ?? 1
        VStack(spacing: 0) {
            CommandBar(title: "App history",
                       subtitle: "Resource usage since \(Format.dateTime.string(from: store.since)) for this user account") {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { state.runTaskShown = true }
                CommandButton(title: "Delete usage history", symbol: "trash") { confirmReset = true }
            }
            TableHeader(columns: columns, sort: $sort, widths: widths) {
                Toggle("Show history for all processes", isOn: $preferences.historyForAllProcesses)
            }
            if entries.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "Collecting usage",
                               detail: "Task Manager records CPU time, network and disk traffic per app while it runs. Usage appears here within a few seconds.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(spacing: 0) {
                                ForEach(columns) { column in
                                    Cell(column: column, widths: widths, heat: column.id == "cpu" ? entry.cpuTime / maxCPU * 0.6 : 0) {
                                        switch column.id {
                                        case "name":
                                            HStack(spacing: 6) {
                                                FileIcon(path: entry.iconPath)
                                                Text(entry.name).font(.tmBody)
                                            }
                                        case "cpu": Text(Format.cpuTime(entry.cpuTime)).font(.tmNumber)
                                        case "network": Text(Format.bytes(entry.networkBytes)).font(.tmNumber)
                                        case "disk": Text(Format.bytes(entry.diskBytes)).font(.tmNumber)
                                        default:
                                            Text(Format.shortDateTime.string(from: entry.lastSeen)).font(.tmBody).foregroundStyle(Theme.secondaryText)
                                        }
                                    }
                                }
                            }
                            .tableRow(selected: state.selection == entry.id)
                            .onTapGesture { state.selection = entry.id }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Delete usage history?", isPresented: $confirmReset) {
            Button("Delete usage history", role: .destructive) { store.reset() }
        } message: {
            Text("This clears the CPU time, network and disk totals collected so far.")
        }
    }

    private func currentEntries() -> [AppUsage] {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        var list = Array(store.entries.values)
        if !preferences.historyForAllProcesses { list = list.filter(\.isApp) }
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        return list.sorted { a, b in
            let ordered: Bool
            switch sort.column {
            case "name": ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case "network": ordered = a.networkBytes < b.networkBytes
            case "disk": ordered = a.diskBytes < b.diskBytes
            case "seen": ordered = a.lastSeen < b.lastSeen
            default: ordered = a.cpuTime < b.cpuTime
            }
            return sort.ascending ? ordered : !ordered
        }
    }
}
