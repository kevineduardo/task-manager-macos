import Darwin
import Foundation

/// Small, allocation-light wrappers around `sysctlbyname` and friends.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            // Some keys are 32-bit.
            var small: Int32 = 0
            var smallSize = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &small, &smallSize, nil, 0) == 0 else { return nil }
            return Int(small)
        }
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    static func value<T>(_ name: String, as type: T.Type, default fallback: T) -> T {
        var value = fallback
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return fallback }
        return value
    }
}

/// Converts Mach absolute time units to nanoseconds. On Intel the ratio is 1:1,
/// on Apple Silicon one tick is 125/3 ns, and rusage/task CPU times use ticks.
enum MachTime {
    static let ratio: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    @inline(__always)
    static func nanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * ratio
    }

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// Static facts about the machine. Computed once.
struct MachineInfo {
    let cpuBrand: String
    let physicalCores: Int
    let logicalCores: Int
    let performanceCores: Int?
    let efficiencyCores: Int?
    let cpuFrequencyMHz: Int?
    let totalMemory: UInt64
    let modelIdentifier: String
    let isAppleSilicon: Bool
    let l1Cache: Int?
    let l2Cache: Int?
    let l3Cache: Int?
    let bootTime: Date
    let osVersion: String

    static let current = MachineInfo()

    private init() {
        let brand = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
        cpuBrand = brand.trimmingCharacters(in: .whitespaces)
        physicalCores = Sysctl.int("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        logicalCores = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        modelIdentifier = Sysctl.string("hw.model") ?? "Mac"
        totalMemory = UInt64(Sysctl.int("hw.memsize") ?? Int(ProcessInfo.processInfo.physicalMemory))

        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        isAppleSilicon = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1

        if let levels = Sysctl.int("hw.nperflevels"), levels > 1 {
            performanceCores = Sysctl.int("hw.perflevel0.logicalcpu")
            efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu")
        } else {
            performanceCores = nil
            efficiencyCores = nil
        }

        if let hz = Sysctl.int("hw.cpufrequency"), hz > 0 {
            cpuFrequencyMHz = hz / 1_000_000
        } else {
            cpuFrequencyMHz = nil
        }

        if isAppleSilicon {
            l1Cache = Sysctl.int("hw.perflevel0.l1dcachesize")
            l2Cache = Sysctl.int("hw.perflevel0.l2cachesize")
            l3Cache = nil
        } else {
            l1Cache = Sysctl.int("hw.l1dcachesize")
            l2Cache = Sysctl.int("hw.l2cachesize")
            l3Cache = Sysctl.int("hw.l3cachesize")
        }

        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &boot, &bootSize, nil, 0) == 0 {
            bootTime = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        } else {
            bootTime = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    var coreSummary: String {
        if let p = performanceCores, let e = efficiencyCores {
            return "\(p)P + \(e)E"
        }
        return "\(physicalCores)"
    }
}
