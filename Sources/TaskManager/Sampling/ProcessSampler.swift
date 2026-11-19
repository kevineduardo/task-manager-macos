import AppKit
import Darwin
import Foundation

/// Enumerates processes with libproc and computes per-second rates between samples.
///
/// macOS only gives detailed task info (CPU time, footprint, disk I/O) for the
/// caller's own processes. For everything else we read CPU time and resident
/// memory from `/bin/ps`, which is setuid root, in one batched call per sample.
final class ProcessSampler {
    struct Options {
        var includeNetwork = true
        var gpuPerProcess: [Int32: Double] = [:]
    }

    private struct Static {
        var startTime: Date?
        var startKey: UInt64
        var path: String?
        var name: String
        var executableName: String
        var bundlePath: String?
        var architecture: Architecture
        var responsiblePid: Int32
    }

    private struct Counters {
        var cpuNs: Double
        var diskRead: UInt64
        var diskWrite: UInt64
        var energy: UInt64
    }

    private var statics: [Int32: Static] = [:]
    private var previous: [Int32: Counters] = [:]
    private var previousTime: UInt64 = 0
    private var users: [UInt32: String] = [:]
    private let netTop = NetTopReader()
    private let logicalCores = Double(max(1, MachineInfo.current.logicalCores))
    private let ownUid = getuid()

    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    func sample(options: Options, apps: [Int32: RunningAppInfo], efficiencyPids: Set<Int32>) -> [ProcessRecord] {
        let now = MachTime.now()
        let elapsedNs = previousTime > 0 ? Double(now - previousTime) : 0
        let pids = Self.allPids()
        let network = options.includeNetwork ? netTop.rates() : [:]

        var records: [ProcessRecord] = []
        records.reserveCapacity(pids.count)
        var current: [Int32: Counters] = [:]
        var needsPs: [Int32] = []
        var seen = Set<Int32>()

        for pid in pids {
            var short = proc_bsdshortinfo()
            let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize || pid == 0 else { continue }
            seen.insert(pid)

            var all = proc_taskallinfo()
            let allSize = Int32(MemoryLayout<proc_taskallinfo>.size)
            let hasAll = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, allSize) == allSize

            let startKey = hasAll ? UInt64(all.pbsd.pbi_start_tvsec) &* 1_000_000 &+ UInt64(all.pbsd.pbi_start_tvusec) : 0
            var info = statics[pid]
            if info == nil || (hasAll && info!.startKey != 0 && info!.startKey != startKey) {
                info = makeStatic(pid: pid, short: short, all: hasAll ? all : nil, startKey: startKey)
                statics[pid] = info
                previous[pid] = nil
            }
            guard let info else { continue }

            let uid = pid == 0 ? 0 : short.pbsi_uid
            let app = apps[pid]
            let bundlePath = app?.bundlePath ?? info.bundlePath
            let isRegular = app?.isRegular ?? false
            var record = ProcessRecord(
                pid: pid,
                ppid: Int32(bitPattern: short.pbsi_ppid),
                responsiblePid: info.responsiblePid,
                uid: uid,
                user: userName(uid),
                name: app?.name ?? info.name,
                executableName: info.executableName,
                path: info.path,
                bundlePath: bundlePath,
                bundleIdentifier: app?.bundleIdentifier,
                isRegularApp: isRegular,
                kind: ProcessClassifier.kind(pid: pid, uid: uid, path: info.path, isRegularApp: isRegular)
            )
            record.startTime = info.startTime
            record.architecture = app?.architecture ?? info.architecture
            record.nice = Int32(getpriority(PRIO_PROCESS, id_t(pid)))
            if short.pbsi_status == UInt32(SSTOP) {
                record.status = .suspended
            } else if short.pbsi_status == UInt32(SZOMB) {
                record.status = .zombie
            } else if efficiencyPids.contains(pid) {
                record.status = .efficiency
            }

            if hasAll {
                record.threads = Int(all.ptinfo.pti_threadnum)
                record.memory = all.ptinfo.pti_resident_size
            }

            var usage = rusage_info_v4()
            let hasUsage = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }

            if hasUsage {
                record.memory = usage.ri_phys_footprint
                let cpuNs = MachTime.nanoseconds(usage.ri_user_time &+ usage.ri_system_time)
                record.cpuTime = cpuNs / 1_000_000_000
                record.diskReadTotal = usage.ri_diskio_bytesread
                record.diskWriteTotal = usage.ri_diskio_byteswritten
                let counters = Counters(cpuNs: cpuNs, diskRead: usage.ri_diskio_bytesread,
                                        diskWrite: usage.ri_diskio_byteswritten, energy: usage.ri_billed_energy)
                current[pid] = counters
                if let before = previous[pid], elapsedNs > 0 {
                    let seconds = elapsedNs / 1_000_000_000
                    record.cpu = max(0, min(100, (counters.cpuNs - before.cpuNs) / elapsedNs / logicalCores * 100))
                    record.diskRead = Double(counters.diskRead &- before.diskRead) / seconds
                    record.diskWrite = Double(counters.diskWrite &- before.diskWrite) / seconds
                    if record.diskRead > 1e12 { record.diskRead = 0 }
                    if record.diskWrite > 1e12 { record.diskWrite = 0 }
                    if counters.energy > before.energy {
                        // ri_billed_energy is in nanojoules.
                        record.watts = Double(counters.energy - before.energy) / 1e9 / seconds
                    }
                }
            } else if hasAll {
                let cpuNs = MachTime.nanoseconds(all.ptinfo.pti_total_user &+ all.ptinfo.pti_total_system)
                record.cpuTime = cpuNs / 1_000_000_000
                current[pid] = Counters(cpuNs: cpuNs, diskRead: 0, diskWrite: 0, energy: 0)
                if let before = previous[pid], elapsedNs > 0 {
                    record.cpu = max(0, min(100, (cpuNs - before.cpuNs) / elapsedNs / logicalCores * 100))
                }
            } else {
                record.hasDetails = false
                needsPs.append(pid)
            }

