import AppKit
import SwiftUI

// MARK: - Run new task

struct RunTaskSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @AppStorage("runTask.history") private var historyText = ""
    @State private var command = ""
    @State private var admin = false
    @State private var error: String?

    private var history: [String] { historyText.split(separator: "\n").map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 20)).foregroundStyle(Color.accentColor)
                Text("Create new task").font(.system(size: 16, weight: .semibold))
            }
            Text("Type the name of an app, a file, a folder, a URL or a shell command, and Task Manager will open it for you.")
                .font(.tmCaption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Open:").font(.tmBody)
                TextField("e.g. Safari, ~/Downloads, top -o cpu", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                if !history.isEmpty {
                    Menu {
                        ForEach(history, id: \.self) { item in Button(item) { command = item } }
                    } label: {
                        Image(systemName: "clock")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Recent tasks")
                }
                Button("Browse…", action: browse)
            }
            Toggle("Create this task with administrative privileges", isOn: $admin)
                .toggleStyle(.checkbox)
                .font(.tmBody)
            if let error {
                Text(error).font(.tmCaption).foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func run() {
        let text = command
        let elevated = admin
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessActions.runTask(text, asAdministrator: elevated)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    remember(text)
                    dismiss()
                    if preferences.minimizeOnUse { NSApp.mainWindow?.miniaturize(nil) }
                case .failure(let failure):
                    error = failure.message
                }
            }
        }
    }

    private func remember(_ text: String) {
        var items = history.filter { $0 != text }
        items.insert(text, at: 0)
        historyText = items.prefix(10).joined(separator: "\n")
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            command = url.path
        }
    }
}

// MARK: - Properties

struct PropertiesSheet: View {
    var record: ProcessRecord
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        let live = monitor.process(pid: record.pid) ?? record
        let bundle = live.bundlePath.flatMap { Bundle(path: $0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FileIcon(path: live.bundlePath ?? live.path, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.name).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                    Text(live.path ?? live.executableName).font(.tmSmall).foregroundStyle(Theme.secondaryText)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("PID", "\(live.pid)")
                row("Parent PID", "\(live.ppid)")
                row("User", live.user)
                row("Status", live.status == .running ? "Running" : live.status.label)
                row("Type", live.kind.sectionTitle)
                row("Architecture", live.architecture == .unknown ? "Unknown" : live.architecture.rawValue)
                row("Started", live.startTime.map { Format.dateTime.string(from: $0) } ?? "Unknown")
                row("CPU time", Format.cpuTime(live.cpuTime))
                row("Memory", Format.bytes(live.memory))
                row("Threads", live.threads > 0 ? "\(live.threads)" : "Not available")
                row("Priority", "\(live.priorityLabel) (nice \(live.nice))")
                if let id = live.bundleIdentifier ?? bundle?.bundleIdentifier { row("Bundle identifier", id) }
                if let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { row("Version", version) }
                if let path = live.path, let publisher = CodeSignature.publisher(of: live.bundlePath ?? path) { row("Publisher", publisher) }
                if let command = ProcessSampler.commandLine(of: live.pid) { row("Command line", command) }
            }
            if !live.hasDetails {
                Text("This process belongs to another user, so macOS only shares part of its details.")
                    .font(.tmSmall).foregroundStyle(Theme.tertiaryText)
            }
            HStack {
                Button("Open file location") { ProcessActions.revealInFinder(live.bundlePath ?? live.path) }
                    .disabled((live.bundlePath ?? live.path) == nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).font(.tmCaption).foregroundStyle(Theme.secondaryText)
            Text(value).font(.tmCaption).textSelection(.enabled).lineLimit(4)
        }
    }
}

// MARK: - Efficiency mode

struct EfficiencyConfirmSheet: View {
    var records: [ProcessRecord]
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var dontAsk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "leaf").font(.system(size: 20)).foregroundStyle(Theme.success)
                Text("Turn on Efficiency mode?").font(.system(size: 16, weight: .semibold))
            }
            Text("Efficiency mode runs \(records.first?.name ?? "this process") at background priority: macOS gives it less CPU time and throttles its disk and network access. It can make the app slower or less responsive.")
                .font(.tmBody)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Don't ask me again", isOn: $dontAsk).toggleStyle(.checkbox).font(.tmBody)
            HStack {
                Spacer()
                Button("Cancel") {
                    state.pendingEfficiency = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Turn on Efficiency mode") {
                    if dontAsk { preferences.confirmEfficiencyMode = false }
                    ProcessCommands(state: state, monitor: monitor, preferences: preferences).applyEfficiency(records, enabled: true)
                    state.pendingEfficiency = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
