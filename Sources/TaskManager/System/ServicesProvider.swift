import Foundation

struct ServiceItem: Identifiable, Equatable {
    enum Domain: String {
        case user = "User"
        case system = "System"
    }

    var id: String { domain.rawValue + ":" + label }
    var label: String
    var pid: Int32?
    var lastExitStatus: Int?
    var domain: Domain
    var description: String
    var group: String

    var isRunning: Bool { (pid ?? 0) > 0 }
    var statusLabel: String { isRunning ? "Running" : "Stopped" }
    var target: String { (domain == .system ? "system" : "gui/\(getuid())") + "/" + label }
}

/// launchd jobs for the user session and the system, via `launchctl`.
enum ServicesProvider {
    static func load() -> [ServiceItem] {
        var items: [ServiceItem] = []
        if let output = Shell.run("/bin/launchctl", ["list"], timeout: 5) {
            items += parseList(output)
        }
        if let output = Shell.run("/bin/launchctl", ["print", "system"], timeout: 5) {
            items += parsePrintServices(output, domain: .system)
        }
        return items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// `launchctl list`: "PID\tStatus\tLabel" rows.
    static func parseList(_ output: String) -> [ServiceItem] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, fields[0] != "PID" else { return nil }
            return make(label: fields[2], pid: Int32(fields[0]), status: Int(fields[1]), domain: .user)
        }
    }

    /// The `services = { ... }` block of `launchctl print <domain>`.
    static func parsePrintServices(_ output: String, domain: ServiceItem.Domain) -> [ServiceItem] {
        var items: [ServiceItem] = []
        var inside = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inside {
                if trimmed == "services = {" { inside = true }
                continue
            }
            if trimmed == "}" { break }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let label = fields.last else { continue }
            items.append(make(label: String(label), pid: Int32(fields[0]), status: Int(fields[1]), domain: domain))
        }
        return items
    }

    private static func make(label: String, pid: Int32?, status: Int?, domain: ServiceItem.Domain) -> ServiceItem {
        let decoded = StartupCatalog.decode(label)
        return ServiceItem(
            label: label,
            pid: (pid ?? 0) > 0 ? pid : nil,
            lastExitStatus: status,
            domain: domain,
            description: decoded.displayName,
            group: decoded.vendor
        )
    }

    enum Command {
        case start, stop, restart
    }

    static func perform(_ command: Command, on item: ServiceItem) -> Result<Void, ActionError> {
        let arguments: [String]
        switch command {
        case .start: arguments = ["kickstart", item.target]
        case .restart: arguments = ["kickstart", "-k", item.target]
        case .stop: arguments = ["kill", "SIGTERM", item.target]
        }
        if item.domain == .user {
            let result = Shell.execute("/bin/launchctl", arguments)
            if result.succeeded { return .success(()) }
            if !result.error.localizedCaseInsensitiveContains("not permitted") {
                return .failure(ActionError(message: result.error.isEmpty ? "launchctl failed." : result.error.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        let command = "/bin/launchctl " + arguments.map(Shell.quote).joined(separator: " ")
        let result = Shell.runAsAdministrator(command)
        return result.succeeded
            ? .success(())
            : .failure(ActionError(message: ProcessActions.friendly(result.error, fallback: "Couldn't change the service.")))
    }
}
