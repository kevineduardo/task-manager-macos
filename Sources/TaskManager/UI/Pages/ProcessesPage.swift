import SwiftUI

struct ProcessesPage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var preferences: Preferences
    @StateObject private var widths = ColumnWidths(table: "processes")
    @State private var sort = SortDescriptor(column: ProcessColumn.cpu.rawValue, ascending: false)
    @State private var expandAll = false

    private var commands: ProcessCommands { ProcessCommands(state: state, monitor: monitor, preferences: preferences) }

    var body: some View {
        let rows = currentRows()
        VStack(spacing: 0) {
            CommandBar(title: "Processes") {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { state.runTaskShown = true }
                CommandButton(title: "End task", symbol: "xmark.circle", isEnabled: selectedRecords(rows).isEmpty == false) {
                    endSelected(rows)
                }
                CommandButton(title: "Efficiency mode", symbol: "leaf", isEnabled: selectedRecords(rows).isEmpty == false) {
                    commands.toggleEfficiency(selectedRecords(rows))
                }
                CommandMenu(title: "View", symbol: "rectangle.3.group") { viewMenu }
            }
            TableHeader(columns: columns, sort: $sort, widths: widths, leadingInset: 0, tall: true) { columnMenu }
            if rows.isEmpty {
                if monitor.lastProcessSnapshot.processesSampled {
                    EmptyStateView(symbol: "magnifyingglass", title: "No results",
                                   detail: "Nothing matches \u{201C}\(state.search)\u{201D}.")
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                rowView(row).id(row.id)
                            }
                        }
                    }
                    .onChange(of: state.selection) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onAppear {
            loadSort()
            KeyboardRouter.shared.handler = { handleKey($0) }
        }
        .onChange(of: sort) { saveSort($0) }
    }

    // MARK: Columns

    private var columns: [TableColumnDef] {
        let snapshot = monitor.snapshot
        return preferences.processColumns.map { column in
            var def = TableColumnDef(
                id: column.rawValue,
                title: column.title,
                width: column == .name ? nil : CGFloat(column.defaultWidth),
                minWidth: column == .name ? 160 : 50,
                trailing: column.isNumeric
            )
            switch column {
            case .cpu:
                def.headerValue = Format.wholePercent(snapshot.cpu.total)
                def.headerHeat = snapshot.cpu.total / 100
            case .memory:
                def.headerValue = Format.wholePercent(snapshot.memory.percent)
                def.headerHeat = snapshot.memory.percent / 100
            case .disk:
                def.headerValue = Format.wholePercent(snapshot.diskActiveTime)
                def.headerHeat = snapshot.diskActiveTime / 100
            case .network:
                def.headerValue = Format.wholePercent(snapshot.networkUtilization)
                def.headerHeat = snapshot.networkUtilization / 100
            case .gpu:
                def.headerValue = snapshot.gpuUtilization.map(Format.wholePercent) ?? " "
                def.headerHeat = (snapshot.gpuUtilization ?? 0) / 100
            default:
                break
            }
            return def
        }
    }

    @ViewBuilder
    private var columnMenu: some View {
        ForEach(ProcessColumn.allCases.filter { $0 != .name }) { column in
            Toggle(column.title, isOn: Binding(
                get: { preferences.processColumns.contains(column) },
                set: { _ in preferences.toggle(column) }
            ))
        }
        Divider()
        Button("Reset columns") {
            preferences.resetColumns()
            widths.reset()
        }
    }

    @ViewBuilder
    private var viewMenu: some View {
        Toggle("Group by type", isOn: $preferences.groupByType)
        Divider()
        Button("Expand all") { expandAllGroups() }
        Button("Collapse all") {
            state.expandedNodes.removeAll()
            state.collapsedSections.removeAll()
        }
        Divider()
        Menu("Columns") { columnMenu }
        Divider()
        Button("Refresh now") { monitor.refreshNow() }
    }

    // MARK: Rows

    private func currentRows() -> [ProcessRow] {
        let column = ProcessColumn(rawValue: sort.column) ?? .cpu
        let filtered = ProcessTableBuilder.filter(monitor.nodes, query: state.search)
        let sorted = ProcessTableBuilder.sorted(filtered, column: column, ascending: sort.ascending)
        return ProcessTableBuilder.rows(
            nodes: sorted,
            groupByType: preferences.groupByType,
            expanded: state.expandedNodes,
            collapsedSections: state.collapsedSections,
            forceExpand: !state.search.isEmpty
        )
    }

    private func expandAllGroups() {
        state.collapsedSections.removeAll()
        state.expandedNodes = Set(monitor.nodes.filter(\.isGroup).map(\.id))
    }

    @ViewBuilder
    private func rowView(_ row: ProcessRow) -> some View {
        switch row {
        case .section(let kind, let count):
            sectionRow(kind: kind, count: count)
        case .node(let node, let expanded):
            nodeRow(node, expanded: expanded)
        case .member(let record, let parentID):
            memberRow(record, parentID: parentID)
        }
    }

    private func sectionRow(kind: ProcessKind, count: Int) -> some View {
        let collapsed = state.collapsedSections.contains(kind) && state.search.isEmpty
        return HStack(spacing: 6) {
            Disclosure(expanded: !collapsed) { toggleSection(kind) }
            Text(kind.sectionTitle)
                .font(.system(size: 12.5, weight: .semibold))
            Text("(\(count))")
                .font(.tmBody)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .padding(.leading, 6)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleSection(kind) }
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1).opacity(0.6) }
    }

    private func toggleSection(_ kind: ProcessKind) {
        if state.collapsedSections.contains(kind) {
            state.collapsedSections.remove(kind)
        } else {
            state.collapsedSections.insert(kind)
        }
    }

    private func nodeRow(_ node: ProcessNode, expanded: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths, heat: heat(for: column, node: node)) {
                    nodeCell(column: column, node: node, expanded: expanded)
                }
            }
        }
        .tableRow(selected: state.selection == node.id)
        .onTapGesture { state.selection = node.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if node.isGroup { toggle(node.id) } })
        .contextMenu {
            commands.menu(records: node.members, primary: node.primary, node: node)
        }
    }

    @ViewBuilder
    private func nodeCell(column: TableColumnDef, node: ProcessNode, expanded: Bool) -> some View {
        switch ProcessColumn(rawValue: column.id) ?? .name {
        case .name:
            HStack(spacing: 6) {
                if node.isGroup {
                    Disclosure(expanded: expanded) { toggle(node.id) }
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
                FileIcon(path: node.iconPath)
                Text(node.isGroup ? "\(node.name) (\(node.members.count))" : node.name)
                    .font(.tmBody)
                    .truncationMode(.middle)
            }
            .padding(.leading, preferences.groupByType ? 14 : 0)
        case .status: ProcessStatusLabel(status: node.status)
        case .pid: number(node.isGroup ? "" : String(node.primary.pid))
        case .processName: text(node.primary.executableName)
        case .user: text(node.primary.user)
        case .architecture: text(node.primary.architecture.rawValue)
        case .cpu: number(Format.percent(node.cpu))
        case .memory: number(Format.memoryMB(node.memory))
        case .disk: number(Format.diskRate(node.disk))
        case .network: number(node.network.map(Format.networkRate) ?? "—")
        case .gpu: number(node.gpu.map(Format.percent) ?? (MachineInfo.current.isAppleSilicon ? "0%" : "—"))
        case .power: text(node.power.label)
        case .threads: number(Format.grouped(node.threads))
        }
    }

    private func memberRow(_ record: ProcessRecord, parentID: String) -> some View {
        let id = "\(parentID)/\(record.pid)"
        return HStack(spacing: 0) {
            ForEach(columns) { column in
                Cell(column: column, widths: widths, heat: heat(for: column, record: record)) {
                    memberCell(column: column, record: record)
                }
            }
        }
        .tableRow(selected: state.selection == id)
        .onTapGesture { state.selection = id }
        .contextMenu { commands.menu(records: [record], primary: record) }
    }

    @ViewBuilder
    private func memberCell(column: TableColumnDef, record: ProcessRecord) -> some View {
        switch ProcessColumn(rawValue: column.id) ?? .name {
        case .name:
            HStack(spacing: 6) {
                FileIcon(path: ProcessClassifier.innerBundle(of: record.path) ?? record.bundlePath ?? record.path)
                Text(record.name).font(.tmBody).truncationMode(.middle)
            }
            .padding(.leading, (preferences.groupByType ? 14 : 0) + 44)
        case .status: ProcessStatusLabel(status: record.status)
        case .pid: number(String(record.pid))
        case .processName: text(record.executableName)
        case .user: text(record.user)
        case .architecture: text(record.architecture.rawValue)
        case .cpu: number(Format.percent(record.cpu))
        case .memory: number(Format.memoryMB(record.memory))
        case .disk: number(record.hasDetails ? Format.diskRate(record.disk) : "—")
        case .network: number(record.network.map(Format.networkRate) ?? "—")
        case .gpu: number(record.gpu.map(Format.percent) ?? (MachineInfo.current.isAppleSilicon ? "0%" : "—"))
        case .power: text(record.power.label)
        case .threads: number(record.threads > 0 ? Format.grouped(record.threads) : "—")
        }
    }

    private func number(_ value: String) -> some View {
        Text(value).font(.tmNumber).foregroundStyle(Theme.text)
    }

    private func text(_ value: String) -> some View {
        Text(value).font(.tmBody).foregroundStyle(Theme.secondaryText)
    }

    private func heat(for column: TableColumnDef, node: ProcessNode) -> Double {
        heat(column: column, cpu: node.cpu, memory: node.memory, disk: node.disk, network: node.network, gpu: node.gpu, power: node.power)
    }

    private func heat(for column: TableColumnDef, record: ProcessRecord) -> Double {
        heat(column: column, cpu: record.cpu, memory: record.memory, disk: record.disk, network: record.network, gpu: record.gpu, power: record.power)
    }

    /// Windows scales the tint against what's "a lot" for each resource.
    private func heat(column: TableColumnDef, cpu: Double, memory: UInt64, disk: Double,
                      network: Double?, gpu: Double?, power: PowerLevel) -> Double {
        switch ProcessColumn(rawValue: column.id) {
        case .cpu: return cpu / 50
        case .memory: return Double(memory) / Double(max(1, MachineInfo.current.totalMemory)) * 6
        case .disk: return disk / 40_000_000
        case .network: return (network ?? 0) * 8 / 20_000_000
        case .gpu: return (gpu ?? 0) / 50
        case .power: return power.heat
        default: return 0
        }
    }

    private func toggle(_ id: String) {
        if state.expandedNodes.contains(id) {
            state.expandedNodes.remove(id)
        } else {
            state.expandedNodes.insert(id)
        }
    }

    // MARK: Selection and keyboard

    private func selectedRecords(_ rows: [ProcessRow]) -> [ProcessRecord] {
        guard let id = state.selection else { return [] }
        for row in rows where row.id == id {
            switch row {
            case .node(let node, _): return node.members
            case .member(let record, _): return [record]
            case .section: return []
            }
        }
        return []
    }

    private func endSelected(_ rows: [ProcessRow]) {
        guard let id = state.selection else { return }
        for row in rows where row.id == id {
            switch row {
            case .node(let node, _): commands.endTask(node: node)
            case .member(let record, _): commands.endTask([record])
            case .section: break
            }
        }
    }

    private func handleKey(_ key: KeyAction) -> Bool {
        let rows = currentRows().filter { if case .section = $0 { return false } else { return true } }
        guard !rows.isEmpty else { return false }
        let index = state.selection.flatMap { id in rows.firstIndex { $0.id == id } }
        switch key {
        case .down:
            state.selection = rows[min(rows.count - 1, (index ?? -1) + 1)].id
        case .up:
            state.selection = rows[max(0, (index ?? 1) - 1)].id
        case .home:
            state.selection = rows.first?.id
        case .end:
            state.selection = rows.last?.id
        case .pageDown:
            state.selection = rows[min(rows.count - 1, (index ?? 0) + 15)].id
        case .pageUp:
            state.selection = rows[max(0, (index ?? 0) - 15)].id
        case .right, .left:
            guard let index, case .node(let node, let expanded) = rows[index], node.isGroup else { return false }
            if (key == .right) != expanded { toggle(node.id) }
        case .enter:
            guard let index else { return false }
            switch rows[index] {
            case .node(let node, _):
                if node.isGroup { toggle(node.id) } else { state.properties = node.primary }
            case .member(let record, _):
                state.properties = record
            case .section:
                break
            }
        case .delete:
            endSelected(currentRows())
        case .escape:
            state.selection = nil
        }
        return true
    }

    private func loadSort() {
        if let data = UserDefaults.standard.data(forKey: "processes.sort"),
           let stored = try? JSONDecoder().decode(SortDescriptor.self, from: data) {
            sort = stored
        }
    }

    private func saveSort(_ value: SortDescriptor) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "processes.sort")
        }
    }
}
