#if DEBUG
import AppKit

/// Debug-only smoke test: `CLASSIC_PAINT_SELFTEST=/out/dir ClassicPaint` drives the
/// first window with real mouse/keyboard events and writes window.png + image.png.
enum SelfTest {
    private static var steps: [() -> Void] = []

    static func runIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["CLASSIC_PAINT_SELFTEST"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { start(out) }
    }

    private static func start(_ out: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard let wc = NSApp.windows.compactMap({ $0.windowController as? PaintWindowController }).first,
              let window = wc.window else { print("SELFTEST: no window"); exit(2) }
        window.makeKeyAndOrderFront(nil)
        if let shot = ProcessInfo.processInfo.environment["CLASSIC_PAINT_TEST_ATTRIBUTES"] {
            UserDefaults.standard.removeObject(forKey: "AttributesUnit")
            let form = AttributesForm(width: 800, height: 600)
            let radios = form.view.subviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSButton }
            func click(_ title: String) { radios.first { $0.title == title }!.performClick(nil) }
            func fields() -> String { "\(form.widthField.stringValue) x \(form.heightField.stringValue)" }
            print("ATTR pixels: \(fields())")
            click("Inches"); print("ATTR inches: \(fields())")
            click("Cm"); print("ATTR cm: \(fields())")
            click("Pixels"); print("ATTR back to pixels: \(fields()) result=\(form.result()!)")
            click("Inches"); form.widthField.stringValue = "2"; form.heightField.stringValue = "1,5"
            print("ATTR 2in x 1,5in -> \(form.result()!)")
            click("Cm"); print("ATTR shown in cm: \(fields()) result=\(form.result()!)")
            form.widthField.stringValue = "abc"; print("ATTR invalid -> \(String(describing: form.result()))")
            let img = Bitmap(width: 555, height: 266, fill: .white)
            for uti in ["public.png", "com.microsoft.bmp", "public.jpeg", "public.tiff"] {
                let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(img.encoded(as: uti)! as CFData, nil)!, 0, nil) as! [CFString: Any]
                let dpi = props[kCGImagePropertyDPIWidth] as? Double ?? 0
                print("ATTR \(uti) dpi=\(dpi) → \(String(format: "%.2f", 555 / dpi * 2.54)) cm wide")
            }
            print("ATTR remembered unit=\(UserDefaults.standard.integer(forKey: "AttributesUnit"))")
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            form.widthField.stringValue = "21.17"
            let box = NSView(frame: NSRect(origin: .zero, size: form.view.fittingSize).insetBy(dx: -16, dy: -16))
            form.view.frame = NSRect(origin: NSPoint(x: 16, y: 16), size: form.view.fittingSize)
            box.addSubview(form.view)
            host.appearance = NSAppearance(named: .aqua)
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            host.contentView = box
            box.layoutSubtreeIfNeeded()
            let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds)!
            box.cacheDisplay(in: box.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
            exit(0)
        }
        if ProcessInfo.processInfo.environment["CLASSIC_PAINT_DUMP_MENU"] != nil {
            func dump(_ m: NSMenu, _ indent: String) {
                for i in m.items where !i.isSeparatorItem {
                    var k = i.keyEquivalent.unicodeScalars.map { $0.value < 0x7F ? String($0) : String(format: "U+%04X", $0.value) }.joined()
                    let f = i.keyEquivalentModifierMask
                    if !k.isEmpty { k = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + k }
                    print("MENU \(indent)\(i.title) \(k)\(i.isHidden ? " (hidden)" : "")")
                    if let sub = i.submenu { dump(sub, indent + "  ") }
                }
            }
            dump(NSApp.mainMenu!, "")
            exit(0)
        }
        let canvas = wc.canvas
        let state = PaintState.shared

        func pt(_ x: Int, _ y: Int) -> NSPoint {
            canvas.convert(NSPoint(x: canvas.margin + CGFloat(x) + 0.5, y: canvas.margin + CGFloat(y) + 0.5), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ x: Int, _ y: Int, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) {
            let e = NSEvent.mouseEvent(with: type, location: pt(x, y), modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            // Direct dispatch: a launched-from-shell app may not be allowed to become active,
            // and AppKit swallows first clicks on inactive windows.
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: e)
            case .leftMouseDragged: canvas.mouseDragged(with: e)
            case .leftMouseUp: canvas.mouseUp(with: e)
            case .rightMouseDown: canvas.rightMouseDown(with: e)
            case .rightMouseDragged: canvas.rightMouseDragged(with: e)
            default: canvas.rightMouseUp(with: e)
            }
        }
        func drag(_ pts: [(Int, Int)], right: Bool = false, _ mods: NSEvent.ModifierFlags = []) {
            let (down, dragged, up): (NSEvent.EventType, NSEvent.EventType, NSEvent.EventType) =
                right ? (.rightMouseDown, .rightMouseDragged, .rightMouseUp) : (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
            steps.append { mouse(down, pts[0].0, pts[0].1, mods) }
            for p in pts.dropFirst() { steps.append { mouse(dragged, p.0, p.1, mods) } }
            steps.append { mouse(up, pts.last!.0, pts.last!.1, mods) }
        }
        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            steps.append {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                NSApp.postEvent(e, atStart: false)
            }
        }
        func act(_ f: @escaping () -> Void) { steps.append(f) }

        // Drag the bottom-right canvas handle out to 900×700
        drag([(800, 600), (850, 650), (900, 700)])
        act { print("SELFTEST: canvas after handle drag \(canvas.bitmap.width)x\(canvas.bitmap.height)") }
        // Pencil scribble
        act { state.selectTool(.pencil) }
        drag([(20, 20), (60, 40), (100, 20), (140, 60)])
        // Thick brush, right button (background color = yellow)
        act { state.secondary = rgb(255, 255, 0); state.selectTool(.brush); state.brushIndex = 0 }
        drag([(20, 100), (80, 130), (160, 100)], right: true)
        // Filled rectangle (outline black, fill yellow), line width 3
        act { state.selectTool(.rectangle); state.fillStyle = 1; state.lineWidth = 3 }
        drag([(200, 20), (260, 60), (300, 90)])
        // Shift-constrained circle, red outline
        act { state.primary = rgb(255, 0, 0); state.selectTool(.ellipse); state.fillStyle = 0 }
        drag([(320, 20), (360, 50), (400, 70)], .shift)
        // Rounded rect, fill only, blue
        act { state.primary = rgb(0, 0, 255); state.selectTool(.roundedRect); state.fillStyle = 2 }
        drag([(440, 20), (520, 80)])
        // Line at 45° with shift
        act { state.primary = .black; state.selectTool(.line); state.lineWidth = 2 }
        drag([(20, 180), (90, 230), (120, 250)], .shift)
        // Curve: line then two bends
        act { state.selectTool(.curve) }
        drag([(200, 200), (350, 200)])
        drag([(240, 140)])
        drag([(320, 260)])
        // Polygon: triangle closed with double-click, outline + fill
        act { state.selectTool(.polygon); state.fillStyle = 1; state.secondary = rgb(0, 255, 0) }
        drag([(420, 150), (500, 150)])
        drag([(460, 230)])
        act { mouse(.leftMouseDown, 460, 230, clicks: 2) }
        act { mouse(.leftMouseUp, 460, 230, clicks: 2) }
        // Flood fill inside the rectangle with cyan
        act { state.primary = rgb(0, 255, 255); state.selectTool(.fill) }
        drag([(250, 50)])
        // Airbrush
        act { state.primary = rgb(255, 0, 255); state.selectTool(.airbrush); state.airbrushIndex = 2 }
        drag([(60, 300), (70, 305), (80, 310)])
        // Text
        act { state.primary = .black; state.selectTool(.text); state.fontSize = 20 }
        drag([(200, 300), (420, 340)])
        for (c, code) in [("H", UInt16(4)), ("i", UInt16(34)), ("!", UInt16(18))] { key(c, code) }
        act { state.selectTool(.select) }   // commits the text
        // Select a block and move it (Ctrl+drag would copy)
        drag([(10, 10), (150, 70)])
        drag([(50, 30), (80, 380), (90, 420)])
        // Undo the move, redo it, invert the selection
        act { print("SELFTEST: before undo name=\(canvas.document.undoManager!.undoActionName)") }
        act { canvas.document.undoManager?.undo() }
        act { print("SELFTEST: after undo selection=\(canvas.selection != nil) redo=\(canvas.document.undoManager!.redoActionName)") }
        act { canvas.document.undoManager?.redo() }
        act { state.selectTool(.select) }
        drag([(10, 350), (160, 440)])
        act { canvas.invertColors(nil) }
        act { canvas.commitSelection() }
        // Free-form select, then Option-drag a copy to the right
        act { state.selectTool(.freeSelect) }
        drag([(420, 140), (520, 140), (520, 245), (420, 245), (420, 140)])
        drag([(470, 200), (600, 200), (650, 220)], .option)
        // Eraser (white square path) and color eraser (red -> white on the circle)
        act { state.secondary = .white; state.primary = rgb(255, 0, 0); state.selectTool(.eraser); state.eraserIndex = 3 }
        drag([(300, 120), (520, 120)])
        drag([(320, 40), (400, 40)], right: true)
        act { state.primary = .black }
        // Formats round trip
        act {
            for t in PaintDocument.fileTypes {
                let data = try? canvas.document.data(ofType: t.identifier)
                let back = data.flatMap(Bitmap.load)
                print("SELFTEST: \(t.preferredFilenameExtension!) bytes=\(data?.count ?? 0) size=\(back.map { "\($0.width)x\($0.height)" } ?? "nil")")
            }
        }
        act {
            let dir = URL(fileURLWithPath: out)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window.png"))
            }
            try? canvas.flattened().encoded(as: "public.png")?.write(to: dir.appendingPathComponent("image.png"))
            state.showGrid = true
            state.selectTool(.brush)
            canvas.setZoom(6, around: CGPoint(x: 330, y: 30))
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("zoom.png"))
            }
            let um = canvas.document.undoManager!
            let windowsBefore = NSApp.windows.filter { $0.windowController is PaintWindowController }.count
            let file = dir.appendingPathComponent("image.png")
            print("SELFTEST: undo=\(um.undoActionName) canUndo=\(um.canUndo) edited=\(canvas.document.isDocumentEdited) title=\(window.title)")
            canvas.document.updateChangeCount(.changeCleared)
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { doc, _, err in
                let windows = NSApp.windows.filter { $0.windowController is PaintWindowController }
                print("SELFTEST: open err=\(String(describing: err)) windows \(windowsBefore)->\(windows.count) sameDoc=\(canvas.document === doc) title=\(window.title) size=\(canvas.bitmap.width)x\(canvas.bitmap.height) docs=\(NSDocumentController.shared.documents.count)")
                exit(0)
            }
        }
        runNext()
    }

    private static func runNext() {
        guard !steps.isEmpty else { return }
        steps.removeFirst()()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { runNext() }
    }
}
#endif
