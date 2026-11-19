import Foundation

/// Number formatting that mirrors Windows 11 Task Manager.
enum Format {
    private static let decimal1: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private static let integer: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static func oneDecimal(_ value: Double) -> String {
        decimal1.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    static func grouped(_ value: Int) -> String {
        integer.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "0%", "0.4%", "12.3%"
    static func percent(_ value: Double) -> String {
        if value < 0.05 { return "0%" }
        return oneDecimal(min(value, 100)) + "%"
    }

    /// Whole-number percent for headers: "24%".
    static func wholePercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Processes memory column: always MB, e.g. "2,431.5 MB".
    static func memoryMB(_ bytes: UInt64) -> String {
        oneDecimal(Double(bytes) / 1_048_576) + " MB"
    }

    /// Disk column: "0 MB/s", "0.1 MB/s".
    static func diskRate(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_048_576
        if mb < 0.05 { return "0 MB/s" }
        return oneDecimal(mb) + " MB/s"
    }

    /// Network column: "0 Mbps", "0.1 Mbps".
    static func networkRate(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond * 8 / 1_000_000
        if mbps < 0.05 { return "0 Mbps" }
        return oneDecimal(mbps) + " Mbps"
    }

    /// Sizes: "512 KB", "130.3 MB", "29.9 GB".
    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = v
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        return oneDecimal(size) + " " + units[unit]
    }

    /// Throughput in bytes: "117.6 KB/s".
    static func byteRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "0 KB/s" }
        return bytes(UInt64(bytesPerSecond)) + "/s"
    }

    /// Throughput in bits: "120 Kbps", "1.4 Mbps".
    static func bitRate(_ bitsPerSecond: Double) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var size = bitsPerSecond
        var unit = 0
        while size >= 1000, unit < units.count - 1 {
            size /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(size)) bps" }
        return (size >= 100 ? "\(Int(size.rounded()))" : oneDecimal(size)) + " " + units[unit]
    }

    /// Link speed: "1 Gbps", "866.7 Mbps".
    static func linkSpeed(_ bitsPerSecond: UInt64) -> String {
        guard bitsPerSecond > 0 else { return "Unknown" }
        return bitRate(Double(bitsPerSecond))
    }

    /// Up time as d:hh:mm:ss, like Windows.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%d:%02d:%02d:%02d", days, hours, minutes, secs)
    }

    /// CPU time as h:mm:ss.
    static func cpuTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func megahertz(_ mhz: Int) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", Double(mhz) / 1000) : "\(mhz) MHz"
    }

    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
