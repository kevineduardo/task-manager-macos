import AppKit
import Darwin
import Foundation

struct ActionError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum ProcessActions {
    private static let prioDarwinProcess: Int32 = 4      // PRIO_DARWIN_PROCESS
    private static let prioDarwinBackground: Int32 = 0x1000 // PRIO_DARWIN_BG

    /// Ends processes. Apps get a polite terminate first (so they can save), plain
    /// processes get SIGTERM. Processes owned by other users need an admin prompt.
    static func endTask(_ records: [ProcessRecord], force: Bool = false) -> Result<Void, ActionError> {
        var denied: [Int32] = []
        var failures: [String] = []
        for record in records {
            if !force, record.isRegularApp, let app = NSRunningApplication(processIdentifier: record.pid) {
                if app.terminate() { continue }
            }
            if kill(record.pid, force ? SIGKILL : SIGTERM) != 0 {
                if errno == EPERM {
                    denied.append(record.pid)
                } else if errno != ESRCH {
                    failures.append("\(record.name): \(String(cString: strerror(errno)))")
                }
            }
        }
        if !denied.isEmpty {
            let signal = force ? "-KILL" : "-TERM"
            let command = "/bin/kill \(signal) " + denied.map(String.init).joined(separator: " ")
            let result = Shell.runAsAdministrator(command)
            if !result.succeeded {
                return .failure(ActionError(message: friendly(result.error, fallback: "Couldn't end the task.")))
            }
        }
        if let first = failures.first { return .failure(ActionError(message: first)) }
        return .success(())
    }

    /// Every descendant of `pid`, deepest first, followed by `pid` itself.
    static func processTree(of pid: Int32, in records: [ProcessRecord]) -> [ProcessRecord] {
        var children: [Int32: [ProcessRecord]] = [:]
        for record in records { children[record.ppid, default: []].append(record) }
        var result: [ProcessRecord] = []
        func walk(_ current: Int32, depth: Int) {
            guard depth < 64 else { return }
            for child in children[current] ?? [] where child.pid != current {
                walk(child.pid, depth: depth + 1)
                result.append(child)
            }
        }
        walk(pid, depth: 0)
        if let root = records.first(where: { $0.pid == pid }) { result.append(root) }
        return result
    }

    static func setPriority(_ record: ProcessRecord, _ priority: Priority) -> Result<Void, ActionError> {
        if setpriority(PRIO_PROCESS, id_t(record.pid), priority.rawValue) == 0 { return .success(()) }
        guard errno == EPERM || errno == EACCES else {
            return .failure(ActionError(message: String(cString: strerror(errno))))
        }
        let result = Shell.runAsAdministrator("/usr/bin/renice \(priority.rawValue) -p \(record.pid)")
        return result.succeeded ? .success(()) : .failure(ActionError(message: friendly(result.error, fallback: "Couldn't change the priority.")))
    }

    /// The closest macOS match to Windows "Efficiency mode": the Darwin background
    /// policy lowers CPU priority and throttles disk and network I/O.
    static func setEfficiencyMode(_ records: [ProcessRecord], enabled: Bool) -> Result<Void, ActionError> {
        for record in records {
            if setpriority(prioDarwinProcess, id_t(record.pid), enabled ? prioDarwinBackground : 0) != 0 {
                if errno == EPERM || errno == EACCES {
                    return .failure(ActionError(message: "Efficiency mode can only be changed for your own processes."))
                }
                if errno != ESRCH {
                    return .failure(ActionError(message: String(cString: strerror(errno))))
                }
            }
        }
        return .success(())
    }

    static func suspend(_ records: [ProcessRecord], resume: Bool) -> Result<Void, ActionError> {
        for record in records where kill(record.pid, resume ? SIGCONT : SIGSTOP) != 0 {
            if errno == EPERM {
                return .failure(ActionError(message: "You don't have permission to \(resume ? "resume" : "suspend") \(record.name)."))
            }
        }
        return .success(())
    }

    static func revealInFinder(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func searchOnline(_ text: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    /// "Run new task": opens apps, files and URLs, or runs a shell command.
    static func runTask(_ input: String, asAdministrator: Bool) -> Result<Void, ActionError> {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(ActionError(message: "Type the name of a program, folder, document or command.")) }

        if asAdministrator {
            let result = Shell.runAsAdministrator(text + " > /dev/null 2>&1 &")
            return result.succeeded ? .success(()) : .failure(ActionError(message: friendly(result.error, fallback: "Couldn't run the task.")))
        }

        let expanded = (text as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
            return .success(())
        }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "mailto", "x-apple.systempreferences"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return .success(())
        }
        if let appURL = findApplication(named: text) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return .success(())
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return .success(())
        } catch {
            return .failure(ActionError(message: error.localizedDescription))
        }
    }

    static func findApplication(named name: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return url }
        let file = name.hasSuffix(".app") ? name : name + ".app"
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func friendly(_ error: String, fallback: String) -> String {
        if error.contains("-128") || error.localizedCaseInsensitiveContains("canceled") || error.localizedCaseInsensitiveContains("cancelled") {
            return "The administrator prompt was cancelled."
        }
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
