import AppKit

extension Notification.Name {
    static let paintStateChanged = Notification.Name("PaintStateChanged")
}

enum Tool: Int, CaseIterable {
    case freeSelect, select, eraser, fill, pick, magnifier, pencil, brush
    case airbrush, text, line, curve, rectangle, polygon, ellipse, roundedRect

    var title: String {
        ["Free-Form Select", "Select", "Eraser/Color Eraser", "Fill With Color", "Pick Color", "Magnifier",
         "Pencil", "Brush", "Airbrush", "Text", "Line", "Curve", "Rectangle", "Polygon", "Ellipse",
         "Rounded Rectangle"][rawValue]
    }

    var help: String {
        switch self {
        case .freeSelect: return "Selects a free-form part of the picture to move, copy, or edit."
        case .select: return "Selects a rectangular part of the picture to move, copy, or edit."
        case .eraser: return "Erases part of the picture. Right-drag replaces the foreground color with the background color."
        case .fill: return "Fills an area with the current drawing color."
        case .pick: return "Picks up a color from the picture for drawing."
        case .magnifier: return "Changes the magnification."
        case .pencil: return "Draws a free-form line one pixel wide."
        case .brush: return "Draws using a brush with the selected shape and size."
        case .airbrush: return "Draws using an airbrush of the selected size."
        case .text: return "Inserts text into the picture."
        case .line: return "Draws a straight line with the selected line width."
        case .curve: return "Draws a curved line with the selected line width."
        case .rectangle: return "Draws a rectangle with the selected fill style."
        case .polygon: return "Draws a polygon with the selected fill style."
        case .ellipse: return "Draws an ellipse with the selected fill style."
        case .roundedRect: return "Draws a rounded rectangle with the selected fill style."
        }
    }

    var usesLineWidth: Bool { [.line, .curve, .rectangle, .polygon, .ellipse, .roundedRect].contains(self) }
}

/// Tool, color and option state shared by every window, like Paint's single toolbox.
final class PaintState: NSObject {
    static let shared = PaintState()

    /// The 28-color Windows palette.
    static let defaultPalette: [Pixel] = [
        rgb(0, 0, 0), rgb(128, 128, 128), rgb(128, 0, 0), rgb(128, 128, 0), rgb(0, 128, 0), rgb(0, 128, 128),
        rgb(0, 0, 128), rgb(128, 0, 128), rgb(128, 128, 64), rgb(0, 64, 64), rgb(0, 128, 255), rgb(0, 64, 128),
        rgb(128, 0, 255), rgb(128, 64, 0),
        rgb(255, 255, 255), rgb(192, 192, 192), rgb(255, 0, 0), rgb(255, 255, 0), rgb(0, 255, 0), rgb(0, 255, 255),
        rgb(0, 0, 255), rgb(255, 0, 255), rgb(255, 255, 128), rgb(0, 255, 128), rgb(128, 255, 255), rgb(128, 128, 255),
        rgb(255, 0, 128), rgb(255, 128, 64),
    ]

    /// (shape, size): 0 round, 1 square, 2 slash, 3 backslash.
    static let brushShapes: [(kind: Int, size: Int)] = [
        (0, 7), (0, 4), (0, 1), (1, 8), (1, 5), (1, 2), (2, 8), (2, 5), (2, 2), (3, 8), (3, 5), (3, 2),
    ]
    static let eraserSizes = [4, 6, 8, 10]
    static let airbrushRadii = [4, 8, 12]
    static let magnifierLevels: [CGFloat] = [1, 2, 6, 8]

    private let defaults = UserDefaults.standard

    private(set) var tool: Tool = .pencil
    private(set) var previousTool: Tool = .pencil
    var primary: Pixel = .black { didSet { changed() } }
    var secondary: Pixel = .white { didSet { changed() } }
    var palette = PaintState.defaultPalette { didSet { changed() } }

