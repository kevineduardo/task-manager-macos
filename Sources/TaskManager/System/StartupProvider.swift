import Foundation
import Security

struct StartupItem: Identifiable, Equatable {
    enum Kind: String {
        case userAgent = "Launch agent"
        case globalAgent = "Global launch agent"
        case daemon = "Launch daemon"

        var isDaemon: Bool { self == .daemon }
    }

    var id: String { plistPath }
    var label: String
    var name: String
    var vendor: String
    var vendorKey: String
    var publisher: String?
    var plistPath: String
    var program: String?
    var iconPath: String?
    var kind: Kind
    var enabled: Bool
    var runAtLoad: Bool
    var keepAlive: Bool
    var groupKey: String?

    var publisherLabel: String { publisher ?? (vendor.isEmpty ? "Unknown" : vendor) }

    /// Rough stand-in for Windows' measured impact, from how the job is configured.
    var impact: String {
        guard enabled else { return "None" }
        if keepAlive { return "High" }
        if runAtLoad { return "Medium" }
        return "Low"
    }
}

/// Reads launchd plists from the standard folders and toggles them with launchctl.
enum StartupProvider {
    static func loadItems() -> [StartupItem] {
        let home = NSHomeDirectory()
        let sources: [(String, StartupItem.Kind)] = [
            (home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]
        let disabled = disabledLabels()
        var items: [StartupItem] = []
        var publisherCache: [String: String?] = [:]

        for (folder, kind) in sources {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = folder + "/" + file
                let plist = NSDictionary(contentsOfFile: path) as? [String: Any] ?? [:]
                let fileLabel = String(file.dropLast(6))
                let label = (plist["Label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? fileLabel
                let arguments = (plist["ProgramArguments"] as? [String]) ?? []
                let program = (plist["Program"] as? String) ?? arguments.first
                let decoded = StartupCatalog.decode(label)

                var name = decoded.displayName
                var iconPath: String?
                let candidates = ([plist["Program"] as? String] + arguments.map { Optional($0) }).compactMap { $0 }
                for candidate in candidates {
                    if let bundle = StartupCatalog.bundles(in: candidate).first(where: { FileManager.default.fileExists(atPath: $0) }) {
                        iconPath = bundle
                        if StartupCatalog.knownLabels[label] == nil, let bundleName = Bundle(path: bundle)?.displayName {
                            name = bundleName
                        }
                        break
                    }
                }
                if iconPath == nil, let program, FileManager.default.fileExists(atPath: program) {
                    iconPath = program
                }

                var publisher: String?
                if let signed = iconPath ?? program {
                    if let cached = publisherCache[signed] {
                        publisher = cached
                    } else {
                        publisher = CodeSignature.publisher(of: signed)
                        publisherCache[signed] = publisher
                    }
                }

                let keepAlive: Bool
                if let flag = plist["KeepAlive"] as? Bool { keepAlive = flag } else { keepAlive = plist["KeepAlive"] is [String: Any] }
                let groupable = StartupCatalog.groupableVendors.contains(decoded.vendorKey)
                items.append(StartupItem(
                    label: label,
                    name: name,
                    vendor: decoded.vendor,
                    vendorKey: decoded.vendorKey,
                    publisher: publisher,
                    plistPath: path,
                    program: program,
                    iconPath: iconPath,
                    kind: kind,
                    enabled: !disabled.contains(label) && (plist["Disabled"] as? Bool) != true,
                    runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    keepAlive: keepAlive,
                    groupKey: groupable ? decoded.vendorKey : nil
                ))
            }
        }

        // Items of one vendor share the first icon found among them.
        var vendorIcons: [String: String] = [:]
        for item in items { if let key = item.groupKey, let icon = item.iconPath, vendorIcons[key] == nil { vendorIcons[key] = icon } }
        for index in items.indices where items[index].iconPath == nil {
            if let key = items[index].groupKey { items[index].iconPath = vendorIcons[key] }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func disabledLabels() -> Set<String> {
        var result = Set<String>()
        for domain in ["gui/\(getuid())", "system"] {
            guard let output = Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: 5) else { continue }
            result.formUnion(parseDisabled(output))
        }
        return result
    }

    /// Parses `launchctl print-disabled` lines such as `"com.foo.bar" => disabled` (or `=> true`).
    static func parseDisabled(_ output: String) -> Set<String> {
        var result = Set<String>()
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let arrow = trimmed.range(of: "=>") else { continue }
            let value = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            let label = trimmed[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            result.insert(label)
        }
        return result
    }

    /// Enables or disables a job for future logins. Daemons and all-user agents
    /// need administrator rights; the standard macOS prompt asks for them.
    static func setEnabled(_ item: StartupItem, enabled: Bool) -> Result<Void, ActionError> {
        let domain = item.kind.isDaemon ? "system" : "gui/\(getuid())"
        let target = "\(domain)/\(item.label)"
        let verb = enabled ? "enable" : "disable"
        if !item.kind.isDaemon {
            let result = Shell.execute("/bin/launchctl", [verb, target])
            if result.succeeded { return .success(()) }
        }
        let result = Shell.runAsAdministrator("/bin/launchctl \(verb) \(Shell.quote(target))")
        return result.succeeded
            ? .success(())
            : .failure(ActionError(message: ProcessActions.friendly(result.error, fallback: "Couldn't change the startup item.")))
    }
}

enum CodeSignature {
    /// The organisation from the leaf signing certificate, e.g. "Google LLC".
    static func publisher(of path: String) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return nil }
        if summary.hasPrefix("Apple ") || summary == "Software Signing" { return "Apple Inc." }
        // "Developer ID Application: Google LLC (EQHXZ8M8AV)" -> "Google LLC"
        var name = summary
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if let paren = name.range(of: " (", options: .backwards) { name = String(name[..<paren.lowerBound]) }
        return name.isEmpty ? nil : name
    }
}

extension Bundle {
    var displayName: String? {
        let name = object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
        return name?.isEmpty == false ? name : nil
    }
}
