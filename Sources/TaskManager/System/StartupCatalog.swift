import Foundation

/// Turns launchd labels such as "com.google.keystone.agent" into readable names
/// and vendors. Pure logic, unit tested.
enum StartupCatalog {
    static let dnsPrefixes: Set<String> = [
        "com", "org", "net", "io", "co", "edu", "gov", "mil", "info", "biz", "dev",
        "app", "me", "us", "uk", "de", "fr", "ru", "jp", "cn", "au", "ca", "nl",
        "it", "es", "br", "in", "kr", "eu", "tv", "pt",
    ]

    static let vendorNames: [String: String] = [
        "adobe": "Adobe", "google": "Google", "docker": "Docker", "apple": "Apple",
        "microsoft": "Microsoft", "oracle": "Oracle", "valvesoftware": "Steam", "valve": "Steam",
        "dropbox": "Dropbox", "spotify": "Spotify", "logitech": "Logitech", "logi": "Logitech",
        "zoom": "Zoom", "zoomus": "Zoom", "slack": "Slack", "tinyspeck": "Slack", "discord": "Discord",
        "jetbrains": "JetBrains", "github": "GitHub", "gitlab": "GitLab", "mozilla": "Mozilla",
        "brave": "Brave", "opera": "Opera", "yandex": "Yandex", "autodesk": "Autodesk",
        "parallels": "Parallels", "vmware": "VMware", "teamviewer": "TeamViewer", "nordvpn": "NordVPN",
        "cloudflare": "Cloudflare", "amazon": "Amazon", "meta": "Meta", "facebook": "Meta",
        "telegram": "Telegram", "skype": "Skype", "cisco": "Cisco", "intel": "Intel",
        "nvidia": "NVIDIA", "wacom": "Wacom", "elgato": "Elgato", "synology": "Synology",
        "backblaze": "Backblaze", "malwarebytes": "Malwarebytes", "bitdefender": "Bitdefender",
        "kaspersky": "Kaspersky", "1password": "1Password", "agilebits": "1Password",
        "lastpass": "LastPass", "bitwarden": "Bitwarden", "notion": "Notion", "figma": "Figma",
        "steam": "Steam", "tailscale": "Tailscale", "objective-see": "Objective-See",
        "openai": "OpenAI", "anthropic": "Anthropic", "raycast": "Raycast", "setapp": "Setapp",
        "macpaw": "MacPaw", "pqrs": "Karabiner", "keybase": "Keybase", "virtualbox": "VirtualBox",
        "corsair": "Corsair", "razer": "Razer", "epicgames": "Epic Games", "blizzard": "Blizzard",
    ]

    /// Vendors whose items are folded into one expandable row.
    static let groupableVendors: Set<String> = [
        "adobe", "google", "docker", "apple", "microsoft", "oracle", "valvesoftware", "jetbrains", "logitech",
    ]

    static let knownLabels: [String: String] = [
        "com.adobe.AdobeCreativeCloud": "Adobe Creative Cloud",
        "com.adobe.ccxprocess": "Adobe Creative Cloud Experience",
        "com.adobe.CCXProcess": "Adobe Creative Cloud Experience",
        "com.adobe.acc.installer.v2": "Adobe Creative Cloud Installer",
        "com.adobe.acc.installer": "Adobe Creative Cloud Installer",
        "com.adobe.GC.Invoker-1.0": "Adobe Genuine Software",
        "com.adobe.agsservice": "Adobe Genuine Software",
        "com.google.GoogleUpdater.wake": "Google Updater",
        "com.google.GoogleUpdater.wake.system": "Google Updater",
        "com.google.keystone.agent": "Google Keystone Agent",
        "com.google.keystone.daemon": "Google Keystone Daemon",
        "com.google.keystone.xpcservice": "Google Keystone XPC",
        "com.google.keystone.system.agent": "Google Keystone Agent",
        "com.docker.socket": "Docker Socket",
        "com.docker.vmnetd": "Docker Networking",
        "com.docker.helper": "Docker Helper",
        "com.microsoft.SyncReporter": "OneDrive Sync Reporter",
        "com.microsoft.update.agent": "Microsoft AutoUpdate",
        "com.microsoft.autoupdate.helper": "Microsoft AutoUpdate Helper",
        "com.microsoft.office.licensingV2.helper": "Microsoft Office Licensing",
        "com.microsoft.OneDriveStandaloneUpdater": "OneDrive",
        "com.microsoft.OneDriveUpdaterDaemon": "OneDrive",
        "com.oracle.java.Java-Updater": "Java Updater",
        "com.valvesoftware.steamclean": "Steam",
    ]

