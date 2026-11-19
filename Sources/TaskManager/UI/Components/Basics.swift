import AppKit
import SwiftUI

// MARK: - Icons

/// Caches Finder icons by path. NSWorkspace icons are cheap once loaded,
/// but creating them for hundreds of rows every second is not.
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private lazy var executableIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .unixExecutable)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }()

    init() {
        cache.countLimit = 600
    }

    func icon(for path: String?) -> NSImage {
        guard let path, !path.isEmpty else { return executableIcon }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon: NSImage
        if path.hasSuffix(".app") || FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = executableIcon
        }
        icon.size = NSSize(width: 32, height: 32)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

struct FileIcon: View {
    var path: String?
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Window chrome

/// Lets the custom title bar move the window and zoom on double-click.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Command bar

struct CommandButton: View {
    var title: String
    var symbol: String
    var isEnabled = true
    var showsTitle = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)
                if showsTitle {
                    Text(title).font(.tmBody)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering && isEnabled ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Theme.text : Theme.tertiaryText)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// A command-bar button that opens a menu ("View", "…").
struct CommandMenu<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.tmBody)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 30)
        .help(title)
    }
}

struct CommandBar<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.tmPageTitle)
                if let subtitle {
                    Text(subtitle).font(.tmSmall).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.leading, 20)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.trailing, 12)
        .frame(height: 52)
    }
}

// MARK: - Misc

struct StatusPill: View {
    var text: String
    var positive: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(positive ? Theme.success : Theme.secondaryText)
            .background(Capsule().fill(positive ? Theme.successFill : Theme.hover))
    }
}

struct BannerView: View {
    var banner: AppState.Banner
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(banner.text)
                .font(.tmBody)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardBorder))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var icon: String {
        switch banner.style {
        case .info: return "info.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch banner.style {
        case .info: return .accentColor
        case .error: return Theme.danger
        case .success: return Theme.success
        }
    }

    private var fill: Color {
        switch banner.style {
        case .info: return Theme.card
        case .error: return Theme.dangerFill
        case .success: return Theme.successFill
        }
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(title).font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.tmCaption)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small disclosure chevron used by tree rows.
struct Disclosure: View {
    var expanded: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
