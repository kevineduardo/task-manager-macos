import Darwin
import Foundation

struct CPUSample: Equatable {
    /// Overall utilization, 0...100.
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    /// Per logical processor utilization, 0...100.
    var perCore: [Double] = []
    var loadAverage: (Double, Double, Double) = (0, 0, 0)

    static func == (lhs: CPUSample, rhs: CPUSample) -> Bool {
        lhs.total == rhs.total && lhs.perCore == rhs.perCore
    }
}

/// Reads per-core tick counters with `host_processor_info` and turns two
/// consecutive readings into utilization percentages.
final class CPUSampler {
    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private let host = mach_host_self()
    private var previous: [Ticks] = []

    func sample() -> CPUSample {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return CPUSample() }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let stateCount = Int(CPU_STATE_MAX)
        var current: [Ticks] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stateCount
            current.append(Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }

        defer { previous = current }
        var sample = CPUSample()
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            sample.loadAverage = (loads[0], loads[1], loads[2])
        }
        guard previous.count == current.count else {
            sample.perCore = Array(repeating: 0, count: current.count)
            return sample
        }

        var sumUser: Double = 0
        var sumSystem: Double = 0
        var sumTotal: Double = 0
        sample.perCore.reserveCapacity(current.count)
        for (now, before) in zip(current, previous) {
            // Counters are 32-bit and wrap; wrapping subtraction handles that.
            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let total = user + system + idle
            sample.perCore.append(total > 0 ? min(100, (user + system) / total * 100) : 0)
            sumUser += user
            sumSystem += system
            sumTotal += total
        }
        if sumTotal > 0 {
            sample.user = sumUser / sumTotal * 100
            sample.system = sumSystem / sumTotal * 100
            sample.total = min(100, sample.user + sample.system)
        }
        return sample
    }
}
