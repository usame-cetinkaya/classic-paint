import AppKit

/// Text box editor. Keeps its own undo history so typing doesn't mix with picture undo.
final class PaintTextView: NSTextView {
    private let ownUndo = UndoManager()
    var onEscape: (() -> Void)?

    override var undoManager: UndoManager? { ownUndo }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Bold / Italic / Underline with ⌘ or Ctrl, as in Paint's text toolbar.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == [.command] || mods == [.control], let c = e.charactersIgnoringModifiers?.lowercased() {
            let s = PaintState.shared
            switch c {
            case "b": s.bold.toggle(); return true
            case "i": s.italic.toggle(); return true
            case "u": s.underline.toggle(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: e)
    }

    @objc func undo(_ sender: Any?) { ownUndo.undo() }
    @objc func redo(_ sender: Any?) { ownUndo.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return ownUndo.canUndo
        case #selector(redo(_:)): return ownUndo.canRedo
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

/// The floating "Fonts" toolbar shown while typing text.
final class FontBar: NSPanel, NSWindowDelegate, NSComboBoxDelegate {
    static let shared = FontBar()

    let family = NSPopUpButton()
    let size = NSComboBox()
    let bold = NSButton(title: "B", target: nil, action: nil)
    let italic = NSButton(title: "I", target: nil, action: nil)
    let underline = NSButton(title: "U", target: nil, action: nil)

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 36),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        title = "Fonts"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        delegate = self

        family.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        family.target = self
        family.action = #selector(familyChanged)
        size.addItems(withObjectValues: [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72].map(String.init))
        size.numberOfVisibleItems = 12
        size.target = self
        size.action = #selector(sizeEntered)
        size.delegate = self
        size.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for (b, font, action) in [(bold, NSFont.boldSystemFont(ofSize: 13), #selector(boldChanged)),
                                  (italic, NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask), #selector(italicChanged)),
                                  (underline, NSFont.systemFont(ofSize: 13), #selector(underlineChanged))] {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .smallSquare
            b.font = font
            b.target = self
            b.action = action
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        underline.attributedTitle = NSAttributedString(string: "U", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                                                               .font: NSFont.systemFont(ofSize: 13)])
        let stack = NSStackView(views: [family, size, bold, italic, underline])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        contentView = stack
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .paintStateChanged, object: nil)
        sync()
    }

    func show(near window: NSWindow?) {
        sync()
        if !isVisible, let w = window {
            setFrameTopLeftPoint(NSPoint(x: w.frame.minX + 70, y: w.frame.maxY - 40))
        }
        orderFront(nil)
    }

    @objc private func sync() {
        let s = PaintState.shared
        if family.titleOfSelectedItem != s.fontFamily { family.selectItem(withTitle: s.fontFamily) }
        // Don't overwrite a size while it is being typed.
        let sizeText = s.fontSize == s.fontSize.rounded() ? String(Int(s.fontSize)) : String(format: "%g", s.fontSize)
        if size.currentEditor() == nil, size.stringValue != sizeText { size.stringValue = sizeText }
        bold.state = s.bold ? .on : .off
        italic.state = s.italic ? .on : .off
        underline.state = s.underline ? .on : .off
    }

    @objc private func familyChanged() {
        if let t = family.titleOfSelectedItem { PaintState.shared.fontFamily = t }
    }

    /// Applies a typed or picked size; `strict` restores the shown size when it is invalid.
    private func applySize(_ text: String?, strict: Bool) {
        let t = (text ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if let v = Double(t), v >= 4, v <= 500 {
            if PaintState.shared.fontSize != CGFloat(v) { PaintState.shared.fontSize = CGFloat(v) }
        } else if strict {
            sync()
        }
    }

    /// Return in the size box.
    @objc private func sizeEntered() { applySize(size.stringValue, strict: true) }

    /// A size picked from the list (the text field isn't updated yet at this point).
    func comboBoxSelectionDidChange(_ notification: Notification) {
        applySize(size.objectValueOfSelectedItem as? String, strict: false)
    }

    /// Typing a size applies it right away, without needing Return.
    func controlTextDidChange(_ obj: Notification) { applySize(size.stringValue, strict: false) }

    func controlTextDidEndEditing(_ obj: Notification) { applySize(size.stringValue, strict: true) }

    // One action per button: setting one style posts a change that refreshes all buttons,
    // so reading the others afterwards would see their old state.
    @objc private func boldChanged() { PaintState.shared.bold = bold.state == .on }
    @objc private func italicChanged() { PaintState.shared.italic = italic.state == .on }
    @objc private func underlineChanged() { PaintState.shared.underline = underline.state == .on }

    func windowWillClose(_ notification: Notification) {
        PaintState.shared.showTextToolbar = false
    }
}

/// View > View Bitmap: the picture alone on a black screen until any key or click.
final class ViewBitmapWindow: NSWindow {
    private static var current: ViewBitmapWindow?

    private final class ImageView: NSView {
        let image: CGImage
        init(image: CGImage) {
            self.image = image
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill()
            dirtyRect.fill()
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = min(1, bounds.width / w, bounds.height / h)
            let r = NSRect(x: ((bounds.width - w * scale) / 2).rounded(), y: ((bounds.height - h * scale) / 2).rounded(),
                           width: w * scale, height: h * scale)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: r)
        }
        override func mouseDown(with event: NSEvent) { window?.close() }
        override func rightMouseDown(with event: NSEvent) { window?.close() }
    }

    static func show(_ image: CGImage) {
        guard let screen = NSScreen.main else { return }
        let w = ViewBitmapWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = ImageView(image: image)
        w.setFrame(screen.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        current = w
    }

    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        close()
        return true
    }
    override func close() {
        super.close()
        ViewBitmapWindow.current = nil
    }
}

/// Help > Help Topics: the keyboard shortcut reference.
enum HelpWindow {
    private static var window: NSWindow?