            if options.includeNetwork {
                record.network = network[pid]?.rate ?? 0
                record.networkTotal = network[pid]?.total ?? 0
            }
            record.gpu = options.gpuPerProcess[pid]
            records.append(record)
        }

        if !needsPs.isEmpty {
            let ps = Self.psSample(pids: needsPs)
            for index in records.indices where !records[index].hasDetails {
                let pid = records[index].pid
                guard let entry = ps[pid] else { continue }
                records[index].memory = entry.rss
                records[index].cpuTime = entry.cpuSeconds
                let cpuNs = entry.cpuSeconds * 1_000_000_000
                current[pid] = Counters(cpuNs: cpuNs, diskRead: 0, diskWrite: 0, energy: 0)
                if let before = previous[pid], elapsedNs > 0 {
                    records[index].cpu = max(0, min(100, (cpuNs - before.cpuNs) / elapsedNs / logicalCores * 100))
                }
            }
        }

        // Forget processes that exited.
        if statics.count > seen.count + 64 {
            statics = statics.filter { seen.contains($0.key) }
        }
        previous = current
        previousTime = now
        return records
    }

    // MARK: - Static info

    private func makeStatic(pid: Int32, short: proc_bsdshortinfo, all: proc_taskallinfo?, startKey: UInt64) -> Static {
        let path = Self.path(of: pid)
        var kernelName = ""
        if var bsd = all?.pbsd {
            kernelName = Self.string(fromTuple: &bsd.pbi_name)
            if kernelName.isEmpty { kernelName = Self.string(fromTuple: &bsd.pbi_comm) }
        }
        if kernelName.isEmpty {
            var copy = short
            kernelName = Self.string(fromTuple: &copy.pbsi_comm)
        }
        if pid == 0 { kernelName = "kernel_task" }

        var startTime: Date?
        if let bsd = all?.pbsd {
            startTime = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        }

        let executable = path.map { ($0 as NSString).lastPathComponent } ?? kernelName
        return Static(
            startTime: startTime,
            startKey: startKey,
            path: path,
            name: ProcessClassifier.displayName(path: path, kernelName: kernelName),
            executableName: executable.isEmpty ? kernelName : executable,
            bundlePath: ProcessClassifier.outerBundle(of: path),
            architecture: Self.architecture(of: pid),
            responsiblePid: Self.responsibleFunction?(pid) ?? pid
        )
    }

    private func userName(_ uid: UInt32) -> String {
        if let cached = users[uid] { return cached }
        var name = "\(uid)"
        if let entry = getpwuid(uid), let raw = entry.pointee.pw_name {
            name = String(cString: raw)
        }
        users[uid] = name
        return name
    }

    static func allPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func architecture(of pid: Int32) -> Architecture {
        guard MachineInfo.current.isAppleSilicon else { return .intel }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return .unknown }
        let translated: Int32 = 0x0002_0000 // P_TRANSLATED
        return info.kp_proc.p_flag & translated != 0 ? .intel : .appleSilicon
    }

    static func string<T>(fromTuple tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Full command line via KERN_PROCARGS2. Only works for the caller's own processes.
    static func commandLine(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        var start = index
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        guard !args.isEmpty else { return nil }
        return args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    // MARK: - ps fallback

    struct PsEntry {
        var cpuSeconds: Double
        var rss: UInt64
    }

    static func psSample(pids: [Int32]) -> [Int32: PsEntry] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let output = Shell.run("/bin/ps", ["-o", "pid=,time=,rss=", "-p", list], timeout: 3) else { return [:] }
        return parsePs(output)
    }

    static func parsePs(_ output: String) -> [Int32: PsEntry] {
        var result: [Int32: PsEntry] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]), let rss = UInt64(fields[2]) else { continue }
            result[pid] = PsEntry(cpuSeconds: parseCPUTime(String(fields[1])), rss: rss * 1024)
        }
        return result
    }

    /// Parses ps TIME values like "0:01.23", "12:34.56", "1:02:03.45" or "2-01:02:03".
    static func parseCPUTime(_ text: String) -> Double {
        var days: Double = 0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var total: Double = 0
        for part in rest.split(separator: ":") {
            total = total * 60 + (Double(part) ?? 0)
        }
        return days * 86_400 + total
    }
}

/// What NSWorkspace knows about a running app, captured for the sampler.
struct RunningAppInfo {
    var name: String
    var bundlePath: String?
    var bundleIdentifier: String?
    var isRegular: Bool
    var architecture: Architecture?

    static func snapshot() -> [Int32: RunningAppInfo] {
        var result: [Int32: RunningAppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            var arch: Architecture?
            switch app.executableArchitecture {
            case NSBundleExecutableArchitectureARM64: arch = .appleSilicon
            case NSBundleExecutableArchitectureX86_64: arch = MachineInfo.current.isAppleSilicon ? .intel : .intel
            default: arch = nil
            }
            result[app.processIdentifier] = RunningAppInfo(
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                bundlePath: app.bundleURL?.path,
                bundleIdentifier: app.bundleIdentifier,
                isRegular: app.activationPolicy == .regular,
                architecture: arch
            )
        }
        return result
    }
}
