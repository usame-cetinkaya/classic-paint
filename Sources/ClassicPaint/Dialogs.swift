import AppKit

/// Paint's small modal dialogs, built on NSAlert.
enum Dialogs {
    enum FlipRotate {
        case flipHorizontal, flipVertical
        case rotate(Int)
    }

    private final class RadioTarget: NSObject {
        @objc func pick(_ sender: NSButton) {}
    }

    private static let radioTarget = RadioTarget()

    /// Radio buttons that share a superview form one group.
    private static func radio(_ title: String, on: Bool = false) -> NSButton {
        let b = NSButton(radioButtonWithTitle: title, target: radioTarget, action: #selector(RadioTarget.pick(_:)))
        b.state = on ? .on : .off
        return b
    }

    private static func field(_ value: String) -> NSTextField {
        let f = NSTextField(string: value)
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return f
    }

    private static func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private static func run(_ title: String, _ accessory: NSView, focus: NSView? = nil) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        accessory.frame = NSRect(origin: .zero, size: accessory.fittingSize)
        a.accessoryView = accessory
        if let focus { a.window.initialFirstResponder = focus }
        return a.runModal() == .alertFirstButtonReturn
    }

    static func attributes(width: Int, height: Int) -> (Int, Int)? {
        let form = AttributesForm(width: width, height: height)
        guard run("Attributes", form.view, focus: form.widthField) else { return nil }
        return form.result()
    }

    static func flipRotate() -> FlipRotate? {
        let flipH = radio("Flip horizontal", on: true), flipV = radio("Flip vertical"), rotate = radio("Rotate by angle")
        let r90 = radio("90°", on: true), r180 = radio("180°"), r270 = radio("270°")
        let angles = NSStackView(views: [r90, r180, r270])
        angles.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        let main = NSStackView(views: [flipH, flipV, rotate])
        main.orientation = .vertical
        main.alignment = .leading
        let stack = NSStackView(views: [main, angles])
        stack.orientation = .vertical
        stack.alignment = .leading
        guard run("Flip and Rotate", stack) else { return nil }
        if flipH.state == .on { return .flipHorizontal }
        if flipV.state == .on { return .flipVertical }
        return .rotate(r90.state == .on ? 1 : r180.state == .on ? 2 : 3)
    }

    struct StretchSkew {
        var stretchX: Double, stretchY: Double, skewX: Double, skewY: Double
    }

    static func stretchSkew() -> StretchSkew? {
        let sx = field("100"), sy = field("100"), kx = field("0"), ky = field("0")
        let grid = NSGridView(views: [
            [label("Stretch"), NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Horizontal:"), sx, label("%")],
            [label("Vertical:"), sy, label("%")],
            [label("Skew"), NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Horizontal:"), kx, label("degrees")],
            [label("Vertical:"), ky, label("degrees")],
        ])
        grid.rowSpacing = 6
        guard run("Stretch and Skew", grid, focus: sx),
              let a = Double(sx.stringValue), let b = Double(sy.stringValue),
              let c = Double(kx.stringValue), let d = Double(ky.stringValue),
              (1...500).contains(a), (1...500).contains(b), (-89...89).contains(c), (-89...89).contains(d) else { return nil }
        return StretchSkew(stretchX: a, stretchY: b, skewX: c, skewY: d)
    }

    static func customZoom(current: CGFloat) -> CGFloat? {
        let levels: [CGFloat] = [1, 2, 4, 6, 8]
        let buttons = levels.map { radio("\(Int($0 * 100))%", on: abs($0 - current) < 0.001) }
        if !buttons.contains(where: { $0.state == .on }) { buttons[0].state = .on }
        let row = NSStackView(views: buttons)
        let stack = NSStackView(views: [label("Current zoom: \(Int((current * 100).rounded()))%"), row])
        stack.orientation = .vertical
        stack.alignment = .leading
        guard run("Custom Zoom", stack), let i = buttons.firstIndex(where: { $0.state == .on }) else { return nil }
        return levels[i]
    }

    /// Yes = enlarge, No = keep the size, nil = cancel.
    static func confirmEnlarge() -> Bool? {
        let a = NSAlert()
        a.messageText = "The image in the clipboard is larger than the bitmap."
        a.informativeText = "Would you like the bitmap enlarged?"
        a.addButton(withTitle: "Yes")
        a.addButton(withTitle: "No")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }
}

/// Image > Attributes: width and height in inches, centimeters or pixels,
/// converted at 96 dots per inch like Windows Paint.
final class AttributesForm: NSObject {
    enum Unit: Int, CaseIterable {
        case inches, centimeters, pixels

        var title: String { ["Inches", "Cm", "Pixels"][rawValue] }
        var pixelsPerUnit: Double { [AttributesForm.dpi, AttributesForm.dpi / 2.54, 1][rawValue] }
    }

    static let dpi = 96.0
    private static let unitKey = "AttributesUnit"

    let widthField = NSTextField()
    let heightField = NSTextField()
    private(set) var view = NSView()
    private var unit: Unit
    private var buttons: [NSButton] = []
    /// Exact sizes, so switching units back and forth never changes them by rounding.
    private var pixels: (w: Int, h: Int)
    private var shown: (w: String, h: String) = ("", "")

    init(width: Int, height: Int) {
        pixels = (width, height)
        unit = (UserDefaults.standard.object(forKey: AttributesForm.unitKey) as? Int).flatMap(Unit.init) ?? .pixels
        super.init()
        for f in [widthField, heightField] {
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        buttons = Unit.allCases.map { u in
            let b = NSButton(radioButtonWithTitle: u.title, target: self, action: #selector(unitChanged(_:)))
            b.tag = u.rawValue
            b.state = u == unit ? .on : .off
            return b
        }
        let size = NSGridView(views: [[NSTextField(labelWithString: "Width:"), widthField],
                                      [NSTextField(labelWithString: "Height:"), heightField]])
        size.rowSpacing = 8
        let units = NSStackView(views: [NSTextField(labelWithString: "Units:")] + buttons)
        let note = NSTextField(labelWithString: "Resolution: \(Int(AttributesForm.dpi)) × \(Int(AttributesForm.dpi)) dots per inch")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [size, units, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view = stack
        show()
    }

    private func format(_ px: Int) -> String {
        unit == .pixels ? String(px) : String(format: "%.2f", Double(px) / unit.pixelsPerUnit)
    }

    private func show() {
        shown = (format(pixels.w), format(pixels.h))
        widthField.stringValue = shown.w
        heightField.stringValue = shown.h
    }

    /// The field in pixels; nil when it isn't a valid number.
    private func parse(_ field: NSTextField, displayed: String, exact: Int) -> Int? {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if text == displayed { return exact }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return max(1, Int((v * unit.pixelsPerUnit).rounded()))
    }

    @objc private func unitChanged(_ sender: NSButton) {
        guard let new = Unit(rawValue: sender.tag), new != unit else { return }
        if let w = parse(widthField, displayed: shown.w, exact: pixels.w) { pixels.w = w }
        if let h = parse(heightField, displayed: shown.h, exact: pixels.h) { pixels.h = h }
        unit = new
        UserDefaults.standard.set(new.rawValue, forKey: AttributesForm.unitKey)
        show()
    }

    func result() -> (Int, Int)? {
        guard let w = parse(widthField, displayed: shown.w, exact: pixels.w),
              let h = parse(heightField, displayed: shown.h, exact: pixels.h),
              (1...20000).contains(w), (1...20000).contains(h) else { return nil }
        return (w, h)
    }
}
