import AppKit
import SwiftUI

enum PerformanceDevice: Hashable {
    case cpu
    case memory
    case disk(String)
    case network(String)
    case gpu(Int)
}

struct PerformancePage: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var preferences: Preferences
    @State private var device: PerformanceDevice = .cpu

    var body: some View {
        let snapshot = monitor.snapshot
        VStack(spacing: 0) {
            CommandBar(title: "Performance") {
                CommandButton(title: "Run new task", symbol: "plus.rectangle.on.rectangle") { state.runTaskShown = true }
                CommandButton(title: "Copy", symbol: "doc.on.doc") { copySummary(snapshot) }
                CommandButton(title: "Open Activity Monitor", symbol: "chart.xyaxis.line", showsTitle: false) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(devices(snapshot), id: \.self) { item in
                            DeviceTile(device: item, snapshot: snapshot, history: monitor.history, selected: item == device) {
                                device = item
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(width: 270)
                Theme.divider.frame(width: 1)
                ScrollView {
                    detail(snapshot)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { KeyboardRouter.shared.handler = { key in handleKey(key, snapshot: monitor.snapshot) } }
    }

    private func devices(_ snapshot: SystemSnapshot) -> [PerformanceDevice] {
        [.cpu, .memory]
            + snapshot.disks.map { .disk($0.id) }
            + snapshot.networks.map { .network($0.id) }
            + snapshot.gpus.map { .gpu($0.id) }
    }

    private func handleKey(_ key: KeyAction, snapshot: SystemSnapshot) -> Bool {
        let list = devices(snapshot)
        guard let index = list.firstIndex(of: device) else { device = .cpu; return true }
        switch key {
        case .down: device = list[min(list.count - 1, index + 1)]
        case .up: device = list[max(0, index - 1)]
        default: return false
        }
        return true
    }

    @ViewBuilder
    private func detail(_ snapshot: SystemSnapshot) -> some View {
        switch device {
        case .cpu:
            CPUDetail(snapshot: snapshot, history: monitor.history)
        case .memory:
            MemoryDetail(snapshot: snapshot, history: monitor.history)
        case .disk(let id):
            if let disk = snapshot.disks.first(where: { $0.id == id }) {
                DiskDetail(disk: disk, history: monitor.history)
            } else {
                EmptyStateView(symbol: "internaldrive", title: "This disk is no longer connected")
            }
        case .network(let id):
            if let net = snapshot.networks.first(where: { $0.id == id }) {
                NetworkDetail(net: net, history: monitor.history)
            } else {
                EmptyStateView(symbol: "network.slash", title: "This adapter is no longer connected")
            }
        case .gpu(let id):
            if let gpu = snapshot.gpus.first(where: { $0.id == id }) {
                GPUDetail(gpu: gpu, history: monitor.history)
            } else {
                EmptyStateView(symbol: "cpu", title: "GPU not available")
            }
        }
    }

    private func copySummary(_ snapshot: SystemSnapshot) {
        let machine = MachineInfo.current
        var lines = [
            "CPU: \(machine.cpuBrand) — \(Format.wholePercent(snapshot.cpu.total))",
            "Memory: \(Format.bytes(snapshot.memory.used)) / \(Format.bytes(snapshot.memory.total)) (\(Format.wholePercent(snapshot.memory.percent)))",
        ]
        for disk in snapshot.disks {
            lines.append("\(disk.title) (\(disk.model)): \(Format.wholePercent(disk.activeTime)) active, read \(Format.byteRate(disk.readRate)), write \(Format.byteRate(disk.writeRate))")
        }
        for net in snapshot.networks {
            lines.append("\(net.displayName) (\(net.id)): send \(Format.bitRate(net.sendRate * 8)), receive \(Format.bitRate(net.receiveRate * 8))")
        }
        for gpu in snapshot.gpus {
            lines.append("\(gpu.title) (\(gpu.model)): \(gpu.utilization.map(Format.wholePercent) ?? "n/a")")
        }
        lines.append("Up time: \(Format.uptime(snapshot.uptime))")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        state.show("Performance summary copied.", style: .success)
    }
}

// MARK: - Sidebar tiles

private struct DeviceTile: View {
    var device: PerformanceDevice
    var snapshot: SystemSnapshot
    var history: History
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let info = describe()
        Button(action: action) {
            HStack(spacing: 12) {
                Sparkline(values: history[info.key].values, color: info.color, maximum: info.maximum,
                          secondary: info.secondaryKey.map { history[$0].values })
                    .frame(width: 72, height: 46)
                    .background(Theme.content)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    if !info.subtitle.isEmpty {
                        Text(info.subtitle).font(.tmSmall).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Text(info.value).font(.tmSmall.monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 18)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private struct Info {
        var title: String
        var subtitle: String
        var value: String
        var key: String
        var secondaryKey: String?
        var color: Color
        var maximum: Double?
    }

    private func describe() -> Info {
        switch device {
        case .cpu:
            let speed = MachineInfo.current.cpuFrequencyMHz.map { " " + Format.megahertz($0) } ?? ""
            return Info(title: "CPU", subtitle: "", value: Format.wholePercent(snapshot.cpu.total) + speed,
                        key: "cpu", color: Theme.cpu, maximum: 100)
        case .memory:
            let m = snapshot.memory
            return Info(title: "Memory", subtitle: "",
                        value: "\(Format.bytes(m.used))/\(Format.bytes(m.total)) (\(Format.wholePercent(m.percent)))",
                        key: "memory", color: Theme.memory, maximum: 100)
        case .disk(let id):
            let disk = snapshot.disks.first { $0.id == id }
            return Info(title: disk?.title ?? "Disk", subtitle: disk.map { "\($0.kindLabel)" } ?? "",
                        value: Format.wholePercent(disk?.activeTime ?? 0),
                        key: "disk.\(id)", color: Theme.disk, maximum: 100)
        case .network(let id):
            let net = snapshot.networks.first { $0.id == id }
            let value = net.map { "S: \(Format.bitRate($0.sendRate * 8)) R: \(Format.bitRate($0.receiveRate * 8))" } ?? ""
            return Info(title: net?.displayName ?? "Network", subtitle: id, value: value,
                        key: "net.\(id).rx", secondaryKey: "net.\(id).tx", color: Theme.network, maximum: nil)
        case .gpu(let index):
            let gpu = snapshot.gpus.first { $0.id == index }
            return Info(title: gpu?.title ?? "GPU", subtitle: gpu?.model ?? "",
                        value: gpu?.utilization.map(Format.wholePercent) ?? "n/a",
                        key: "gpu.\(index)", color: Theme.gpu, maximum: 100)
        }
    }
}

// MARK: - Shared detail pieces

private struct DetailHeader: View {
    var title: String
    var trailing: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Spacer()
            Text(trailing).font(.system(size: 14)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .padding(.bottom, 12)
    }
}

private struct ChartCaption: View {
    var leading: String
    var trailing: String

    var body: some View {
        HStack {
            Text(leading)
            Spacer()
            Text(trailing)
        }
        .font(.tmSmall)
        .foregroundStyle(Theme.secondaryText)
    }
}

private struct BigStat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.tmCaption).foregroundStyle(Theme.secondaryText)
            Text(value).font(.system(size: 20).monospacedDigit()).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

private struct KeyValueTable: View {
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0 + ":").foregroundStyle(Theme.secondaryText)
                    Text(row.1).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                .font(.tmCaption)
            }
        }
    }
}

/// Big stats on the left, static facts on the right — the Windows layout.
private struct StatsArea: View {
    var stats: [(String, String)]
    var facts: [(String, String)]

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 14) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                    BigStat(label: stat.0, value: stat.1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            KeyValueTable(rows: facts)
                .frame(minWidth: 220, alignment: .leading)
        }
        .padding(.top, 18)
    }
}

