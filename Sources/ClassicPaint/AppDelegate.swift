import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let state = PaintState.shared

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
        installWindowsStyleShortcuts()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Lets Ctrl+key do what ⌘+key does, so Windows muscle memory works.
    /// Menu items bound to Ctrl itself (Ctrl+W, Ctrl+PgUp, Ctrl+Plus…) win first.
    private func installWindowsStyleShortcuts() {
        let excluded: Set<String> = ["q", "h", "m", ",", "`"]
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .control, .option])
            guard mods == [.control] else { return e }
            if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return nil }
            guard let chars = e.charactersIgnoringModifiers, chars.count == 1,
                  let scalar = chars.unicodeScalars.first, scalar.value > 0x20, scalar.value < 0x7F,
                  !excluded.contains(chars.lowercased()) else { return e }
            let flags = e.modifierFlags.subtracting(.control).union(.command)
            guard let mapped = NSEvent.keyEvent(with: .keyDown, location: e.locationInWindow, modifierFlags: flags,
                                                timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                                characters: chars, charactersIgnoringModifiers: chars,
                                                isARepeat: e.isARepeat, keyCode: e.keyCode) else { return e }
            if NSApp.keyWindow?.performKeyEquivalent(with: mapped) == true { return nil }
            if NSApp.mainMenu?.performKeyEquivalent(with: mapped) == true { return nil }
            return e
        }
    }

    // MARK: Global toggles

    @objc func toggleToolBox(_ sender: Any?) { state.showToolBox.toggle() }
    @objc func toggleColorBox(_ sender: Any?) { state.showColorBox.toggle() }
    @objc func toggleStatusBar(_ sender: Any?) { state.showStatusBar.toggle() }
    @objc func toggleTextToolbar(_ sender: Any?) {
        state.showTextToolbar.toggle()
        if !state.showTextToolbar { FontBar.shared.orderOut(nil) }
    }
    @objc func toggleGrid(_ sender: Any?) { state.showGrid.toggle() }
    @objc func toggleDrawOpaque(_ sender: Any?) { state.transparentSelection.toggle() }
    @objc func chooseTool(_ sender: NSMenuItem) {
        if let t = Tool(rawValue: sender.tag) { state.selectTool(t) }
    }
    @objc func largerBrush(_ sender: Any?) { state.adjustSize(1) }
    @objc func smallerBrush(_ sender: Any?) { state.adjustSize(-1) }
    @objc func swapColors(_ sender: Any?) { (state.primary, state.secondary) = (state.secondary, state.primary) }
    @objc func editColors(_ sender: Any?) { state.editColor(index: state.palette.firstIndex(of: state.primary)) }
    @objc func showHelp(_ sender: Any?) { HelpWindow.show() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleToolBox(_:)): item.state = state.showToolBox ? .on : .off
        case #selector(toggleColorBox(_:)): item.state = state.showColorBox ? .on : .off
        case #selector(toggleStatusBar(_:)): item.state = state.showStatusBar ? .on : .off
        case #selector(toggleTextToolbar(_:)): item.state = state.showTextToolbar ? .on : .off
        case #selector(toggleGrid(_:)): item.state = state.showGrid ? .on : .off
        case #selector(toggleDrawOpaque(_:)): item.state = state.transparentSelection ? .off : .on
        case #selector(chooseTool(_:)): item.state = item.tag == state.tool.rawValue ? .on : .off
        default: break
        }
        return true
    }
}

enum MainMenu {
    private static func key(_ scalar: Int) -> String { String(Character(UnicodeScalar(scalar)!)) }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.tag = tag
        if hidden {
            // Extra key equivalents for the item above it.
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        menu.addItem(item)
        return item
    }

