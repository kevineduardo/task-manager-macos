import AppKit
import SwiftUI

/// Design tokens modelled on Windows 11 Task Manager (Fluent), adapted to macOS.
/// Every color has a light and a dark variant.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    // Surfaces
    static let window = dynamic(light: hex(0xF3F3F3), dark: hex(0x202020))
    static let content = dynamic(light: hex(0xF9F9F9), dark: hex(0x272727))
    static let contentBorder = dynamic(light: hex(0xE5E5E5), dark: hex(0x1D1D1D))
    static let card = dynamic(light: hex(0xFFFFFF), dark: hex(0x2D2D2D))
    static let cardBorder = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0xFFFFFF, alpha: 0.06))
    static let input = dynamic(light: hex(0xFFFFFF, alpha: 0.7), dark: hex(0xFFFFFF, alpha: 0.06))
    static let inputBorder = dynamic(light: hex(0x000000, alpha: 0.10), dark: hex(0xFFFFFF, alpha: 0.08))

    // Rows and controls
    static let hover = dynamic(light: hex(0x000000, alpha: 0.04), dark: hex(0xFFFFFF, alpha: 0.05))
    static let pressed = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.08))
    static let selection = dynamic(light: hex(0x000000, alpha: 0.06), dark: hex(0xFFFFFF, alpha: 0.085))
    static let divider = dynamic(light: hex(0x000000, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.07))
    static let sectionHeader = dynamic(light: hex(0x000000, alpha: 0.025), dark: hex(0xFFFFFF, alpha: 0.025))

    // Text
    static let text = dynamic(light: hex(0x1A1A1A), dark: hex(0xFFFFFF))
    static let secondaryText = dynamic(light: hex(0x5C5C5C), dark: hex(0xC5C5C5))
    static let tertiaryText = dynamic(light: hex(0x8A8A8A), dark: hex(0x9A9A9A))

    // Semantic
    static let success = dynamic(light: hex(0x0F7B0F), dark: hex(0x6CCB5F))
    static let successFill = dynamic(light: hex(0xDFF6DD), dark: hex(0x393D1B))
    static let danger = dynamic(light: hex(0xC42B1C), dark: hex(0xFF99A4))
    static let dangerFill = dynamic(light: hex(0xFDE7E9), dark: hex(0x442726))
    static let caution = dynamic(light: hex(0x9D5D00), dark: hex(0xFCE100))
    static let cautionFill = dynamic(light: hex(0xFFF4CE), dark: hex(0x433519))

    // Performance graphs (Windows 11 palette)
    static let cpu = dynamic(light: hex(0x117DBB), dark: hex(0x2F9BE0))
    static let memory = dynamic(light: hex(0x8B12AE), dark: hex(0xB265E6))
    static let disk = dynamic(light: hex(0x4DA60C), dark: hex(0x5FC74A))
    static let network = dynamic(light: hex(0xA74F01), dark: hex(0xFF9F3A))
    static let gpu = dynamic(light: hex(0xA4126E), dark: hex(0xE85FD0))
    static let graphGrid = dynamic(light: hex(0x000000, alpha: 0.07), dark: hex(0xFFFFFF, alpha: 0.07))

    /// Usage heat for data cells (0...1). Windows tints busy cells from pale
    /// yellow to orange.
    static func heat(_ fraction: Double) -> Color {
        guard fraction > 0.004 else { return .clear }
        let f = min(1, max(0, fraction))
        // Ease in so small values stay subtle.
        let t = pow(f, 0.6)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hue = (48 - 40 * t) / 360
            if dark {
                return NSColor(hue: hue, saturation: 0.75, brightness: 1, alpha: 0.06 + 0.34 * t)
            }
            return NSColor(hue: hue, saturation: 0.18 + 0.5 * t, brightness: 1, alpha: 1)
        })
    }

    static let rowHeight: CGFloat = 30
    static let corner: CGFloat = 6
}

extension Font {
    static let tmBody = Font.system(size: 12.5)
    static let tmSmall = Font.system(size: 11)
    static let tmCaption = Font.system(size: 11.5)
    static let tmTitle = Font.system(size: 20, weight: .semibold)
    static let tmPageTitle = Font.system(size: 14, weight: .semibold)
    static let tmNumber = Font.system(size: 12.5).monospacedDigit()
}

/// Window-level state shared by every page.
final class AppState: ObservableObject {
    @Published var page: Page
    @Published var search = ""
    @Published var selection: String?
    @Published var message: Banner?
    @Published var runTaskShown = false
    @Published var properties: ProcessRecord?
    @Published var pendingEfficiency: [ProcessRecord]?
    @Published var expandedNodes = Set<String>()
    @Published var collapsedSections = Set<ProcessKind>()
    @Published var focusSearch = false

    struct Banner: Identifiable, Equatable {
        enum Style { case info, error, success }
        let id = UUID()
        var text: String
        var style: Style
    }

    init(page: Page) {
        self.page = page
    }

    func show(_ text: String, style: Banner.Style = .error) {
        message = Banner(text: text, style: style)
    }

    /// Runs an action off the main thread (admin prompts block) and reports failures.
    func perform(_ work: @escaping () -> Result<Void, ActionError>, success: String? = nil, then: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                switch result {
                case .success:
                    if let success { self.show(success, style: .success) }
                case .failure(let error):
                    self.show(error.message, style: .error)
                }
                then?()
            }
        }
    }
}