    var eraserIndex = 1 { didSet { changed() } }
    var brushIndex = 1 { didSet { changed() } }
    var airbrushIndex = 0 { didSet { changed() } }
    var magnifierIndex = 2 { didSet { changed() } }
    var lineWidth = 1 { didSet { changed() } }
    /// 0 outline, 1 outline with background-color fill, 2 fill without outline.
    var fillStyle = 0 { didSet { changed() } }
    /// "Draw Opaque" off: background-colored pixels of selections and text boxes are transparent.
    var transparentSelection = false { didSet { changed() } }

    var fontFamily = "Arial" { didSet { changed() } }
    var fontSize: CGFloat = 16 { didSet { changed() } }
    var bold = false { didSet { changed() } }
    var italic = false { didSet { changed() } }
    var underline = false { didSet { changed() } }

    var showGrid = false { didSet { changed() } }
    var showToolBox: Bool { get { flag("ShowToolBox") } set { setFlag("ShowToolBox", newValue) } }
    var showColorBox: Bool { get { flag("ShowColorBox") } set { setFlag("ShowColorBox", newValue) } }
    var showStatusBar: Bool { get { flag("ShowStatusBar") } set { setFlag("ShowStatusBar", newValue) } }
    var showTextToolbar: Bool { get { flag("ShowTextToolbar") } set { setFlag("ShowTextToolbar", newValue) } }

    var defaultImageSize: (Int, Int) {
        get {
            let w = defaults.integer(forKey: "DefaultWidth"), h = defaults.integer(forKey: "DefaultHeight")
            return (w > 0 ? w : 800, h > 0 ? h : 600)
        }
        set {
            defaults.set(newValue.0, forKey: "DefaultWidth")
            defaults.set(newValue.1, forKey: "DefaultHeight")
        }
    }

    private func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    private func setFlag(_ key: String, _ value: Bool) { defaults.set(value, forKey: key); changed() }

    func changed() { NotificationCenter.default.post(name: .paintStateChanged, object: self) }

    // MARK: Tools

    func selectTool(_ t: Tool) {
        guard t != tool else { return }
        let temporary: Set<Tool> = [.pick, .magnifier]
        if temporary.contains(t) && !temporary.contains(tool) { previousTool = tool }
        tool = t
        changed()
    }

    /// Pick Color and Magnifier hand control back to the tool used before them.
    func restorePreviousTool() { selectTool(previousTool) }

    var brushStamp: Stamp {
        let s = PaintState.brushShapes[brushIndex]
        switch s.kind {
        case 0: return .disk(s.size)
        case 1: return .square(s.size)
        case 2: return .slash(s.size)
        default: return .backslash(s.size)
        }
    }
    var eraserSize: Int { PaintState.eraserSizes[eraserIndex] }
    var airbrushRadius: Int { PaintState.airbrushRadii[airbrushIndex] }
    var magnifierLevel: CGFloat { PaintState.magnifierLevels[magnifierIndex] }

    /// Ctrl+Plus / Ctrl+Minus: next size of the current tool.
    func adjustSize(_ delta: Int) {
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
        switch tool {
        case .brush:
            let family = brushIndex / 3, pos = clamp(brushIndex % 3 - delta, 0, 2)
            brushIndex = family * 3 + pos
        case .eraser: eraserIndex = clamp(eraserIndex + delta, 0, 3)
        case .airbrush: airbrushIndex = clamp(airbrushIndex + delta, 0, 2)
        case .text: fontSize = CGFloat(clamp(Int(fontSize) + 2 * delta, 6, 400))
        case _ where tool.usesLineWidth: lineWidth = clamp(lineWidth + delta, 1, 5)
        default: NSSound.beep()
        }
    }

    // MARK: Text

    func textFont() -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: fontFamily, traits: traits, weight: 5, size: fontSize)
            ?? NSFont(name: fontFamily, size: fontSize)
            ?? .systemFont(ofSize: fontSize)
    }

    // MARK: Edit Colors

    private var editingIndex: Int?

    /// Opens the color panel for a palette slot (or the foreground color).
    func editColor(index: Int?) {
        editingIndex = index
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.color = (index.map { palette[$0] } ?? primary).nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ panel: NSColorPanel) {
        let c = Pixel(panel.color)
        if let i = editingIndex { palette[i] = c }
        primary = c
    }
}
