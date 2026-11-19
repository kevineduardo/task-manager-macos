import Foundation
import IOKit

struct DiskSample: Identifiable, Equatable {
    /// BSD name, e.g. "disk0".
    var id: String
    var index: Int
    var model: String
    var readRate: Double = 0
    var writeRate: Double = 0
    /// Share of wall time the device had requests in flight, 0...100.
    var activeTime: Double = 0
    var capacity: UInt64 = 0
    var isSolidState: Bool = true
    var isInternal: Bool = true
    var interconnect: String = ""
    var isSystemDisk: Bool = false
    var volumeTotal: UInt64 = 0
    var volumeAvailable: UInt64 = 0

    var title: String { "Disk \(index)" }
    var kindLabel: String {
        let medium = isSolidState ? "SSD" : "HDD"
        return interconnect.isEmpty ? medium : "\(medium) (\(interconnect))"
    }
}

/// Throughput and active time for physical disks, from IOBlockStorageDriver
/// statistics. Virtual devices (disk images) are skipped.
final class DiskSampler {
    private struct Counters {
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var timeNs: UInt64
    }

    private var previous: [String: Counters] = [:]
    private var previousTime: UInt64 = 0

    func sample() -> [DiskSample] {
        let now = MachTime.now()
        let elapsed = previousTime > 0 ? Double(now - previousTime) : 0
        var disks: [DiskSample] = []
        var current: [String: Counters] = [:]

        IOReg.forEachService(matching: "IOBlockStorageDriver") { driver in
            guard let stats = IOReg.property(driver, "Statistics") as? [String: Any] else { return }

            var bsdName: String?
            var capacity: UInt64 = 0
            IOReg.forEachChild(of: driver) { media in
                if bsdName == nil, let name = IOReg.property(media, "BSD Name") as? String {
                    bsdName = name
                    capacity = IOReg.uint64(IOReg.property(media, "Size")) ?? 0
                }
            }
            guard let name = bsdName else { return }

            var model = "Disk"
            var solid = true
            var interconnect = ""
            var location = "Internal"
            if let device = IOReg.parent(of: driver) {
                defer { IOObjectRelease(device) }
                if let traits = IOReg.property(device, "Device Characteristics") as? [String: Any] {
                    if let product = traits["Product Name"] as? String {
                        model = product.trimmingCharacters(in: .whitespaces)
                    }
                    if let medium = traits["Medium Type"] as? String {
                        solid = medium.localizedCaseInsensitiveContains("solid")
                    }
                }
                if let proto = IOReg.property(device, "Protocol Characteristics") as? [String: Any] {
                    interconnect = proto["Physical Interconnect"] as? String ?? ""
                    location = proto["Physical Interconnect Location"] as? String ?? location
                }
            }
            if interconnect.localizedCaseInsensitiveContains("virtual") || location == "File" { return }

            let counters = Counters(
                bytesRead: IOReg.uint64(stats["Bytes (Read)"]) ?? 0,
                bytesWritten: IOReg.uint64(stats["Bytes (Write)"]) ?? 0,
                timeNs: (IOReg.uint64(stats["Total Time (Read)"]) ?? 0) + (IOReg.uint64(stats["Total Time (Write)"]) ?? 0)
            )
            current[name] = counters

            var disk = DiskSample(id: name, index: Self.index(of: name), model: model)
            disk.capacity = capacity
            disk.isSolidState = solid
            disk.interconnect = interconnect == "PCI-Express" ? "NVMe" : interconnect
            disk.isInternal = location.localizedCaseInsensitiveContains("internal")
            if let before = previous[name], elapsed > 0 {
                let seconds = elapsed / 1_000_000_000
                disk.readRate = Double(counters.bytesRead &- before.bytesRead) / seconds
                disk.writeRate = Double(counters.bytesWritten &- before.bytesWritten) / seconds
                disk.activeTime = min(100, Double(counters.timeNs &- before.timeNs) / elapsed * 100)
                if disk.readRate < 0 || disk.readRate > 1e12 { disk.readRate = 0 }
                if disk.writeRate < 0 || disk.writeRate > 1e12 { disk.writeRate = 0 }
            }
            disks.append(disk)
        }

        disks.sort { $0.index < $1.index }
        if let systemIndex = disks.firstIndex(where: { $0.isInternal }) ?? disks.indices.first {
            disks[systemIndex].isSystemDisk = true
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
            disks[systemIndex].volumeTotal = UInt64(values?.volumeTotalCapacity ?? 0)
            disks[systemIndex].volumeAvailable = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        }

        previous = current
        previousTime = now
        return disks
    }

    private static func index(of bsdName: String) -> Int {
        Int(bsdName.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0
    }
}