// MARK: - CPU

private struct CPUDetail: View {
    var snapshot: SystemSnapshot
    var history: History
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        let machine = MachineInfo.current
        let cores = snapshot.cpu.perCore.count
        VStack(alignment: .leading, spacing: 6) {
            DetailHeader(title: "CPU", trailing: machine.cpuBrand)
            ChartCaption(leading: preferences.cpuGraphMode == .logical ? "% Utilization over logical processors" : "% Utilization over 60 seconds",
                         trailing: "100%")
            Group {
                if preferences.cpuGraphMode == .logical, cores > 1 {
                    let columnCount = gridColumns(for: cores)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columnCount), spacing: 6) {
                        ForEach(0..<cores, id: \.self) { core in
                            LineChart(lines: [ChartLine(values: history["cpu.\(core)"].values)],
                                      color: Theme.cpu, maximum: 100, gridColumns: 5, gridRows: 5, lineWidth: 1)
                                .frame(height: max(48, 300 / CGFloat((cores + columnCount - 1) / columnCount)))
                                .help(coreLabel(core))
                        }
                    }
                } else {
                    LineChart(lines: [ChartLine(values: history["cpu"].values),
                                      ChartLine(values: history["cpu.kernel"].values, dashed: true, filled: false)],
                              color: Theme.cpu, maximum: 100)
                        .frame(height: 300)
                }
            }
            .contextMenu {
                Picker("Change graph to", selection: $preferences.cpuGraphMode) {
                    Text("Overall utilization").tag(CPUGraphMode.overall)
                    Text("Logical processors").tag(CPUGraphMode.logical)
                }
            }
            ChartCaption(leading: "60 seconds", trailing: "0")

            StatsArea(
                stats: [
                    ("Utilization", Format.wholePercent(snapshot.cpu.total)),
                    ("User / System", "\(Format.wholePercent(snapshot.cpu.user)) / \(Format.wholePercent(snapshot.cpu.system))"),
                    ("Processes", Format.grouped(snapshot.processCount)),
                    ("Threads", snapshot.threadCount.map(Format.grouped) ?? "—"),
                    ("Load average", String(format: "%.2f · %.2f · %.2f", snapshot.cpu.loadAverage.0, snapshot.cpu.loadAverage.1, snapshot.cpu.loadAverage.2)),
                    ("Up time", Format.uptime(snapshot.uptime)),
                ],
                facts: facts(machine)
            )
            TopProcesses(title: "Top processes by CPU", nodes: Array(snapshot.nodes.sorted { $0.cpu > $1.cpu }.prefix(5))) {
                Format.percent($0.cpu)
            }
        }
    }

    private func facts(_ machine: MachineInfo) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let mhz = machine.cpuFrequencyMHz { rows.append(("Base speed", Format.megahertz(mhz))) }
        rows.append(("Sockets", "1"))
        rows.append(("Cores", "\(machine.physicalCores)"))
        if let p = machine.performanceCores, let e = machine.efficiencyCores {
            rows.append(("Performance cores", "\(p)"))
            rows.append(("Efficiency cores", "\(e)"))
        }
        rows.append(("Logical processors", "\(machine.logicalCores)"))
        rows.append(("Virtualization", Sysctl.int("kern.hv_support") == 1 ? "Enabled" : "Not available"))
        if let l1 = machine.l1Cache { rows.append(("L1 cache", Format.bytes(UInt64(l1)))) }
        if let l2 = machine.l2Cache { rows.append(("L2 cache", Format.bytes(UInt64(l2)))) }
        if let l3 = machine.l3Cache { rows.append(("L3 cache", Format.bytes(UInt64(l3)))) }
        rows.append(("Architecture", machine.isAppleSilicon ? "Apple silicon (arm64)" : "Intel (x86_64)"))
        return rows
    }

    private func gridColumns(for cores: Int) -> Int {
        switch cores {
        case ...4: return 2
        case ...8: return 4
        case ...16: return 4
        case ...24: return 6
        default: return 8
        }
    }

    private func coreLabel(_ index: Int) -> String {
        let machine = MachineInfo.current
        if let p = machine.performanceCores, machine.efficiencyCores != nil {
            // Apple lists performance cores first in perflevel0.
            return index < p ? "Performance core \(index)" : "Efficiency core \(index)"
        }
        return "Logical processor \(index)"
    }
}

