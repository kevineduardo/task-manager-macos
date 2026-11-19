import AppKit
import Combine
import SwiftUI

@main
enum TaskManagerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    let preferences = Preferences.shared
    lazy var monitor = Monitor(preferences: preferences)
    lazy var state = AppState(page: preferences.startPage)

    private var window: NSWindow!
    private var keyMonitor: Any?
    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    private let titleItem = NSToolbarItem.Identifier("title")
    private let searchItem = NSToolbarItem.Identifier("search")

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.applyTheme()
        NSApp.mainMenu = MainMenu.build(target: self)
        makeWindow()
        installKeyboardMonitor()
        monitor.start()

        preferences.$alwaysOnTop
            .sink { [weak self] onTop in self?.window?.level = onTop ? .floating : .normal }
            .store(in: &cancellables)
        preferences.$showMenuBarExtra
            .sink { [weak self] show in self?.setStatusItem(visible: show) }
            .store(in: &cancellables)

        if let directory = ScreenshotMode.outputDirectory {
            ScreenshotMode(window: window, state: state, preferences: preferences, directory: directory).run()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !preferences.showMenuBarExtra
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.appHistory.save()
    }

    // MARK: Window

    private func makeWindow() {
        let root = RootView().environmentObjects(state, monitor, preferences)
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Task Manager"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 540)
        window.contentView = hosting
        window.delegate = self
        window.backgroundColor = .clear

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [searchItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setFrameAutosaveName("TaskManagerMainWindow")
        if !window.setFrameUsingName("TaskManagerMainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.level = preferences.alwaysOnTop ? .floating : .normal

        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.monitor.isWindowVisible = self.window.occlusionState.contains(.visible)
        }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [titleItem, .flexibleSpace, searchItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case titleItem:
            let view = NSHostingView(rootView: ToolbarTitle())
            view.translatesAutoresizingMaskIntoConstraints = false
            item.view = view
            item.label = "Task Manager"
        case searchItem:
            let view = NSHostingView(rootView: ToolbarSearchField().environmentObjects(state, monitor, preferences))
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
                view.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
                view.heightAnchor.constraint(equalToConstant: 30),
            ])
            let preferred = view.widthAnchor.constraint(equalToConstant: 460)
            preferred.priority = .defaultLow
            preferred.isActive = true
            item.view = view
            item.label = "Search"
            item.visibilityPriority = .high
        default:
            return nil
        }
        return item
    }

    // MARK: Keyboard

    /// Arrow keys, Delete and Return go to the visible table unless a text field has focus.
    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.attachedSheet == nil else { return event }
            if self.window.firstResponder is NSText { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return event }
            let action: KeyAction?
            switch event.keyCode {
            case 125: action = .down
            case 126: action = .up
            case 123: action = .left
            case 124: action = .right
            case 51, 117: action = .delete
            case 36, 76: action = .enter
            case 53: action = .escape
            case 116: action = .pageUp
            case 121: action = .pageDown
            case 115: action = .home
            case 119: action = .end
            default: action = nil
            }
            if let action, KeyboardRouter.shared.handler?(action) == true { return nil }
            // Typing a letter jumps to the search box, like Windows.
            if action == nil, let characters = event.characters, characters.count == 1,
               characters.rangeOfCharacter(from: .alphanumerics) != nil, self.state.page != .settings {
                self.state.search += characters
                self.state.focusSearch = true
                return nil
            }
            return event
        }
    }

    // MARK: Menu bar extra

    private func setStatusItem(visible: Bool) {
        if visible {
            if statusItem == nil {
                statusItem = StatusItemController(monitor: monitor) { [weak self] in self?.showWindow() }
            }
        } else {
            statusItem = nil
        }
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        showWindow()
        state.page = .settings
    }

    @objc func showPage(_ sender: NSMenuItem) {
        showWindow()
        if let page = Page(rawValue: sender.representedObject as? String ?? "") { state.page = page }
    }

    @objc func focusSearch(_ sender: Any?) {
        showWindow()
        state.focusSearch = true
    }

    @objc func runNewTask(_ sender: Any?) {
        showWindow()
        state.runTaskShown = true
    }

    @objc func endSelectedTask(_ sender: Any?) {
        _ = KeyboardRouter.shared.handler?(.delete)
    }

    @objc func refreshNow(_ sender: Any?) {
        monitor.refreshNow()
    }

    @objc func setUpdateSpeed(_ sender: NSMenuItem) {
        if let speed = UpdateSpeed(rawValue: sender.representedObject as? String ?? "") { preferences.updateSpeed = speed }
    }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        preferences.alwaysOnTop.toggle()
    }

    @objc func toggleGroupByType(_ sender: Any?) {
        preferences.groupByType.toggle()
    }

    @objc func openRepository(_ sender: Any?) {
        if let url = URL(string: AppInfo.repositoryURL) { NSWorkspace.shared.open(url) }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setUpdateSpeed(_:)):
            item.state = (item.representedObject as? String) == preferences.updateSpeed.rawValue ? .on : .off
        case #selector(toggleAlwaysOnTop(_:)):
            item.state = preferences.alwaysOnTop ? .on : .off
        case #selector(toggleGroupByType(_:)):
            item.state = preferences.groupByType ? .on : .off
        case #selector(showPage(_:)):
            item.state = (item.representedObject as? String) == state.page.rawValue ? .on : .off
        default:
            break
        }
        return true
    }
}
