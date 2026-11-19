import AppKit

enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // App
        let app = NSMenu()
        app.addItem(withTitle: "About Task Manager", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Task Manager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Task Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "Task Manager", to: main)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("Run new task…", #selector(AppDelegate.runNewTask(_:)), "n", target))
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, titled: "File", to: main)

        // Edit (needed for copy/paste in the search box)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(item("Find", #selector(AppDelegate.focusSearch(_:)), "f", target))
        add(edit, titled: "Edit", to: main)

        // View
        let view = NSMenu(title: "View")
        for (index, page) in Page.navigable.enumerated() {
            let entry = item(page.title, #selector(AppDelegate.showPage(_:)), "\(index + 1)", target)
            entry.representedObject = page.rawValue
            view.addItem(entry)
        }
        view.addItem(.separator())
        view.addItem(item("Refresh now", #selector(AppDelegate.refreshNow(_:)), "r", target))
        let speed = NSMenuItem(title: "Update speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for option in UpdateSpeed.allCases {
            let entry = item(option.title, #selector(AppDelegate.setUpdateSpeed(_:)), "", target)
            entry.representedObject = option.rawValue
            speedMenu.addItem(entry)
        }
        speed.submenu = speedMenu
        view.addItem(speed)
        view.addItem(item("Group by type", #selector(AppDelegate.toggleGroupByType(_:)), "", target))
        view.addItem(.separator())
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(view, titled: "View", to: main)

        // Process
        let process = NSMenu(title: "Process")
        let end = item("End task", #selector(AppDelegate.endSelectedTask(_:)), "\u{8}", target)
        end.keyEquivalentModifierMask = [.command]
        process.addItem(end)
        add(process, titled: "Process", to: main)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(item("Always on top", #selector(AppDelegate.toggleAlwaysOnTop(_:)), "", target))
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        add(window, titled: "Window", to: main)

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("Task Manager on GitHub", #selector(AppDelegate.openRepository(_:)), "", target))
        NSApp.helpMenu = help
        add(help, titled: "Help", to: main)

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        holder.submenu = menu
        main.addItem(holder)
    }
}