private struct TopProcesses: View {
    var title: String
    var nodes: [ProcessNode]
    var value: (ProcessNode) -> String

    var body: some View {
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.bottom, 6)
                ForEach(nodes) { node in
                    HStack(spacing: 8) {
                        FileIcon(path: node.iconPath)
                        Text(node.name).font(.tmBody).lineLimit(1)
                        Spacer()
                        Text(value(node)).font(.tmNumber).foregroundStyle(Theme.secondaryText)
                    }
                    .frame(height: 26)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.top, 22)
        }
    }
}

// MARK: - Memory

private struct MemoryDetail: View {
    var snapshot: SystemSnapshot
    var history: History

    var body: some View {
        let m = snapshot.memory
        let total = Double(m.total)
        VStack(alignment: .leading, spacing: 6) {
            DetailHeader(title: "Memory", trailing: Format.bytes(m.total))
            ChartCaption(leading: "Memory usage", trailing: Format.bytes(m.total))
            LineChart(lines: [ChartLine(values: history["memory"].values)], color: Theme.memory, maximum: 100)
                .frame(height: 230)
            ChartCaption(leading: "60 seconds", trailing: "0")
            Text("Memory composition").font(.tmSmall).foregroundStyle(Theme.secondaryText).padding(.top, 10)
            CompositionBar(segments: [
                .init(label: "App memory", value: Double(m.app), opacity: 0.55),
                .init(label: "Wired", value: Double(m.wired), opacity: 0.4),
                .init(label: "Compressed", value: Double(m.compressed), opacity: 0.28),
                .init(label: "Cached files", value: Double(m.cached), opacity: 0.12),
            ], total: total, color: Theme.memory)
            .frame(height: 44)

            StatsArea(
                stats: [
                    ("In use (Compressed)", "\(Format.bytes(m.used)) (\(Format.bytes(m.compressed)))"),
                    ("Available", Format.bytes(m.available)),
                    ("Cached files", Format.bytes(m.cached)),
                    ("Swap used", "\(Format.bytes(m.swapUsed)) / \(Format.bytes(m.swapTotal))"),
                    ("Memory pressure", m.pressure.label),
                ],
                facts: [
                    ("App memory", Format.bytes(m.app)),
                    ("Wired memory", Format.bytes(m.wired)),
                    ("Compressed", Format.bytes(m.compressed)),
                    ("Free", Format.bytes(m.free)),
                    ("Total", Format.bytes(m.total)),
                ]
            )
            TopProcesses(title: "Top processes by memory", nodes: Array(snapshot.nodes.sorted { $0.memory > $1.memory }.prefix(5))) {
                Format.bytes($0.memory)
            }
        }
    }
}

