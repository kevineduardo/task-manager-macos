import AppKit
import SwiftUI

final class StartupModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loading = false

    func reload() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = StartupProvider.loadItems()
            DispatchQueue.main.async {
                self.items = items
                self.loading = false
            }
        }
    }
}

struct StartupPage: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = StartupModel()
    @StateObject private var widths = ColumnWidths(table: "startup")
    @State private var sort = SortDescriptor(column: "name", ascending: true)
    @State private var expanded = Set<String>()

    private let columns: [TableColumnDef] = [
        TableColumnDef(id: "name", title: "Name", width: nil, minWidth: 240),
        TableColumnDef(id: "publisher", title: "Publisher", width: 170),
        TableColumnDef(id: "type", title: "Type", width: 160),
        TableColumnDef(id: "status", title: "Status", width: 100),
        TableColumnDef(id: "impact", title: "Startup impact", width: 120),
    ]

    private enum Row: Identifiable {
        case group(key: String, name: String, items: [StartupItem])
        case item(StartupItem, nested: Bool)

        var id: String {
            switch self {
            case .group(let key, _, _): return "group:" + key
            case .item(let item, _): return item.id
            }
        }
    }

    var body: some View {
        let rows = currentRows()
        let selected = model.items.first { $0.id == state.selection }
        VStack(spacing: 0) {
            CommandBar(title: "Startup apps", subtitle: subtitle) {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { state.runTaskShown = true }
                CommandButton(title: "Enable", symbol: "checkmark.circle", isEnabled: selected.map { !$0.enabled } ?? false) {
                    if let selected { setEnabled(selected, true) }
                }
                CommandButton(title: "Disable", symbol: "nosign", isEnabled: selected?.enabled ?? false) {
                    if let selected { setEnabled(selected, false) }
                }
                CommandMenu(title: "More", symbol: "ellipsis") {
                    Button("Login Items settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Refresh") { model.reload() }
                }
            }
            TableHeader(columns: columns, sort: $sort, widths: widths) {
                Button("Reset column widths") { widths.reset() }
            }
            if model.items.isEmpty {
                if model.loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(symbol: "gauge.with.dots.needle.0percent", title: "No startup items",
                                   detail: "Launch agents and daemons installed by apps show up here.")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .group(let key, let name, let items): groupRow(key: key, name: name, items: items)
                            case .item(let item, let nested): itemRow(item, nested: nested)
                            }
                        }
                    }
                }
                Text("Items added through System Settings › General › Login Items are managed by macOS and aren't listed here.")
                    .font(.tmSmall)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
        }
        .onAppear {
            if model.items.isEmpty { model.reload() }
            KeyboardRouter.shared.handler = nil
        }
    }

    private var subtitle: String {
        let enabled = model.items.filter(\.enabled).count
        let boot = Format.dateTime.string(from: MachineInfo.current.bootTime)
        return "\(model.items.count) items · \(enabled) enabled · Last boot \(boot)"
    }

    private func currentRows() -> [Row] {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        var items = model.items
        if !query.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.label.localizedCaseInsensitiveContains(query)
                    || $0.publisherLabel.localizedCaseInsensitiveContains(query)
            }
        }
        items.sort { a, b in
            let result: ComparisonResult
            switch sort.column {
            case "publisher": result = a.publisherLabel.localizedStandardCompare(b.publisherLabel)
            case "type": result = a.kind.rawValue.compare(b.kind.rawValue)
            case "status": result = a.enabled == b.enabled ? .orderedSame : (a.enabled ? .orderedAscending : .orderedDescending)
            case "impact": result = a.impact.compare(b.impact)
            default: result = a.name.localizedStandardCompare(b.name)
            }
            if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return (result == .orderedAscending) == sort.ascending
        }

        var rows: [Row] = []
        var emitted = Set<String>()
        let groups = Dictionary(grouping: items.filter { $0.groupKey != nil }, by: { $0.groupKey! })
        for item in items {
            if let key = item.groupKey, let members = groups[key], members.count > 1 {
                guard !emitted.contains(key) else { continue }
                emitted.insert(key)
                rows.append(.group(key: key, name: members[0].vendor, items: members))
                if expanded.contains(key) || !query.isEmpty {
                    rows += members.map { .item($0, nested: true) }
                }
            } else {
                rows.append(.item(item, nested: false))
            }
        }
        return rows
    }

    private func groupRow(key: String, name: String, items: [StartupItem]) -> some View {
        let isOpen = expanded.contains(key) || !state.search.isEmpty
        let enabledCount = items.filter(\.enabled).count
        let kinds = Set(items.map(\.kind))
        return HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths) {
                    switch column.id {
                    case "name":
                        HStack(spacing: 8) {
                            Disclosure(expanded: isOpen) { toggle(key) }
                            FileIcon(path: items.first { $0.iconPath != nil }?.iconPath, size: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(name).font(.tmBody)
                                Text("\(items.count) items").font(.tmSmall).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    case "publisher": Text(items.compactMap(\.publisher).first ?? name).font(.tmBody).foregroundStyle(Theme.secondaryText)
                    case "type": Text(kinds.count == 1 ? kinds.first!.rawValue : "Multiple").font(.tmBody).foregroundStyle(Theme.secondaryText)
                    case "status": StatusPill(text: enabledCount == 0 ? "Disabled" : (enabledCount == items.count ? "Enabled" : "\(enabledCount) enabled"), positive: enabledCount > 0)
                    default: Text("Not measured").font(.tmBody).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .tableRow(selected: state.selection == "group:" + key, height: 44)
        .onTapGesture { state.selection = "group:" + key }
        .simultaneousGesture(TapGesture(count: 2).onEnded { toggle(key) })
    }

    private func itemRow(_ item: StartupItem, nested: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths) {
                    switch column.id {
                    case "name":
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { item.enabled }, set: { setEnabled(item, $0) }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .help(item.enabled ? "Disable" : "Enable")
                            if let icon = item.iconPath {
                                FileIcon(path: icon, size: 20)
                            } else {
                                Text(String(item.name.prefix(1)).uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 20, height: 20)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.hover))
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name).font(.tmBody)
                                Text(item.label).font(.tmSmall).foregroundStyle(Theme.secondaryText).truncationMode(.middle)
                            }
                        }
                        .padding(.leading, nested ? 40 : 22)
                    case "publisher": Text(item.publisherLabel).font(.tmBody).foregroundStyle(Theme.secondaryText)
                    case "type": Text(item.kind.rawValue).font(.tmBody).foregroundStyle(Theme.secondaryText)
                    case "status": StatusPill(text: item.enabled ? "Enabled" : "Disabled", positive: item.enabled)
                    default:
                        Text(item.impact).font(.tmBody).foregroundStyle(Theme.secondaryText)
                            .help("Estimated from the job's RunAtLoad and KeepAlive settings. macOS doesn't measure startup impact.")
                    }
                }
            }
        }
        .tableRow(selected: state.selection == item.id, height: 44)
        .onTapGesture { state.selection = item.id }
        .contextMenu {
            Button(item.enabled ? "Disable" : "Enable") { setEnabled(item, !item.enabled) }
            Divider()
            Button("Open file location") { ProcessActions.revealInFinder(item.plistPath) }
            if let program = item.program {
                Button("Show program in Finder") { ProcessActions.revealInFinder(program) }
            }
            Button("Search online") { ProcessActions.searchOnline(item.label) }
            Button("Copy label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
            Button("Open property list") { NSWorkspace.shared.open(URL(fileURLWithPath: item.plistPath)) }
        }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func setEnabled(_ item: StartupItem, _ enabled: Bool) {
        state.perform({ StartupProvider.setEnabled(item, enabled: enabled) },
                      success: "\(item.name) will \(enabled ? "start" : "no longer start") at login.") {
            model.reload()
        }
    }
}
