import AppKit

/// How many screen points make an inch on each display, so View > Zoom > Actual Size
/// can show the picture at its real-world size (pictures are 96 pixels per inch).
enum ScreenCalibration {
    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Per monitor model/serial and resolution (a different scaled resolution changes points per inch).
    private static func key(_ screen: NSScreen) -> String {
        let id = displayID(screen) ?? 0
        return "ScreenPointsPerInch-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))-"
            + "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    /// The calibrated value, else the display's own report unless it is the 72 dpi
    /// placeholder that displays without size information give.
    static func pointsPerInch(for screen: NSScreen) -> CGFloat? {
        if let v = UserDefaults.standard.object(forKey: key(screen)) as? Double { return CGFloat(v) }
        return reportedPointsPerInch(for: screen)
    }

    static func reportedPointsPerInch(for screen: NSScreen) -> CGFloat? {
        guard let id = displayID(screen) else { return nil }
        let mm = CGDisplayScreenSize(id)
        guard mm.width > 0 else { return nil }
        let ppi = screen.frame.width / (mm.width / 25.4)
        return abs(ppi - 72) < 0.5 ? nil : ppi
    }

    static func set(_ ppi: CGFloat, for screen: NSScreen) {
        UserDefaults.standard.set(Double(ppi), forKey: key(screen))
    }

    /// Shows a 10 cm ruler to match against a real one. Returns points per inch.
    static func runDialog(for screen: NSScreen) -> CGFloat? {
        let view = CalibrationView(pointsPerInch: pointsPerInch(for: screen) ?? CGFloat(Bitmap.dpi))
        let a = NSAlert()
        a.messageText = "Calibrate Screen"
        a.informativeText = "Hold a ruler against the screen and drag the slider until the bar is exactly 10 cm long. "
            + "Or type what the bar measures now and press Return."
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        a.accessoryView = view
        a.window.initialFirstResponder = view.measured
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        view.applyMeasurement()
        set(view.pointsPerInch, for: screen)
        return view.pointsPerInch
    }
}

final class CalibrationView: NSView {
    private static let range: ClosedRange<Double> = 40...165

    var pointsPerInch: CGFloat { didSet { sync() } }
    private let ruler = RulerBar()
    private let slider = NSSlider()
    let measured = NSTextField()
    private let readout = NSTextField(labelWithString: "")

    init(pointsPerInch: CGFloat) {
        self.pointsPerInch = pointsPerInch
        super.init(frame: .zero)
        slider.minValue = CalibrationView.range.lowerBound
        slider.maxValue = CalibrationView.range.upperBound
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)
        measured.placeholderString = "e.g. 7.5"
        measured.target = self
        measured.action = #selector(typed)
        measured.widthAnchor.constraint(equalToConstant: 70).isActive = true
        readout.textColor = .secondaryLabelColor
        readout.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // Wide enough for 10 cm at the top of the slider range.
        ruler.translatesAutoresizingMaskIntoConstraints = false
        ruler.widthAnchor.constraint(equalToConstant: CalibrationView.range.upperBound / 2.54 * 10 + 4).isActive = true
        ruler.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let typedRow = NSStackView(views: [NSTextField(labelWithString: "The bar measures"), measured, NSTextField(labelWithString: "cm")])
        let stack = NSStackView(views: [ruler, slider, typedRow, readout])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        slider.widthAnchor.constraint(equalTo: ruler.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func sync() {
        slider.doubleValue = Double(pointsPerInch)
        ruler.pointsPerCm = pointsPerInch / 2.54
        readout.stringValue = "Actual Size will be \(Int((pointsPerInch / CGFloat(Bitmap.dpi) * 100).rounded()))% zoom"
    }

    @objc private func slid() {
        measured.stringValue = ""
        pointsPerInch = CGFloat(slider.doubleValue)
    }

    @objc private func typed() { applyMeasurement() }

    /// "The bar measures X cm": scale so it becomes 10 cm.
    func applyMeasurement() {
        let text = measured.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let cm = Double(text), cm > 0.5, cm < 50 else { return }
        measured.stringValue = ""
        pointsPerInch = min(max(pointsPerInch * 10 / CGFloat(cm), CGFloat(CalibrationView.range.lowerBound)),
                            CGFloat(CalibrationView.range.upperBound))
    }
}

/// A 10 cm bar with centimeter ticks.
private final class RulerBar: NSView {
    var pointsPerCm: CGFloat = 96 / 2.54 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let len = pointsPerCm * 10
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: len, height: 22).fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 22, width: len, height: 2).fill()
        for i in 0...10 {
            let x = min((CGFloat(i) * pointsPerCm).rounded(), len - 1)
            NSRect(x: x, y: i % 5 == 0 ? 0 : 10, width: 1, height: i % 5 == 0 ? 22 : 12).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        ("0" as NSString).draw(at: NSPoint(x: 0, y: 24), withAttributes: attrs)
        ("10 cm" as NSString).draw(at: NSPoint(x: max(0, len - 26), y: 24), withAttributes: attrs)
    }
}
