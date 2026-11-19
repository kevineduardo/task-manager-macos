import AppKit
import Combine
import Foundation

/// What the visible UI needs from the next sample. Skipping work nobody looks
/// at keeps Task Manager itself near the bottom of the CPU column.
struct SampleDemand: Equatable {
    var processes = true
    var perProcessNetwork = true
    var perProcessGPU = true
    var threadCount = false
}

/// Owns the samplers. Only touched on the sampling queue.
final class SamplingEngine {
    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let disk = DiskSampler()
    private let network = NetworkSampler()
    private let gpu = GPUSampler()
    private let processes = ProcessSampler()
    private var threadCount: Int?
    private var threadStamp = Date.distantPast

    func sample(demand: SampleDemand, apps: [Int32: RunningAppInfo], efficiency: Set<Int32>) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpu = cpu.sample()
        snapshot.memory = memory.sample()
        snapshot.disks = disk.sample()
        snapshot.networks = network.sample()
        let gpuResult = gpu.sample(includePerProcess: demand.processes && demand.perProcessGPU)
        snapshot.gpus = gpuResult.gpus

        if demand.processes {
            var options = ProcessSampler.Options()
            options.includeNetwork = demand.perProcessNetwork
            options.gpuPerProcess = gpuResult.perProcess
            snapshot.processes = processes.sample(options: options, apps: apps, efficiencyPids: efficiency)
            snapshot.nodes = ProcessGrouping.build(snapshot.processes)
            snapshot.processesSampled = true
        }

        if demand.threadCount, Date().timeIntervalSince(threadStamp) > 10 {
            threadStamp = Date()
            threadCount = Self.readThreadCount()
        }
        snapshot.threadCount = threadCount
        return snapshot
    }

    /// `top` reports the system-wide thread count, which libproc can't give us
    /// without root. Called at most every 10 s and only on the Performance page.
    static func readThreadCount() -> Int? {
        guard let output = Shell.run("/usr/bin/top", ["-l", "1", "-n", "0", "-s", "0"], timeout: 5) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("Processes:") {
            let parts = line.split(separator: ",")
            if let threads = parts.first(where: { $0.contains("threads") }) {
                let digits = threads.filter(\.isNumber)
                return Int(digits)
            }
        }
        return nil
    }
}

/// Main-thread facade the UI observes.
final class Monitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    /// Last snapshot that had process data (kept while processes are skipped).
    @Published private(set) var lastProcessSnapshot = SystemSnapshot()
    let history = History()
    let appHistory: AppHistoryStore
    @Published var efficiencyPids = Set<Int32>()

    var demand = SampleDemand()
    var isWindowVisible = true { didSet { if isWindowVisible != oldValue { reschedule() } } }

    private let engine = SamplingEngine()
    private let queue = DispatchQueue(label: "TaskManager.sampling", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var apps: [Int32: RunningAppInfo] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let preferences: Preferences

    init(preferences: Preferences = .shared, appHistory: AppHistoryStore = AppHistoryStore()) {
        self.preferences = preferences
        self.appHistory = appHistory
        refreshApps()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.publisher(for: name)
                .sink { [weak self] _ in self?.refreshApps() }
                .store(in: &cancellables)
        }
        preferences.$updateSpeed
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reschedule() } }
            .store(in: &cancellables)
    }

    func start() {
        tick()
        reschedule()
    }

    func refreshNow() {
        tick()
    }

    private func refreshApps() {
        apps = RunningAppInfo.snapshot()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard var interval = preferences.updateSpeed.interval else { return }
        if !isWindowVisible { interval = max(interval, 5) }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !inFlight else { return }
        inFlight = true
        var demand = self.demand
        if !isWindowVisible {
            demand.perProcessNetwork = false
            demand.perProcessGPU = false
            demand.threadCount = false
        }
        let apps = self.apps
        let efficiency = efficiencyPids
        queue.async { [engine] in
            let snapshot = engine.sample(demand: demand, apps: apps, efficiency: efficiency)
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        inFlight = false
        history.ingest(snapshot)
        if snapshot.processesSampled {
            appHistory.ingest(snapshot.nodes)
            lastProcessSnapshot = snapshot
            let alive = Set(snapshot.processes.map(\.pid))
            if !efficiencyPids.isSubset(of: alive) { efficiencyPids.formIntersection(alive) }
        }
        self.snapshot = snapshot
    }

    /// Processes to show: the newest sample with process data.
    var processes: [ProcessRecord] { lastProcessSnapshot.processes }
    var nodes: [ProcessNode] { lastProcessSnapshot.nodes }

    func process(pid: Int32) -> ProcessRecord? {
        lastProcessSnapshot.processes.first { $0.pid == pid }
    }
}
