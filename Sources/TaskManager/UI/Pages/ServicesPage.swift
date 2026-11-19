import AppKit
import SwiftUI

final class ServicesModel: ObservableObject {
    @Published var items: [ServiceItem] = []
    @Published var loading = false

    func reload() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = ServicesProvider.load()
            DispatchQueue.main.async {
                self.items = items
                self.loading = false
            }
        }
    }
}

struct ServicesPage: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = ServicesModel()
    @StateObject private var widths = ColumnWidths(table: "services")
    @State private var sort = SortDescriptor(column: "name", ascending: true)
    @State private var domain: ServiceItem.Domain?

    private let columns: [TableColumnDef] = [
        TableColumnDef(id: "name", title: "Name", width: 320),
        TableColumnDef(id: "pid", title: "PID", width: 70, trailing: true),
        TableColumnDef(id: "description", title: "Description", width: nil, minWidth: 180),
        TableColumnDef(id: "status", title: "Status", width: 90),
        TableColumnDef(id: "domain", title: "Domain", width: 80),
        TableColumnDef(id: "group", title: "Group", width: 120),
    ]

    var body: some View {
        let items = currentItems()
        let selected = model.items.first { $0.id == state.selection }
        VStack(spacing: 0) {
            CommandBar(title: "Services", subtitle: "\(items.filter(\.isRunning).count) running · \(items.count) total") {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { state.runTaskShown = true }
                CommandButton(title: "Start", symbol: "play", isEnabled: selected.map { !$0.isRunning } ?? false) {
                    if let selected { run(.start, selected) }
                }
                CommandButton(title: "Stop", symbol: "stop", isEnabled: selected?.isRunning ?? false) {
                    if let selected { run(.stop, selected) }
                }
                CommandButton(title: "Restart", symbol: "arrow.clockwise", isEnabled: selected?.isRunning ?? false) {
                    if let selected { run(.restart, selected) }
                }
                CommandMenu(title: "View", symbol: "line.3.horizontal.decrease.circle") {
                    Picker("Show", selection: $domain) {
                        Text("All services").tag(ServiceItem.Domain?.none)
                        Text("User session").tag(ServiceItem.Domain?.some(.user))
                        Text("System").tag(ServiceItem.Domain?.some(.system))
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Refresh") { model.reload() }
                }
            }
            TableHeader(columns: columns, sort: $sort, widths: widths) {
                Button("Reset column widths") { widths.reset() }
            }
            if model.items.isEmpty, model.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in row(item) }
                    }
                }
            }
        }
        .onAppear {
            model.reload()
            KeyboardRouter.shared.handler = nil
        }
    }

    private func currentItems() -> [ServiceItem] {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        var list = model.items
        if let domain { list = list.filter { $0.domain == domain } }
        if !query.isEmpty {
            list = list.filter {
                $0.label.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)
                    || $0.pid.map(String.init) == query
            }
        }
        return list.sorted { a, b in
            let result: ComparisonResult
            switch sort.column {
            case "pid": result = (a.pid ?? 0) < (b.pid ?? 0) ? .orderedAscending : ((a.pid ?? 0) > (b.pid ?? 0) ? .orderedDescending : .orderedSame)
            case "description": result = a.description.localizedStandardCompare(b.description)
            case "status": result = a.statusLabel.compare(b.statusLabel)
            case "domain": result = a.domain.rawValue.compare(b.domain.rawValue)
            case "group": result = a.group.localizedStandardCompare(b.group)
            default: result = a.label.localizedStandardCompare(b.label)
            }
            if result == .orderedSame { return a.label < b.label }
            return (result == .orderedAscending) == sort.ascending
        }
    }

    private func row(_ item: ServiceItem) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths) {
                    switch column.id {
                    case "name":
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.2")
                                .font(.system(size: 11))
                                .foregroundStyle(item.isRunning ? Color.accentColor : Theme.tertiaryText)
                            Text(item.label).font(.tmBody).truncationMode(.middle)
                        }
                    case "pid": Text(item.pid.map(String.init) ?? "").font(.tmNumber)
                    case "description": Text(item.description).font(.tmBody).foregroundStyle(Theme.secondaryText)
                    case "status": Text(item.statusLabel).font(.tmBody).foregroundStyle(item.isRunning ? Theme.text : Theme.secondaryText)
                    case "domain": Text(item.domain.rawValue).font(.tmBody).foregroundStyle(Theme.secondaryText)
                    default: Text(item.group).font(.tmBody).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .tableRow(selected: state.selection == item.id)
        .onTapGesture { state.selection = item.id }
        .contextMenu {
            Button("Start") { run(.start, item) }.disabled(item.isRunning)
            Button("Stop") { run(.stop, item) }.disabled(!item.isRunning)
            Button("Restart") { run(.restart, item) }.disabled(!item.isRunning)
            Divider()
            if let pid = item.pid {
                Button("Go to details") {
                    state.page = .details
                    DispatchQueue.main.async { state.selection = "pid:\(pid)" }
                }
            }
            Button("Search online") { ProcessActions.searchOnline(item.label) }
            Button("Copy label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
        }
    }

    private func run(_ command: ServicesProvider.Command, _ item: ServiceItem) {
        state.perform({ ServicesProvider.perform(command, on: item) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.reload() }
        }
    }
}
