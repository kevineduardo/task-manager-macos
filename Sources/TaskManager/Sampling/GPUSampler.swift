import Foundation
import IOKit

struct GPUSample: Identifiable, Equatable {
    var id: Int  // index
    var model: String
    var utilization: Double?
    /// Named engine utilizations (e.g. Renderer, Tiler on Apple GPUs), 0...100.
    var engines: [Engine] = []
    var memoryInUse: UInt64?
    var memoryAllocated: UInt64?
    var dedicatedMemory: UInt64?
    var coreCount: Int?

    struct Engine: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var utilization: Double
    }

    var title: String { "GPU \(id)" }
}

/// GPU utilization from IOAccelerator `PerformanceStatistics` (no root needed),
/// plus per-process GPU time from the accelerator's user clients.
final class GPUSampler {
    private var previousGPUTime: [Int32: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private var modelCache: [Int: (String, Int?, UInt64?)] = [:]

    struct Result {
        var gpus: [GPUSample]
        /// Percent of GPU time per pid since the last sample (Apple GPUs).
        var perProcess: [Int32: Double]
    }

    func sample(includePerProcess: Bool) -> Result {
        let now = MachTime.now()
        let elapsed = previousTime > 0 ? Double(now - previousTime) : 0
        var gpus: [GPUSample] = []
        var gpuTime: [Int32: UInt64] = [:]
        var index = 0

        IOReg.forEachService(matching: "IOAccelerator") { accelerator in
            let stats = IOReg.property(accelerator, "PerformanceStatistics") as? [String: Any] ?? [:]
            let info = modelInfo(for: accelerator, index: index)
            var gpu = GPUSample(id: index, model: info.0)
            gpu.coreCount = info.1
            gpu.dedicatedMemory = info.2

            let device = number(stats["Device Utilization %"]) ?? number(stats["GPU Activity(%)"])
            gpu.utilization = device.map { min(100, max(0, $0)) }
            var engines: [GPUSample.Engine] = []
            if let renderer = number(stats["Renderer Utilization %"]) {
                engines.append(.init(name: "Renderer", utilization: min(100, renderer)))
            }
            if let tiler = number(stats["Tiler Utilization %"]) {
                engines.append(.init(name: "Tiler", utilization: min(100, tiler)))
            }
            gpu.engines = engines
            gpu.memoryInUse = IOReg.uint64(stats["In use system memory"]) ?? IOReg.uint64(stats["vramUsedBytes"])
            gpu.memoryAllocated = IOReg.uint64(stats["Alloc system memory"])

            if includePerProcess {
                IOReg.forEachChild(of: accelerator) { client in
                    guard let creator = IOReg.property(client, "IOUserClientCreator") as? String,
                          let pid = Self.pid(fromCreator: creator),
                          let usage = IOReg.property(client, "AppUsage") as? [[String: Any]] else { return }
                    let total = usage.reduce(UInt64(0)) { $0 + (IOReg.uint64($1["accumulatedGPUTime"]) ?? 0) }
                    gpuTime[pid, default: 0] += total
                }
            }
            gpus.append(gpu)
            index += 1
        }

        var perProcess: [Int32: Double] = [:]
        if includePerProcess, elapsed > 0 {
            for (pid, total) in gpuTime {
                guard let before = previousGPUTime[pid], total >= before else { continue }
                let percent = Double(total - before) / elapsed * 100
                if percent > 0.01 { perProcess[pid] = min(100, percent) }
            }
        }
        previousGPUTime = gpuTime
        previousTime = now
        return Result(gpus: gpus, perProcess: perProcess)
    }

    static func pid(fromCreator creator: String) -> Int32? {
        // Format: "pid 123, WindowServer"
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return Int32(digits)
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func modelInfo(for accelerator: io_object_t, index: Int) -> (String, Int?, UInt64?) {
        if let cached = modelCache[index] { return cached }
        var model = IOReg.string(from: IOReg.property(accelerator, "model"))
            ?? IOReg.string(from: IOReg.searchParents(accelerator, key: "model"))
            ?? "GPU"
        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if MachineInfo.current.isAppleSilicon, !model.hasPrefix("Apple") {
            model = "Apple \(model)"
        }
        let cores = (IOReg.property(accelerator, "gpu-core-count") as? NSNumber)?.intValue
        var vram: UInt64?
        if let megabytes = IOReg.uint64(IOReg.searchParents(accelerator, key: "VRAM,totalMB")) {
            vram = megabytes * 1024 * 1024
        }
        let info = (model, cores, vram)
        modelCache[index] = info
        return info
    }
}