    static let text = """
    CLASSIC PAINT — KEYBOARD SHORTCUTS

    Every ⌘ shortcut also works with Ctrl, just like on Windows (Ctrl+Z, Ctrl+S, Ctrl+A, …).

    FILE
      New ⌘N   Open ⌘O   Save ⌘S   Save As ⇧⌘S   Print ⌘P   Close ⌘W   Quit ⌘Q

    EDIT
      Undo ⌘Z          Repeat ⌘Y (or ⇧⌘Z)
      Cut ⌘X   Copy ⌘C   Paste ⌘V
      Clear Selection  Delete / ⌫
      Select All ⌘A

    VIEW
      Tool Box ⌘T      Color Box ⌘L      View Bitmap ⌘F
      Normal Size ⌃Page Up (or ⌘0)     Large Size ⌃Page Down
      Zoom In ⌘=       Zoom Out ⌘-       Show Grid ⌘G (at 400% and above)
      Pinch on the trackpad to zoom freely.

    IMAGE
      Attributes: set Resolution to your screen's pixels per inch once, and
      sizes in cm/inches match a ruler at Normal Size (100%).
      Flip/Rotate ⌘R   Stretch/Skew ⌃W   Invert Colors ⌘I
      Attributes ⌘E    Clear Image ⇧⌘N   Crop to Selection ⇧⌘X

    TOOLS
      Larger brush / line / eraser ⌃+   Smaller ⌃-
      Shift while drawing: straight 45° lines, squares and circles
      Right-click (or Ctrl-click): draw with the background color
      Right-drag with the Eraser: replace the foreground color with the background color
      Esc: cancel the shape you are drawing
      Return: finish a curve or polygon
      Double-click: close a polygon

    SELECTIONS
      Drag to move · Ctrl/Option-drag to copy · Shift-drag to smear
      Drag a handle to stretch · Arrow keys nudge 1 pixel (Shift: 10)
      "Draw Opaque" off: background-colored pixels become transparent

    TEXT
      ⌘B / ⌘I / ⌘U (or Ctrl) toggle bold, italic, underline while typing
      Esc or a click outside the box places the text

    COLORS
      Click a swatch: foreground · Right-click (or Ctrl-click): background
      Double-click a swatch: edit it · Click the color pair: swap
    """

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Paint Help"
        w.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.string = text
        tv.textContainerInset = NSSize(width: 12, height: 12)
        w.contentView = scroll
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

enum Clipboard {
    static var hasImage: Bool {
        NSPasteboard.general.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue,
                                                                     NSPasteboard.PasteboardType.tiff.rawValue])
            || NSImage.canInit(with: .general)
    }

    static func read() -> Bitmap? {
        let pb = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let d = pb.data(forType: type), let rep = NSBitmapImageRep(data: d), let cg = rep.cgImage {
                return Bitmap(cgImage: cg)
            }
        }
        if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return Bitmap(cgImage: cg)
        }
        return nil
    }

    static func write(_ bitmap: Bitmap) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = bitmap.encoded(as: "public.png") { pb.setData(png, forType: .png) }
        if let tiff = NSBitmapImageRep(cgImage: bitmap.image).tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }
}
