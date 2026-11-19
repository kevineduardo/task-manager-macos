import AppKit

/// `TaskManager --screenshots <dir> [--theme dark|light]` renders every page to
/// PNG and quits. CI uses it to produce the README images and to smoke-test the UI.
final class ScreenshotMode {
    static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshots"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    static var theme: AppTheme {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--theme"), index + 1 < args.count, args[index + 1] == "light" { return .light }
        return .dark
    }

    private let window: NSWindow
    private let state: AppState
    private let preferences: Preferences
    private let directory: URL

    init(window: NSWindow, state: AppState, preferences: Preferences, directory: URL) {
        self.window = window
        self.state = state
        self.preferences = preferences
        self.directory = directory
    }

    func run() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.appearance = Self.theme.appearance
        window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 820), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let pages: [Page] = [.processes, .performance, .appHistory, .startup, .users, .details, .services, .settings]
        var steps: [(TimeInterval, () -> Void)] = []
        var time: TimeInterval = 5
        for page in pages {
            steps.append((time, { self.state.page = page }))
            time += 2.5
            steps.append((time, { self.capture(name: page.rawValue) }))
            time += 0.5
        }
        steps.append((time, {
            self.state.page = .processes
            self.state.search = "a"
        }))
        time += 2
        steps.append((time, { self.capture(name: "processes-search") }))
        time += 0.5
        steps.append((time, { NSApp.terminate(nil) }))

        for (delay, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private func capture(name: String) {
        let suffix = Self.theme == .light ? "-light" : ""
        let url = directory.appendingPathComponent("\(name)\(suffix).png")
        guard let image = Self.windowImage(window) else {
            FileHandle.standardError.write("screenshot failed: \(name)\n".data(using: .utf8)!)
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("wrote \(url.path)")
        }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Captures our own window. CGWindowListCreateImage is looked up at runtime
    /// because newer SDKs mark it unavailable; the view-cache fallback covers that.
    static func windowImage(_ window: NSWindow) -> CGImage? {
        if let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            let optionIncludingWindow: UInt32 = 1 << 3
            let boundsIgnoreFraming: UInt32 = 1 << 0
            if let image = create(.null, optionIncludingWindow, UInt32(window.windowNumber), boundsIgnoreFraming)?.takeRetainedValue(),
               image.width > 10 {
                return image
            }
        }
        guard let frameView = window.contentView?.superview else { return nil }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.cgImage
    }
}
