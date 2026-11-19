import Darwin
import Foundation

enum MemoryPressure: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct MemorySample: Equatable {
    var total: UInt64 = MachineInfo.current.totalMemory
    /// App memory + wired + compressed. Matches Activity Monitor's "Memory Used".
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File-backed and purgeable pages the system can drop at any time.
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var available: UInt64 { total > used ? total - used : 0 }
    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

final class MemorySampler {
    private let host = mach_host_self()
    private lazy var pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        return UInt64(size == 0 ? 4096 : size)
    }()

    func sample() -> MemorySample {
        var sample = MemorySample()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return sample }

        let page = pageSize
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        sample.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        sample.wired = UInt64(stats.wire_count) * page
        sample.compressed = UInt64(stats.compressor_page_count) * page
        sample.cached = (UInt64(stats.external_page_count) + purgeable) * page
        sample.free = (UInt64(stats.free_count) + UInt64(stats.speculative_count)) * page
        sample.used = min(sample.total, sample.app + sample.wired + sample.compressed)

        let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self, default: xsw_usage())
        sample.swapUsed = swap.xsu_used
        sample.swapTotal = swap.xsu_total

        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level"),
           let pressure = MemoryPressure(rawValue: level) {
            sample.pressure = pressure
        }
        return sample
    }
}
