import Foundation

enum ProcessKind: Int, CaseIterable, Codable {
    case app
    case background
    case system

    var sectionTitle: String {
        switch self {
        case .app: return "Apps"
        case .background: return "Background processes"
        case .system: return "System processes"
        }
    }
}

enum ProcessStatus: Equatable {
    case running
    case suspended
    case zombie
    case efficiency

    var label: String {
        switch self {
        case .running: return ""
        case .suspended: return "Suspended"
        case .zombie: return "Not responding"
        case .efficiency: return "Efficiency mode"
        }
    }
}

enum PowerLevel: Int, Comparable, CaseIterable {
    case veryLow, low, moderate, high, veryHigh

    var label: String {
        switch self {
        case .veryLow: return "Very low"
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        case .veryHigh: return "Very high"
        }
    }

    /// Used for heat shading, 0...1.
    var heat: Double {
        switch self {
        case .veryLow: return 0
        case .low: return 0.15
        case .moderate: return 0.4
        case .high: return 0.7
        case .veryHigh: return 1
        }
    }

    static func < (lhs: PowerLevel, rhs: PowerLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Buckets an estimated draw in watts. Falls back to CPU share when the
    /// kernel reports no energy for the process.
    static func estimate(watts: Double?, cpuPercent: Double) -> PowerLevel {
        if let watts, watts > 0 {
            switch watts {
            case ..<0.1: return .veryLow
            case ..<0.5: return .low
            case ..<2: return .moderate
            case ..<5: return .high
            default: return .veryHigh
            }
        }
        switch cpuPercent {
        case ..<0.5: return .veryLow
        case ..<3: return .low
        case ..<10: return .moderate
        case ..<25: return .high
        default: return .veryHigh
        }
    }
}

enum Architecture: String {
    case appleSilicon = "Apple"
    case intel = "Intel"
    case unknown = ""
}

/// One process at one point in time. Rates are per second.
struct ProcessRecord: Identifiable, Equatable {
    var id: Int32 { pid }

    let pid: Int32
    var ppid: Int32
    var responsiblePid: Int32
    var uid: UInt32
    var user: String
    var name: String
    var executableName: String
    var path: String?
    /// Outermost `.app` bundle containing the executable, if any.
    var bundlePath: String?
    var bundleIdentifier: String?
    /// True for NSRunningApplication with a regular activation policy (Dock apps).
    var isRegularApp: Bool
    var kind: ProcessKind

    var cpu: Double = 0              // 0...100 of the whole machine
    var cpuTime: Double = 0          // seconds, user + system, since start
    var memory: UInt64 = 0           // physical footprint
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var diskReadTotal: UInt64 = 0
    var diskWriteTotal: UInt64 = 0
    var network: Double?             // bytes/s, nil when unknown
    var networkTotal: UInt64 = 0
    var gpu: Double?                 // 0...100
    var watts: Double?
    var threads: Int = 0
    var nice: Int32 = 0
    var status: ProcessStatus = .running
    var startTime: Date?
    var architecture: Architecture = .unknown
    /// False when the kernel refused detailed info (another user's process).
    var hasDetails: Bool = true

    var disk: Double { diskRead + diskWrite }
    var power: PowerLevel { PowerLevel.estimate(watts: watts, cpuPercent: cpu) }

    var priorityLabel: String { Priority.from(nice: nice).label }
}

enum Priority: Int32, CaseIterable, Identifiable {
    case realtime = -20
    case high = -10
    case aboveNormal = -5
    case normal = 0
    case belowNormal = 5
    case low = 19

    var id: Int32 { rawValue }

    var label: String {
        switch self {
        case .realtime: return "Realtime"
        case .high: return "High"
        case .aboveNormal: return "Above normal"
        case .normal: return "Normal"
        case .belowNormal: return "Below normal"
        case .low: return "Low"
        }
    }

    static func from(nice: Int32) -> Priority {
        switch nice {
        case ...(-15): return .realtime
        case ...(-6): return .high
        case ...(-1): return .aboveNormal
        case 0: return .normal
        case 1...9: return .belowNormal
        default: return .low
        }
    }
}
