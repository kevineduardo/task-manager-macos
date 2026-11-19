import Foundation

enum Shell {
    struct Result {
        var status: Int32
        var output: String
        var error: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs a tool synchronously and returns stdout, or nil on failure/timeout.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let result = execute(executable, arguments, timeout: timeout)
        return result.succeeded ? result.output : nil
    }

    @discardableResult
    static func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            out.fileHandleForWriting.closeFile()
            err.fileHandleForWriting.closeFile()
            group.wait()
            return Result(status: -1, output: "", error: error.localizedDescription)
        }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            group.wait()
        }
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Escapes a value for use inside single quotes in /bin/sh.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell command with administrator rights through the standard
    /// macOS authorization prompt.
    static func runAsAdministrator(_ command: String) -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return execute("/usr/bin/osascript", ["-e", script], timeout: 300)
    }
}

/// Per-process network throughput from `nettop`, which needs no privileges.
/// Each call takes one cumulative reading and diffs it with the previous one.
final class NetTopReader {
    struct Entry {
        var rate: Double
        var total: UInt64
    }

    private var previous: [Int32: UInt64] = [:]
    private var previousTime: UInt64 = 0

    func rates() -> [Int32: Entry] {
        guard let output = Shell.run("/usr/bin/nettop", ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"], timeout: 3) else {
            return [:]
        }
        let now = MachTime.now()
        let totals = Self.parse(output)
        let elapsed = previousTime > 0 ? Double(now - previousTime) / 1_000_000_000 : 0
        var result: [Int32: Entry] = [:]
        for (pid, total) in totals {
            var rate: Double = 0
            if elapsed > 0, let before = previous[pid], total >= before {
                rate = Double(total - before) / elapsed
            }
            result[pid] = Entry(rate: rate, total: total)
        }
        previous = totals
        previousTime = now
        return result
    }

    /// Parses lines like "Google Chrome H.1234,5120,2048," into pid -> bytes in + out.
    static func parse(_ output: String) -> [Int32: UInt64] {
        var totals: [Int32: UInt64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, let dot = parts[0].lastIndex(of: ".") else { continue }
            guard let pid = Int32(parts[0][parts[0].index(after: dot)...]) else { continue }
            let bytes = (UInt64(parts[1]) ?? 0) + (UInt64(parts[2]) ?? 0)
            totals[pid, default: 0] += bytes
        }
        return totals
    }
}
