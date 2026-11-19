import Foundation

/// Pure helpers that decide where a process belongs. Kept free of system calls
/// so they can be unit tested.
enum ProcessClassifier {
    static let systemPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/usr/lib/",
        "/sbin/", "/bin/", "/Library/Apple/", "/private/var/db/",
    ]

    static func kind(pid: Int32, uid: UInt32, path: String?, isRegularApp: Bool) -> ProcessKind {
        if isRegularApp { return .app }
        if pid <= 1 { return .system }
        guard let path, !path.isEmpty else {
            return uid == 0 ? .system : .background
        }
        if path.hasPrefix("/usr/local/") { return .background }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return .system }
        return .background
    }

    /// The outermost `.app` bundle in a path:
    /// "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
    /// gives "/Applications/Chrome.app".
    static func outerBundle(of path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else {
            return nil
        }
        return String(path[path.startIndex..<path.index(range.lowerBound, offsetBy: 4)])
    }

    /// The innermost `.app` bundle in a path (used for helper icons and names).
    static func innerBundle(of path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[path.startIndex..<path.index(range.lowerBound, offsetBy: 4)])
    }

    /// Display name of a bundle path: "/Applications/Google Chrome.app" -> "Google Chrome".
    static func bundleName(_ bundlePath: String) -> String {
        let last = (bundlePath as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// A readable process name when the system offers none: prefer the
    /// executable's file name, then the kernel's short name.
    static func displayName(path: String?, kernelName: String) -> String {
        if let path, !path.isEmpty {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return kernelName.isEmpty ? "Unknown" : kernelName
    }
}
