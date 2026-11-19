import AppKit
import Combine
import Foundation

enum Page: String, CaseIterable, Identifiable, Codable {
    case processes, performance, appHistory, startup, users, details, services, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: return "Processes"
        case .performance: return "Performance"
        case .appHistory: return "App history"
        case .startup: return "Startup apps"
        case .users: return "Users"
        case .details: return "Details"
        case .services: return "Services"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .processes: return "square.grid.2x2"
        case .performance: return "waveform.path.ecg"
        case .appHistory: return "clock.arrow.circlepath"
        case .startup: return "gauge.with.dots.needle.33percent"
        case .users: return "person.2"
        case .details: return "list.bullet"
        case .services: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        }
    }

    static let navigable: [Page] = [.processes, .performance, .appHistory, .startup, .users, .details, .services]
}

enum UpdateSpeed: String, CaseIterable, Identifiable, Codable {
    case high, normal, low, paused

    var id: String { rawValue }
    var title: String {
        switch self {
        case .high: return "High"
        case .normal: return "Normal"
        case .low: return "Low"
        case .paused: return "Paused"
        }
    }
    var detail: String {
        switch self {
        case .high: return "Every half second"
        case .normal: return "Every second"
        case .low: return "Every 4 seconds"
        case .paused: return "Doesn't update"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .high: return 0.5
        case .normal: return 1
        case .low: return 4
        case .paused: return nil
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Use system setting"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum CPUGraphMode: String, Codable {
    case overall, logical
}

/// User settings, persisted in UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults: UserDefaults

    @Published var updateSpeed: UpdateSpeed { didSet { save(updateSpeed.rawValue, "updateSpeed") } }
    @Published var startPage: Page { didSet { save(startPage.rawValue, "startPage") } }
    @Published var theme: AppTheme { didSet { save(theme.rawValue, "theme"); applyTheme() } }
    @Published var alwaysOnTop: Bool { didSet { save(alwaysOnTop, "alwaysOnTop") } }
    @Published var minimizeOnUse: Bool { didSet { save(minimizeOnUse, "minimizeOnUse") } }
    @Published var groupByType: Bool { didSet { save(groupByType, "groupByType") } }
    @Published var processColumns: [ProcessColumn] { didSet { save(processColumns.map(\.rawValue), "processColumns") } }
    @Published var showFullAccountName: Bool { didSet { save(showFullAccountName, "showFullAccountName") } }
    @Published var historyForAllProcesses: Bool { didSet { save(historyForAllProcesses, "historyForAllProcesses") } }
    @Published var confirmEfficiencyMode: Bool { didSet { save(confirmEfficiencyMode, "confirmEfficiencyMode") } }
    @Published var showMenuBarExtra: Bool { didSet { save(showMenuBarExtra, "showMenuBarExtra") } }
    @Published var cpuGraphMode: CPUGraphMode { didSet { save(cpuGraphMode.rawValue, "cpuGraphMode") } }
    @Published var navigationExpanded: Bool { didSet { save(navigationExpanded, "navigationExpanded") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        updateSpeed = UpdateSpeed(rawValue: defaults.string(forKey: "updateSpeed") ?? "") ?? .normal
        startPage = Page(rawValue: defaults.string(forKey: "startPage") ?? "") ?? .processes
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        alwaysOnTop = defaults.bool(forKey: "alwaysOnTop")
        minimizeOnUse = defaults.bool(forKey: "minimizeOnUse")
        groupByType = defaults.object(forKey: "groupByType") as? Bool ?? true
        let columns = (defaults.stringArray(forKey: "processColumns") ?? []).compactMap(ProcessColumn.init(rawValue:))
        processColumns = columns.contains(.name) ? columns : ProcessColumn.defaultVisible
        showFullAccountName = defaults.bool(forKey: "showFullAccountName")
        historyForAllProcesses = defaults.bool(forKey: "historyForAllProcesses")
        confirmEfficiencyMode = defaults.object(forKey: "confirmEfficiencyMode") as? Bool ?? true
        showMenuBarExtra = defaults.bool(forKey: "showMenuBarExtra")
        cpuGraphMode = CPUGraphMode(rawValue: defaults.string(forKey: "cpuGraphMode") ?? "") ?? .logical
        navigationExpanded = defaults.bool(forKey: "navigationExpanded")
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func applyTheme() {
        NSApp?.appearance = theme.appearance
    }

    func toggle(_ column: ProcessColumn) {
        guard column != .name else { return }
        if let index = processColumns.firstIndex(of: column) {
            processColumns.remove(at: index)
        } else {
            // Keep the canonical column order.
            var next = processColumns + [column]
            next.sort { lhs, rhs in
                (ProcessColumn.allCases.firstIndex(of: lhs) ?? 0) < (ProcessColumn.allCases.firstIndex(of: rhs) ?? 0)
            }
            processColumns = next
        }
    }

    func resetColumns() {
        processColumns = ProcessColumn.defaultVisible
    }
}