// MARK: - Disk

private struct DiskDetail: View {
    var disk: DiskSample
    var history: History

    var body: some View {
        let read = history["disk.\(disk.id).read"].values
        let write = history["disk.\(disk.id).write"].values
        let peak = ChartScale.niceCeiling(max(read.max() ?? 0, write.max() ?? 0, 1024 * 1024))
        VStack(alignment: .leading, spacing: 6) {
            DetailHeader(title: disk.isSystemDisk ? "\(disk.title) (Macintosh HD)" : disk.title, trailing: disk.model)
            ChartCaption(leading: "Active time", trailing: "100%")
            LineChart(lines: [ChartLine(values: history["disk.\(disk.id)"].values)], color: Theme.disk, maximum: 100)
                .frame(height: 190)
            ChartCaption(leading: "60 seconds", trailing: "0")
            ChartCaption(leading: "Disk transfer rate", trailing: Format.byteRate(peak)).padding(.top, 10)
            LineChart(lines: [ChartLine(values: read), ChartLine(values: write, dashed: true, filled: false)],
                      color: Theme.disk, maximum: peak)
                .frame(height: 110)
            ChartCaption(leading: "60 seconds", trailing: "0")

            StatsArea(
                stats: [
                    ("Active time", Format.wholePercent(disk.activeTime)),
                    ("Read speed", Format.byteRate(disk.readRate)),
                    ("Write speed", Format.byteRate(disk.writeRate)),
                ],
                facts: facts
            )
        }
    }