    private static func submenu(_ main: NSMenu, _ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
        let menu = NSMenu(title: title)
        build(menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Classic Paint"

        _ = submenu(main, appName) { m in
            add(m, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
            m.addItem(.separator())
            add(m, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        }

        _ = submenu(main, "File") { m in
            add(m, "New", #selector(NSDocumentController.newDocument(_:)), "n")
            add(m, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            // AppKit inserts "Open Recent" here by itself.
            m.addItem(.separator())
            add(m, "Close", #selector(NSWindow.performClose(_:)), "w")
            add(m, "Save", #selector(NSDocument.save(_:)), "s")
            add(m, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
            add(m, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
            m.addItem(.separator())
            add(m, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
            add(m, "Print…", #selector(NSDocument.printDocument(_:)), "p")
            m.addItem(.separator())
            add(m, "Set As Desktop Background (Centered)", #selector(CanvasView.setWallpaperCentered(_:)))
            add(m, "Set As Desktop Background (Stretched)", #selector(CanvasView.setWallpaperStretched(_:)))
        }

        _ = submenu(main, "Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z")
            add(m, "Repeat", Selector(("redo:")), "y")
            add(m, "Repeat", Selector(("redo:")), "z", [.command, .shift], hidden: true)
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x")
            add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v")
            // Delete/Backspace reach the canvas (or text box) directly, so no key equivalent here.
            add(m, "Clear Selection", #selector(NSText.delete(_:)))
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            add(m, "Copy To…", #selector(CanvasView.copyTo(_:)))
            add(m, "Paste From…", #selector(CanvasView.pasteFrom(_:)))
        }

        _ = submenu(main, "View") { m in
            add(m, "Tool Box", #selector(AppDelegate.toggleToolBox(_:)), "t")
            add(m, "Color Box", #selector(AppDelegate.toggleColorBox(_:)), "l")
            add(m, "Status Bar", #selector(AppDelegate.toggleStatusBar(_:)))
            add(m, "Text Toolbar", #selector(AppDelegate.toggleTextToolbar(_:)))
            m.addItem(.separator())
            let zoom = NSMenu(title: "Zoom")
            add(zoom, "Normal Size", #selector(CanvasView.zoomNormal(_:)), key(NSPageUpFunctionKey), [.control])
            add(zoom, "Normal Size", #selector(CanvasView.zoomNormal(_:)), "0", hidden: true)
            add(zoom, "Large Size", #selector(CanvasView.zoomLarge(_:)), key(NSPageDownFunctionKey), [.control])
            add(zoom, "Custom…", #selector(CanvasView.zoomCustom(_:)))
            zoom.addItem(.separator())
            add(zoom, "Zoom In", #selector(CanvasView.zoomIn(_:)), "=")
            add(zoom, "Zoom In", #selector(CanvasView.zoomIn(_:)), "+", hidden: true)
            add(zoom, "Zoom Out", #selector(CanvasView.zoomOut(_:)), "-")
            zoom.addItem(.separator())
            add(zoom, "Show Grid", #selector(AppDelegate.toggleGrid(_:)), "g")
            let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
            zoomItem.submenu = zoom
            m.addItem(zoomItem)
            add(m, "View Bitmap", #selector(CanvasView.viewBitmap(_:)), "f")
            m.addItem(.separator())
        }

        _ = submenu(main, "Image") { m in
            add(m, "Flip/Rotate…", #selector(CanvasView.flipRotate(_:)), "r")
            add(m, "Stretch/Skew…", #selector(CanvasView.stretchSkew(_:)), "w", [.control])
            add(m, "Invert Colors", #selector(CanvasView.invertColors(_:)), "i")
            add(m, "Attributes…", #selector(CanvasView.imageAttributes(_:)), "e")
            add(m, "Clear Image", #selector(CanvasView.clearImage(_:)), "n", [.command, .shift])
            add(m, "Crop to Selection", #selector(CanvasView.cropToSelection(_:)), "x", [.command, .shift])
            m.addItem(.separator())
            add(m, "Draw Opaque", #selector(AppDelegate.toggleDrawOpaque(_:)))
        }

        _ = submenu(main, "Tools") { m in
            for t in Tool.allCases {
                add(m, t.title, #selector(AppDelegate.chooseTool(_:)), tag: t.rawValue)
            }
            m.addItem(.separator())
            add(m, "Larger Size", #selector(AppDelegate.largerBrush(_:)), "=", [.control])
            add(m, "Larger Size", #selector(AppDelegate.largerBrush(_:)), "+", [.control], hidden: true)
            add(m, "Larger Size", #selector(AppDelegate.largerBrush(_:)), "+", [.control, .shift], hidden: true)
            add(m, "Smaller Size", #selector(AppDelegate.smallerBrush(_:)), "-", [.control])
        }

        _ = submenu(main, "Colors") { m in
            add(m, "Edit Colors…", #selector(AppDelegate.editColors(_:)))
            add(m, "Swap Colors", #selector(AppDelegate.swapColors(_:)), "x", [.command, .option])
        }

        let window = submenu(main, "Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
            m.addItem(.separator())
            add(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = window

        let help = submenu(main, "Help") { m in
            add(m, "Help Topics", #selector(AppDelegate.showHelp(_:)), "?")
            add(m, "About Paint", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        }
        NSApp.helpMenu = help

        return main
    }
}
