import AppKit
import SwiftUI

/// Process actions shared by Processes, Users and Details.
struct ProcessCommands {
    let state: AppState
    let monitor: Monitor
    let preferences: Preferences

    func endTask(_ records: [ProcessRecord], force: Bool = false) {
        guard !records.isEmpty else { return }
        state.perform({ ProcessActions.endTask(records, force: force) }) { monitor.refreshNow() }
    }

    /// Ends an app the way Windows does: the app's main process is asked to quit,
    /// grouped background processes are ended one by one.
    func endTask(node: ProcessNode) {
        endTask(node.kind == .app && node.primary.isRegularApp ? [node.primary] : node.members)
    }

    func endTree(_ record: ProcessRecord) {
        let tree = ProcessActions.processTree(of: record.pid, in: monitor.processes)
        endTask(tree)
    }

    func isEfficient(_ records: [ProcessRecord]) -> Bool {
        !records.isEmpty && records.allSatisfy { monitor.efficiencyPids.contains($0.pid) }
    }

    func toggleEfficiency(_ records: [ProcessRecord]) {
        guard !records.isEmpty else { return }
        if isEfficient(records) {
            applyEfficiency(records, enabled: false)
        } else if preferences.confirmEfficiencyMode {
            state.pendingEfficiency = records
        } else {
            applyEfficiency(records, enabled: true)
        }
    }

    func applyEfficiency(_ records: [ProcessRecord], enabled: Bool) {
        let pids = Set(records.map(\.pid))
        state.perform({ ProcessActions.setEfficiencyMode(records, enabled: enabled) }) {
            if enabled {
                monitor.efficiencyPids.formUnion(pids)
            } else {
                monitor.efficiencyPids.subtract(pids)
            }
        }
    }

    func suspend(_ records: [ProcessRecord], resume: Bool) {
        state.perform({ ProcessActions.suspend(records, resume: resume) }) { monitor.refreshNow() }
    }

    func setPriority(_ record: ProcessRecord, _ priority: Priority) {
        state.perform({ ProcessActions.setPriority(record, priority) }) { monitor.refreshNow() }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func goToDetails(_ record: ProcessRecord) {
        state.page = .details
        DispatchQueue.main.async { state.selection = "pid:\(record.pid)" }
    }

    /// The right-click menu for a process or a group of processes.
    @ViewBuilder
    func menu(records: [ProcessRecord], primary: ProcessRecord, node: ProcessNode? = nil, includeDetails: Bool = true) -> some View {
        let suspended = records.allSatisfy { $0.status == .suspended }
        Button("End task") {
            if let node { endTask(node: node) } else { endTask(records) }
        }
        Button("End process tree") { endTree(primary) }
        Button("Force quit") { endTask(records, force: true) }
        Divider()
        Button(isEfficient(records) ? "Turn off efficiency mode" : "Efficiency mode") { toggleEfficiency(records) }
        Button(suspended ? "Resume" : "Suspend") { suspend(records, resume: suspended) }
        if records.count == 1 {
            Menu("Set priority") {
                ForEach(Priority.allCases) { priority in
                    Button {
                        setPriority(primary, priority)
                    } label: {
                        if Priority.from(nice: primary.nice) == priority {
                            Label(priority.label, systemImage: "checkmark")
                        } else {
                            Text(priority.label)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Open file location") {
            ProcessActions.revealInFinder(primary.bundlePath ?? primary.path)
            if preferences.minimizeOnUse { NSApp.mainWindow?.miniaturize(nil) }
        }
            .disabled((primary.bundlePath ?? primary.path) == nil)
        Button("Search online") { ProcessActions.searchOnline(node?.name ?? primary.name) }
        Menu("Copy") {
            Button("Name") { copy(node?.name ?? primary.name) }
            Button("PID") { copy(String(primary.pid)) }
            if let path = primary.path { Button("Path") { copy(path) } }
            if let id = primary.bundleIdentifier { Button("Bundle identifier") { copy(id) } }
        }
        if includeDetails {
            Button("Go to details") { goToDetails(primary) }
        }
        Button("Properties") { state.properties = primary }
    }
}

/// Status cell content: efficiency leaf or suspended icon, like Windows.
struct ProcessStatusLabel: View {
    var status: ProcessStatus

    var body: some View {
        switch status {
        case .running:
            EmptyView()
        case .efficiency:
            Label("Efficiency mode", systemImage: "leaf")
                .labelStyle(StatusLabelStyle(tint: Theme.success))
        case .suspended:
            Label("Suspended", systemImage: "pause.circle")
                .labelStyle(StatusLabelStyle(tint: Theme.secondaryText))
        case .zombie:
            Label("Not responding", systemImage: "exclamationmark.circle")
                .labelStyle(StatusLabelStyle(tint: Theme.caution))
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint).font(.system(size: 11))
            configuration.title.font(.tmCaption).foregroundStyle(Theme.secondaryText)
        }
    }
}