    static let tokenNames: [String: String] = [
        "acc": "Creative Cloud", "ccxprocess": "Creative Cloud Experience", "keystone": "Updater",
        "xpcservice": "XPC Service", "vmnetd": "Networking", "steamclean": "Steam",
        "autoupdate": "AutoUpdate", "syncreporter": "Sync Reporter", "powermetrics": "Power Metrics",
        "licensingv2": "Licensing", "googleupdater": "Updater", "installer": "Installer",
        "helper": "Helper", "agent": "Agent", "daemon": "Daemon", "wake": "", "socket": "Socket",
        "launcher": "Launcher", "updater": "Updater",
    ]

    struct Decoded: Equatable {
        var vendorKey: String
        var vendor: String
        var displayName: String
    }

    static func decode(_ label: String) -> Decoded {
        let parts = label.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        var index = 0
        if parts.count >= 2, dnsPrefixes.contains(parts[0].lowercased()) { index = 1 }
        let vendorRaw = parts.indices.contains(index) ? parts[index] : ""
        let vendorKey = vendorRaw.lowercased()
        let vendor = vendorNames[vendorKey] ?? humanizeToken(vendorRaw)

        let rest = parts.dropFirst(index + 1).map(humanizeToken).filter { !$0.isEmpty }
        var product = dedupeWords(rest.joined(separator: " "))
        if !vendor.isEmpty, product.lowercased().hasPrefix(vendor.lowercased()) {
            product = String(product.dropFirst(vendor.count)).trimmingCharacters(in: .whitespaces)
        }
        var display = knownLabels[label] ?? dedupeWords([vendor, product].filter { !$0.isEmpty }.joined(separator: " "))
        if display.isEmpty { display = humanize(label).isEmpty ? label : humanize(label) }
        return Decoded(vendorKey: vendorKey, vendor: vendor, displayName: display)
    }

    /// "GoogleUpdater-wake_v2" -> "Google Updater wake v2"
    static func humanize(_ text: String) -> String {
        var output = ""
        var previous: Character?
        let chars = Array(text)
        for (i, char) in chars.enumerated() {
            if char == "-" || char == "_" {
                output.append(" ")
            } else {
                if let prev = previous, char.isUppercase {
                    let next = i + 1 < chars.count ? chars[i + 1] : nil
                    if prev.isLowercase || prev.isNumber || (prev.isUppercase && (next?.isLowercase ?? false)) {
                        output.append(" ")
                    }
                }
                output.append(char)
            }
            previous = char
        }
        return output.split(separator: " ").joined(separator: " ")
    }

    static func humanizeToken(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        let isVersion = raw.range(of: #"^v?\d+(\.\d+)*$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if isVersion { return "" }
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        if let mapped = tokenNames[key] { return mapped }
        return humanize(raw).split(separator: " ").map { word -> String in
            let w = String(word)
            if w.count <= 4, w == w.uppercased() { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    static func dedupeWords(_ text: String) -> String {
        var out: [Substring] = []
        for word in text.split(separator: " ") where out.last?.lowercased() != word.lowercased() {
            out.append(word)
        }
        return out.joined(separator: " ")
    }

    /// Every `.app` bundle prefix in a path, outermost first.
    static func bundles(in path: String) -> [String] {
        var result: [String] = []
        var searchStart = path.startIndex
        while let range = path.range(of: ".app", options: .caseInsensitive, range: searchStart..<path.endIndex) {
            let end = range.upperBound
            if end == path.endIndex || path[end] == "/" {
                result.append(String(path[path.startIndex..<end]))
            }
            searchStart = end
        }
        return result
    }
}