    private var facts: [(String, String)] {
        var rows: [(String, String)] = [
            ("Capacity", Format.bytes(disk.capacity)),
            ("System disk", disk.isSystemDisk ? "Yes" : "No"),
            ("Type", disk.kindLabel),
            ("Location", disk.isInternal ? "Internal" : "External"),
            ("Device", "/dev/\(disk.id)"),
        ]
        if disk.isSystemDisk, disk.volumeTotal > 0 {
            rows.insert(("Formatted", Format.bytes(disk.volumeTotal)), at: 1)
            rows.insert(("Available", Format.bytes(disk.volumeAvailable)), at: 2)
        }
        return rows
    }
}

// MARK: - Network

private struct NetworkDetail: View {
    var net: NetworkSample
    var history: History

    var body: some View {
        let rx = history["net.\(net.id).rx"].values
        let tx = history["net.\(net.id).tx"].values
        let peak = ChartScale.niceCeiling(max(rx.max() ?? 0, tx.max() ?? 0, 100_000))
        VStack(alignment: .leading, spacing: 6) {
            DetailHeader(title: net.displayName, trailing: net.id)
            ChartCaption(leading: "Throughput", trailing: Format.bitRate(peak))
            LineChart(lines: [ChartLine(values: rx), ChartLine(values: tx, dashed: true, filled: false)],
                      color: Theme.network, maximum: peak)
                .frame(height: 300)
            ChartCaption(leading: "60 seconds", trailing: "0")
            HStack(spacing: 16) {
                legend("Receive", dashed: false)
                legend("Send", dashed: true)
            }
            .padding(.top, 4)

            StatsArea(
                stats: [
                    ("Send", Format.bitRate(net.sendRate * 8)),
                    ("Receive", Format.bitRate(net.receiveRate * 8)),
                    ("Total sent", Format.bytes(net.totalSent)),
                    ("Total received", Format.bytes(net.totalReceived)),
                ],
                facts: [
                    ("Adapter name", net.id),
                    ("Connection type", net.kind.rawValue),
                    ("Link speed", Format.linkSpeed(net.linkSpeed)),
                    ("IPv4 address", net.ipv4.first ?? "—"),
                    ("IPv6 address", net.ipv6.first ?? "—"),
                ]
            )
        }
    }

    private func legend(_ text: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 18, y: 4))
            }
            .stroke(Theme.network, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
            .frame(width: 18, height: 8)
            Text(text).font(.tmSmall).foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - GPU

private struct GPUDetail: View {
    var gpu: GPUSample
    var history: History

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailHeader(title: gpu.title, trailing: gpu.model)
            ChartCaption(leading: "Utilization", trailing: "100%")
            LineChart(lines: [ChartLine(values: history["gpu.\(gpu.id)"].values)], color: Theme.gpu, maximum: 100)
                .frame(height: gpu.engines.isEmpty ? 300 : 200)
            ChartCaption(leading: "60 seconds", trailing: "0")
            if !gpu.engines.isEmpty {
                HStack(spacing: 12) {
                    ForEach(gpu.engines) { engine in
                        VStack(alignment: .leading, spacing: 4) {
                            ChartCaption(leading: engine.name, trailing: Format.wholePercent(engine.utilization))
                            LineChart(lines: [ChartLine(values: history["gpu.\(gpu.id).\(engine.name)"].values)],
                                      color: Theme.gpu, maximum: 100, gridColumns: 6, gridRows: 4)
                                .frame(height: 90)
                        }
                    }
                }
                .padding(.top, 10)
            }

            StatsArea(
                stats: [
                    ("Utilization", gpu.utilization.map(Format.wholePercent) ?? "n/a"),
                    ("GPU memory in use", gpu.memoryInUse.map(Format.bytes) ?? "—"),
                ] + (gpu.memoryAllocated.map { [("GPU memory allocated", Format.bytes($0))] } ?? []),
                facts: facts
            )
        }
    }

    private var facts: [(String, String)] {
        var rows: [(String, String)] = [("Model", gpu.model)]
        if let cores = gpu.coreCount { rows.append(("GPU cores", "\(cores)")) }
        if let vram = gpu.dedicatedMemory {
            rows.append(("Dedicated memory", Format.bytes(vram)))
        } else if MachineInfo.current.isAppleSilicon {
            rows.append(("Memory", "Unified (shared with CPU)"))
        }
        return rows
    }
}
