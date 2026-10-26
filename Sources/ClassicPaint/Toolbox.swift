import AppKit

/// The 2×8 tool buttons with the tool options box underneath.
final class ToolboxView: NSView, NSViewToolTipOwner {
    static let width: CGFloat = 56
    private let cell: CGFloat = 25
    private let state = PaintState.shared
    var onHover: ((String?) -> Void)?

    private enum Options { case none, transparency, eraser, magnifier, brush, airbrush, lineWidth, fillStyle }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: .paintStateChanged, object: nil)
        for t in Tool.allCases { addToolTip(buttonRect(t), owner: self, userData: nil) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func stateChanged() { needsDisplay = true }

    private func buttonRect(_ t: Tool) -> NSRect {
        let i = t.rawValue
        return NSRect(x: 3 + CGFloat(i % 2) * cell, y: 4 + CGFloat(i / 2) * cell, width: cell, height: cell)
    }

    private var optionsBox: NSRect { NSRect(x: 6, y: 4 + 8 * cell + 6, width: 44, height: 70) }

    private func tool(at p: NSPoint) -> Tool? { Tool.allCases.first { buttonRect($0).contains(p) } }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tool(at: point)?.title ?? ""
    }

    override func mouseMoved(with e: NSEvent) {
        onHover?(tool(at: convert(e.locationInWindow, from: nil))?.help)
    }

    override func mouseExited(with e: NSEvent) { onHover?(nil) }

    // MARK: Options

    private var options: Options {
        switch state.tool {
        case .select, .freeSelect, .text: return .transparency
        case .eraser: return .eraser
        case .magnifier: return .magnifier
        case .brush: return .brush
        case .airbrush: return .airbrush
        case .line, .curve: return .lineWidth
        case .rectangle, .polygon, .ellipse, .roundedRect: return .fillStyle
        default: return .none
        }
    }

    private func rows(_ r: NSRect, _ n: Int) -> [NSRect] {
        let h = r.height / CGFloat(n)
        return (0..<n).map { NSRect(x: r.minX, y: r.minY + CGFloat($0) * h, width: r.width, height: h).integral }
    }

    private func optionRects() -> [NSRect] {
        let b = optionsBox.insetBy(dx: 3, dy: 3)
        switch options {
        case .none: return []
        case .transparency: return rows(b, 2)
        case .eraser, .magnifier: return rows(b, 4)
        case .brush:
            let w = b.width / 3, h = b.height / 4
            return (0..<12).map { NSRect(x: b.minX + CGFloat($0 % 3) * w, y: b.minY + CGFloat($0 / 3) * h, width: w, height: h).integral }
        case .airbrush:
            let top = NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height * 0.45)
            return [NSRect(x: top.minX, y: top.minY, width: top.width / 2, height: top.height).integral,
                    NSRect(x: top.midX, y: top.minY, width: top.width / 2, height: top.height).integral,
                    NSRect(x: b.minX, y: top.maxY, width: b.width, height: b.height - top.height).integral]
        case .lineWidth: return rows(b, 5)
        case .fillStyle: return rows(b, 3)
        }
    }

    private var selectedOption: Int {
        get {
            switch options {
            case .none: return -1
            case .transparency: return state.transparentSelection ? 1 : 0
            case .eraser: return state.eraserIndex
            case .magnifier: return state.magnifierIndex
            case .brush: return state.brushIndex
            case .airbrush: return state.airbrushIndex
            case .lineWidth: return state.lineWidth - 1
            case .fillStyle: return state.fillStyle
            }
        }
        set {
            switch options {
            case .none: break
            case .transparency: state.transparentSelection = newValue == 1
            case .eraser: state.eraserIndex = newValue
            case .magnifier: state.magnifierIndex = newValue
            case .brush: state.brushIndex = newValue
            case .airbrush: state.airbrushIndex = newValue
            case .lineWidth: state.lineWidth = newValue + 1
            case .fillStyle: state.fillStyle = newValue
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Classic.face.setFill()
        bounds.fill()
        for t in Tool.allCases {
            let r = buttonRect(t)
            let on = t == state.tool
            if on {
                Classic.pressed.setFill()
                r.fill()
                Classic.sunken(r)
            } else {
                Classic.raised(r)
            }
            let o: CGFloat = on ? 5 : 4
            PixelArt.icon(t).draw(in: NSRect(x: r.minX + o, y: r.minY + o, width: 16, height: 16), from: .zero,
                                  operation: .sourceOver, fraction: 1, respectFlipped: true,
                                  hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        Classic.sunken(optionsBox)
        let selected = selectedOption
        for (i, r) in optionRects().enumerated() {
            let on = i == selected
            if on {
                Classic.navy.setFill()
                r.fill()
            }
            drawOption(i, in: r, color: on ? .white : .black)
        }
    }

    private func dot(_ x: CGFloat, _ y: CGFloat, _ c: NSColor) {
        c.setFill()
        NSRect(x: x, y: y, width: 1, height: 1).fill()
    }

    private func drawOption(_ i: Int, in r: NSRect, color: NSColor) {
        let cx = r.midX.rounded(.down), cy = r.midY.rounded(.down)
        switch options {
        case .none:
            break
        case .transparency:
            let pic = NSRect(x: cx - 14, y: cy - 9, width: 28, height: 18)
            if i == 0 {
                NSColor.white.setFill()
                pic.fill()
                NSColor.black.setStroke()
                NSBezierPath(rect: pic.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
            NSColor(srgbRed: 0, green: 0.5, blue: 0.5, alpha: 1).setFill()
            NSRect(x: pic.minX + 4, y: pic.minY + 4, width: 10, height: 10).fill()
            NSColor.red.setFill()
            NSBezierPath(ovalIn: NSRect(x: pic.minX + 11, y: pic.minY + 5, width: 12, height: 10)).fill()
        case .eraser:
            let s = CGFloat(PaintState.eraserSizes[i])
            color.setFill()
            NSRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s).fill()
        case .magnifier:
            let label = "\(Int(PaintState.magnifierLevels[i]))x" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: color]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        case .brush:
            let shape = PaintState.brushShapes[i]
            let stamp: Stamp
            switch shape.kind {
            case 0: stamp = .disk(shape.size)
            case 1: stamp = .square(shape.size)
            case 2: stamp = .slash(shape.size)
            default: stamp = .backslash(shape.size)
            }
            for o in stamp.offsets { dot(cx + CGFloat(o.0), cy + CGFloat(o.1), color) }
        case .airbrush:
            let radius = Double(PaintState.airbrushRadii[i])
            var seed: UInt32 = 12345
            func rnd() -> Double { seed = seed &* 1_103_515_245 &+ 12345; return Double((seed >> 8) & 0xFFFF) / 65535 }
            for _ in 0..<Int(radius * 3) {
                let a = rnd() * 2 * .pi, d = radius * rnd().squareRoot()
                dot(cx + CGFloat((d * cos(a)).rounded()), cy + CGFloat((d * sin(a)).rounded()), color)
            }
        case .lineWidth:
            color.setFill()
            NSRect(x: r.minX + 4, y: cy - CGFloat(i / 2), width: r.width - 8, height: CGFloat(i + 1)).fill()
        case .fillStyle:
            let box = NSRect(x: cx - 14, y: cy - 6, width: 28, height: 12)
            if i > 0 {
                Classic.shadow.setFill()
                box.fill()
            }
            if i < 2 {
                color.setStroke()
                NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }

    // MARK: Clicks

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let t = tool(at: p) {
            state.selectTool(t)
            onHover?(t.help)
            return
        }
        if let i = optionRects().firstIndex(where: { $0.contains(p) }) { selectedOption = i }
    }
}

/// The current colors and the 28-color palette.
final class ColorBoxView: NSView {
    static let height: CGFloat = 44
    private let state = PaintState.shared

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: .paintStateChanged, object: nil)
        toolTip = "Click: foreground color · Right-click: background color · Double-click: edit color"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func stateChanged() { needsDisplay = true }

    private var currentRect: NSRect { NSRect(x: 6, y: 6, width: 32, height: 32) }

    private func swatchRect(_ i: Int) -> NSRect {
        NSRect(x: 44 + CGFloat(i % 14) * 16, y: 6 + CGFloat(i / 14) * 16, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        Classic.face.setFill()
        bounds.fill()
        Classic.box(0, 0, bounds.width, 1, Classic.light)

        let cur = currentRect
        Classic.pressed.setFill()
        cur.fill()
        Classic.sunken(cur)
        let back = NSRect(x: cur.minX + 14, y: cur.minY + 14, width: 13, height: 13)
        let front = NSRect(x: cur.minX + 5, y: cur.minY + 5, width: 13, height: 13)
        for (r, c) in [(back, state.secondary), (front, state.primary)] {
            Classic.raised(r)
            c.nsColor.setFill()
            r.insetBy(dx: 2, dy: 2).fill()
        }

        for (i, c) in state.palette.enumerated() {
            let r = swatchRect(i)
            Classic.sunken(r)
            c.nsColor.setFill()
            r.insetBy(dx: 2, dy: 2).fill()
        }
    }

    private func swatch(at e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return state.palette.indices.first { swatchRect($0).contains(p) }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if currentRect.contains(p) {
            (state.primary, state.secondary) = (state.secondary, state.primary)
            return
        }
        guard let i = swatch(at: e) else { return }
        if e.modifierFlags.contains(.control) {
            state.secondary = state.palette[i]
        } else if e.clickCount >= 2 {
            state.editColor(index: i)
        } else {
            state.primary = state.palette[i]
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        if let i = swatch(at: e) { state.secondary = state.palette[i] }
    }
}

final class StatusBarView: NSView {
    static let height: CGFloat = 22
    static let defaultHelp = "For Help, click Help Topics on the Help Menu."

    var help = StatusBarView.defaultHelp { didSet { if help != oldValue { needsDisplay = true } } }
    var position = "" { didSet { if position != oldValue { needsDisplay = true } } }
    var selectionSize = "" { didSet { if selectionSize != oldValue { needsDisplay = true } } }
    var imageSize = "" { didSet { if imageSize != oldValue { needsDisplay = true } } }
    var zoom = "" { didSet { if zoom != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Classic.face.setFill()
        bounds.fill()
        Classic.box(0, 0, bounds.width, 1, Classic.light)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black]
        let widths: [CGFloat] = [110, 110, 120, 80]
        let values = [position, selectionSize, imageSize, zoom]
        var x = bounds.width - widths.reduce(0, +) - 4
        let helpRect = NSRect(x: 2, y: 3, width: x - 6, height: bounds.height - 5)
        Classic.thinSunken(helpRect)
        (help as NSString).draw(in: helpRect.insetBy(dx: 4, dy: 2), withAttributes: attrs)
        for (w, v) in zip(widths, values) {
            let r = NSRect(x: x, y: 3, width: w - 2, height: bounds.height - 5)
            Classic.thinSunken(r)
            (v as NSString).draw(in: r.insetBy(dx: 4, dy: 2), withAttributes: attrs)
            x += w
        }
    }
}
