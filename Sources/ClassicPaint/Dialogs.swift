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

/// Image > Attributes: width and height in inches, centimeters or pixels, and the
/// resolution (pixels per inch) used to convert them. The resolution is remembered;
/// set to the screen's pixels per inch, centimeters match a ruler at 100% zoom.
final class AttributesForm: NSObject {
    enum Unit: Int, CaseIterable {
        case inches, centimeters, pixels

        var title: String { ["Inches", "Cm", "Pixels"][rawValue] }
        func pixelsPerUnit(_ ppi: Double) -> Double { [ppi, ppi / 2.54, 1][rawValue] }
    }

    private static let unitKey = "AttributesUnit"
    static let resolutionRange: ClosedRange<Double> = 10...1000

    let widthField = NSTextField()
    let heightField = NSTextField()
    let resolutionField = NSTextField()
    private(set) var view = NSView()
    private var unit: Unit
    /// Exact sizes, so switching units back and forth never changes them by rounding.
    private var pixels: (w: Int, h: Int)
    /// What the fields showed, at which resolution; untouched fields keep their exact pixels.
    private var shown: (w: String, h: String, ppi: Double) = ("", "", 0)

    init(width: Int, height: Int) {
        pixels = (width, height)
        unit = (UserDefaults.standard.object(forKey: AttributesForm.unitKey) as? Int).flatMap(Unit.init) ?? .pixels
        super.init()
        for f in [widthField, heightField, resolutionField] {
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
        }
        resolutionField.stringValue = AttributesForm.format(Bitmap.dpi)
        let buttons = Unit.allCases.map { u in
            let b = NSButton(radioButtonWithTitle: u.title, target: self, action: #selector(unitChanged(_:)))
            b.tag = u.rawValue
            b.state = u == unit ? .on : .off
            return b
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width:"), widthField, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Height:"), heightField, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Resolution:"), resolutionField, NSTextField(labelWithString: "pixels per inch")],
        ])
        grid.rowSpacing = 8
        let units = NSStackView(views: [NSTextField(labelWithString: "Units:")] + buttons)
        let note = NSTextField(wrappingLabelWithString:
            "Enter your screen's pixels per inch to make centimeters and inches match a ruler at Normal Size (100%). Windows uses 96.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [grid, units, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view = stack
        show()
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    private static func number(_ field: NSTextField) -> Double? {
        Double(field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// The resolution typed in the dialog (falls back to the saved one while it is invalid).
    private var ppi: Double {
        guard let v = AttributesForm.number(resolutionField), AttributesForm.resolutionRange.contains(v) else { return Bitmap.dpi }
        return v
    }

    private func format(_ px: Int) -> String {
        unit == .pixels ? String(px) : String(format: "%.2f", Double(px) / unit.pixelsPerUnit(ppi))
    }

    private func show() {
        shown = (format(pixels.w), format(pixels.h), ppi)
        widthField.stringValue = shown.w
        heightField.stringValue = shown.h
    }

    /// The field in pixels; nil when it isn't a valid number. After a resolution change,
    /// centimeters/inches as typed are kept and the pixels follow.
    private func parse(_ field: NSTextField, displayed: String, exact: Int) -> Int? {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if text == displayed && (unit == .pixels || ppi == shown.ppi) { return exact }
        guard let v = AttributesForm.number(field), v > 0 else { return nil }
        return max(1, Int((v * unit.pixelsPerUnit(ppi)).rounded()))
    }

    @objc private func unitChanged(_ sender: NSButton) {
        guard let new = Unit(rawValue: sender.tag), new != unit else { return }
        if let w = parse(widthField, displayed: shown.w, exact: pixels.w) { pixels.w = w }
        if let h = parse(heightField, displayed: shown.h, exact: pixels.h) { pixels.h = h }
        unit = new
        UserDefaults.standard.set(new.rawValue, forKey: AttributesForm.unitKey)
        show()
    }

    /// The new size in pixels, after saving the resolution; nil if anything is invalid.
    func result() -> (Int, Int)? {
        guard let r = AttributesForm.number(resolutionField), AttributesForm.resolutionRange.contains(r),
              let w = parse(widthField, displayed: shown.w, exact: pixels.w),
              let h = parse(heightField, displayed: shown.h, exact: pixels.h),
              (1...20000).contains(w), (1...20000).contains(h) else { return nil }
        Bitmap.dpi = r
        return (w, h)
    }
}
