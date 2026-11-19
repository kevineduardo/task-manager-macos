import Foundation

/// Everything sampled in one tick. Produced off the main thread, consumed by the UI.
struct SystemSnapshot {
    var timestamp = Date()
    var cpu = CPUSample()
    var memory = MemorySample()
    var disks: [DiskSample] = []
    var networks: [NetworkSample] = []
    var gpus: [GPUSample] = []
    var processes: [ProcessRecord] = []
    var nodes: [ProcessNode] = []
    var processesSampled = false
    var threadCount: Int?

    var processCount: Int { processes.count }
    var uptime: TimeInterval { Date().timeIntervalSince(MachineInfo.current.bootTime) }

    var diskTotalRate: Double { disks.reduce(0) { $0 + $1.readRate + $1.writeRate } }
    var diskActiveTime: Double { disks.map(\.activeTime).max() ?? 0 }
    var networkTotalRate: Double {
        networks.filter { $0.kind != .vpn }.reduce(0) { $0 + $1.receiveRate + $1.sendRate }
    }
    var networkUtilization: Double {
        let physical = networks.filter { $0.kind != .vpn }
        let link = physical.reduce(UInt64(0)) { $0 + $1.linkSpeed }
        guard link > 0 else { return 0 }
        return min(100, networkTotalRate * 8 / Double(link) * 100)
    }
    var gpuUtilization: Double? { gpus.compactMap(\.utilization).max() }
}

/// Fixed-size rolling series for charts (oldest first).
struct Series: Equatable {
    private(set) var values: [Double]
    let capacity: Int

    init(capacity: Int = 60) {
        self.capacity = capacity
        values = Array(repeating: 0, count: capacity)
    }

    mutating func append(_ value: Double) {
        values.append(value.isFinite ? value : 0)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var last: Double { values.last ?? 0 }
    var maximum: Double { values.max() ?? 0 }
}

/// Chart history for every device, keyed by a stable id ("cpu", "cpu.3", "disk.disk0.read"…).
final class History {
    private(set) var series: [String: Series] = [:]
    let capacity = 60

    func record(_ key: String, _ value: Double) {
        if series[key] == nil { series[key] = Series(capacity: capacity) }
        series[key]?.append(value)
    }

    subscript(key: String) -> Series {
        series[key] ?? Series(capacity: capacity)
    }

    func ingest(_ snapshot: SystemSnapshot) {
        record("cpu", snapshot.cpu.total)
        record("cpu.kernel", snapshot.cpu.system)
        for (index, value) in snapshot.cpu.perCore.enumerated() {
            record("cpu.\(index)", value)
        }
        record("memory", snapshot.memory.percent)
        record("memory.used", Double(snapshot.memory.used))
        for disk in snapshot.disks {
            record("disk.\(disk.id)", disk.activeTime)
            record("disk.\(disk.id).read", disk.readRate)
            record("disk.\(disk.id).write", disk.writeRate)
        }
        for net in snapshot.networks {
            record("net.\(net.id).rx", net.receiveRate * 8)
            record("net.\(net.id).tx", net.sendRate * 8)
        }
        for gpu in snapshot.gpus {
            record("gpu.\(gpu.id)", gpu.utilization ?? 0)
            for engine in gpu.engines {
                record("gpu.\(gpu.id).\(engine.name)", engine.utilization)
            }
        }
    }
}
