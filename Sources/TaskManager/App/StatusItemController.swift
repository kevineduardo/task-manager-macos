import AppKit
import Combine

/// Optional menu bar extra: a tiny CPU history graph plus the current percentage.
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellable: AnyCancellable?
    private let open: () -> Void

    init(monitor: Monitor, open: @escaping () -> Void) {
        self.open = open
        super.init()
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Task Manager", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Task Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        cancellable = monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self, weak monitor] snapshot in
                guard let self, let monitor else { return }
                let values = Array(monitor.history["cpu"].values.suffix(14))
                self.item.button?.image = Self.graph(values)
                self.item.button?.title = " " + Format.wholePercent(snapshot.cpu.total)
            }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func openWindow() {
        open()
    }

    static func graph(_ values: [Double]) -> NSImage {
        let size = NSSize(width: 30, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            NSColor.black.setFill()
            let barWidth = (rect.width - 4) / CGFloat(max(1, values.count))
            for (index, value) in values.enumerated() {
                let height = max(1, (rect.height - 4) * CGFloat(min(100, value) / 100))
                NSBezierPath(rect: NSRect(x: 2 + CGFloat(index) * barWidth, y: 2, width: max(1, barWidth - 0.5), height: height)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
