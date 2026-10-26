import AppKit
import UniformTypeIdentifiers

/// The picture inside the gray workspace. View coordinates are image pixels
/// (plus a small margin); zooming is done by the enclosing scroll view's
/// magnification, so everything here is drawn and hit-tested at 1×.
final class CanvasView: NSView {
    private(set) unowned var document: PaintDocument
    weak var statusBar: StatusBarView?
    private let state = PaintState.shared
    var bitmap: Bitmap { document.bitmap }

    private enum Mode {
        case idle, stroke, shape, curve, polygon, pick, selectRect, selectFree, moveSelection, textBox
        case resizeSelection(Int), resizeCanvas(Int), resizeText(Int), moveText
    }

    private var mode: Mode = .idle
    private var dragging = false
    private var activeRight = false
    /// 0 = left (foreground color), 1 = right (background color).
    private var button = 0
    /// The canvas before the current stroke or shape; restored on every drag
    /// event for shapes, and registered for undo when the operation ends.
    private var base: Snapshot?
    private var startPt = IPoint(x: 0, y: 0)
    private var lastPt = IPoint(x: 0, y: 0)
    private var rawPt = IPoint(x: 0, y: 0)
    private var shift = false
    private var freePath: [IPoint] = []
    private var dragRect: IRect?
    private var canvasDrag: (w: Int, h: Int)?
    private var moveOrigin = IRect(x: 0, y: 0, w: 0, h: 0)
    /// Curve: start, end, first control point, second control point.
    private var curve: [IPoint] = []
    /// 0: dragging the line, 1: first bend, 2: second bend.
    private var curveStage = 0
    private var curveActive = false
    private var poly: [IPoint] = []
    private var polyTail: IPoint?
    private var shapeButton = 0
    private var sprayTimer: Timer?
    private(set) var selection: Selection?
    private var textView: PaintTextView?
    private var textRect = IRect(x: 0, y: 0, w: 0, h: 0)
    private var lastTool: Tool
    private var trackingArea: NSTrackingArea?

    init(document: PaintDocument) {
        self.document = document
        lastTool = PaintState.shared.tool
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged(_:)), name: .paintStateChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }
    /// Gray border around the picture; constant on screen, room for the resize handles.
    var margin: CGFloat { (8 / zoom).rounded(.up) }
    var imageRect: CGRect { CGRect(x: margin, y: margin, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)) }

    func updateFrame() {
        let w = max(bitmap.width, canvasDrag?.w ?? 0), h = max(bitmap.height, canvasDrag?.h ?? 0)
        let m = margin
        setFrameSize(NSSize(width: CGFloat(w) + 2 * m, height: CGFloat(h) + 2 * m))
        textView?.setFrameOrigin(NSPoint(x: m + CGFloat(textRect.x), y: m + CGFloat(textRect.y)))
        needsDisplay = true
        updateStatus()
    }

    private func viewPoint(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private func pixel(_ p: CGPoint) -> IPoint { IPoint(x: Int(floor(p.x - margin)), y: Int(floor(p.y - margin))) }
    private func viewRect(_ r: IRect) -> CGRect { r.cg.offsetBy(dx: margin, dy: margin) }
    private func center(_ p: IPoint) -> CGPoint { CGPoint(x: margin + CGFloat(p.x) + 0.5, y: margin + CGFloat(p.y) + 0.5) }

    private func changed() {
        bitmap.touch()
        needsDisplay = true
    }

    /// After undo, revert or a whole-image change.
    func bitmapDidChange() {
        updateFrame()
        changed()
    }

    private var fg: Pixel { button == 0 ? state.primary : state.secondary }
    private var bg: Pixel { button == 0 ? state.secondary : state.primary }
    private var transparentKey: Pixel? { state.transparentSelection ? state.secondary : nil }
    private var isSelectTool: Bool { state.tool == .select || state.tool == .freeSelect }

    private func registerUndo(_ s: Snapshot, _ name: String) { document.registerUndo(s, name) }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        // Control-click acts as a right click, except for selections where Ctrl-drag copies.
        press(e, button: e.modifierFlags.contains(.control) && !isSelectTool ? 1 : 0, right: false)
    }
    override func rightMouseDown(with e: NSEvent) { press(e, button: 1, right: true) }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func mouseUp(with e: NSEvent) { if !activeRight { release(e) } }
    override func rightMouseUp(with e: NSEvent) { if activeRight { release(e) } }

    private func press(_ e: NSEvent, button b: Int, right: Bool) {
        // Pressing the other button mid-drag cancels, as in Paint.
        if dragging { cancelCurrent(); return }
        if textView != nil {
            // Handles resize the text box, its border moves it; any other click places the text.
            let vp = viewPoint(e)
            if let h = textHandle(at: vp) {
                beginTextDrag(.resizeText(h), e)
            } else if onTextBorder(vp) {
                beginTextDrag(.moveText, e)
            } else {
                commitText()
            }
            return
        }
        window?.makeFirstResponder(self)

        let vp = viewPoint(e), p = pixel(vp)
        let selectionHandleHit = isSelectTool ? selectionHandle(at: vp) : nil
        let canvasHandleHit = selectionHandleHit == nil ? canvasHandle(at: vp) : nil
        if canvasHandleHit != nil {
            // Before the drag starts: finishPending() cancels an active drag.
            finishPending()
            commitSelection()
        }

        dragging = true
        activeRight = right
        button = b
        startPt = p
        lastPt = p
        rawPt = p
        shift = e.modifierFlags.contains(.shift)

        if let h = selectionHandleHit, let sel = selection {
            mode = .resizeSelection(h)
            moveOrigin = sel.rect
            return
        }
        if let h = canvasHandleHit {
            mode = .resizeCanvas(h)
            canvasDrag = (bitmap.width, bitmap.height)
            return
        }

        switch state.tool {
        case .select, .freeSelect:
            pressSelect(p, e)
        case .text:
            commitSelection()
            mode = .textBox
            dragRect = IRect(x: p.x, y: p.y, w: 1, h: 1)
        case .pick:
            mode = .pick
            pickColor(at: p)
        case .magnifier:
            dragging = false
            setZoom(zoom > 1 ? 1 : state.magnifierLevel, around: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            state.restorePreviousTool()
        case .fill:
            dragging = false
            commitSelection()
            let s = bitmap.snapshot()
            if bitmap.floodFill(p.x, p.y, fg) {
                registerUndo(s, Tool.fill.title)
                changed()
            }
        case .pencil, .brush, .eraser, .airbrush:
            commitSelection()
            base = bitmap.snapshot()
            mode = .stroke
            paintStroke(from: p, to: p)
            if state.tool == .airbrush { startSpray() }
        case .line, .rectangle, .ellipse, .roundedRect:
            commitSelection()
            base = bitmap.snapshot()
            mode = .shape
            drawShape()
        case .curve:
            commitSelection()
            mode = .curve
            if !curveActive {
                base = bitmap.snapshot()
                shapeButton = b
                curve = [p, p, p, p]
                curveStage = 0
                curveActive = true
            } else {
                button = shapeButton
                bend(p)
            }
            drawCurve()
        case .polygon:
            commitSelection()
            mode = .polygon
            if poly.isEmpty {
                base = bitmap.snapshot()
                shapeButton = b
                poly = [p]
                polyTail = p
            } else if e.clickCount >= 2 {
                dragging = false
                mode = .idle
                button = shapeButton
                finishPolygon()
                return
            } else {
                button = shapeButton
                polyTail = constrainedTail(p)
            }
            drawPolygon(closed: false)
        }
        updateStatus(at: p)
    }

    private func drag(_ e: NSEvent) {
        guard dragging else { return }
        autoscroll(with: e)
        let vp = viewPoint(e), p = pixel(vp)
        shift = e.modifierFlags.contains(.shift)
        rawPt = p
        switch mode {
        case .stroke:
            paintStroke(from: lastPt, to: p)
            lastPt = p
        case .shape:
            drawShape()
        case .curve:
            if curveStage == 0 { curve[1] = shift ? constrain45(curve[0], p) : p } else { bend(p) }
            drawCurve()
        case .polygon:
            polyTail = constrainedTail(p)
            drawPolygon(closed: false)
        case .pick:
            pickColor(at: p)
        case .selectRect, .textBox:
            dragRect = IRect.spanning(startPt, p)
            needsDisplay = true
        case .selectFree:
            if p != freePath.last { freePath.append(p) }
            needsDisplay = true
        case .moveSelection:
            moveSelection(to: p)
        case .resizeSelection(let h):
            resizeSelection(h, to: p)
        case .resizeText(let h):
            resizeTextBox(h, to: p)
        case .moveText:
            moveTextBox(to: p)
        case .resizeCanvas(let h):
            let w = max(1, Int((vp.x - margin).rounded())), hh = max(1, Int((vp.y - margin).rounded()))
            canvasDrag = (h == 5 ? bitmap.width : w, h == 3 ? bitmap.height : hh)
            updateFrame()
        case .idle:
            break
        }
        updateStatus(at: p)
    }

    private func release(_ e: NSEvent) {
        guard dragging else { return }
        dragging = false
        let ended = mode
        mode = .idle
        switch ended {
        case .stroke:
            stopSpray()
            finishStroke(state.tool.title)
        case .shape:
            finishStroke(state.tool.title)
        case .curve:
            curveStage += 1
            if curveStage >= 3 { finishCurve() }
        case .polygon:
            if let t = polyTail, t != poly.last {
                if poly.count >= 3, abs(t.x - poly[0].x) <= 2, abs(t.y - poly[0].y) <= 2 {
                    finishPolygon()
                } else {
                    poly.append(t)
                }
            }
        case .pick:
            state.restorePreviousTool()
        case .selectRect:
            if let r = dragRect, rawPt != startPt { liftRect(r) }
        case .selectFree:
            if freePath.count > 2 { liftFree(freePath) }
        case .textBox:
            if let r = dragRect { beginText(r, clicked: rawPt == startPt) }
        case .resizeCanvas:
            if let d = canvasDrag {
                canvasDrag = nil
                resizeCanvas(d.w, d.h)
            }
            updateFrame()
        case .resizeText, .moveText:
            if let tv = textView { window?.makeFirstResponder(tv) }
        case .moveSelection, .resizeSelection, .idle:
            break
        }
        dragRect = nil
        freePath = []
        needsDisplay = true
        updateStatus()
    }

    private func finishStroke(_ name: String) {
        if let b = base { registerUndo(b, name) }
        base = nil
    }

    /// Esc: abandon the stroke, shape or drag in progress.
    private func cancelCurrent() {
        stopSpray()
        switch mode {
        case .moveSelection, .resizeSelection: selection?.rect = moveOrigin
        default: break
        }
        if let b = base { bitmap.restore(b) }
        dragging = false
        mode = .idle
        base = nil
        curveActive = false
        curveStage = 0
        poly = []
        polyTail = nil
        dragRect = nil
        freePath = []
        canvasDrag = nil
        updateFrame()
        changed()
    }

    /// Completes a curve or polygon that is waiting for more clicks.
    func finishPending() {
        if dragging { cancelCurrent() }
        if curveActive { finishCurve() }
        if !poly.isEmpty {
            button = shapeButton
            finishPolygon()
        }
    }

    // MARK: Freehand tools

    private func paintStroke(from a: IPoint, to b: IPoint) {
        switch state.tool {
        case .pencil:
            bitmap.strokeLine(a, b, .dot, fg)
        case .brush:
            bitmap.strokeLine(a, b, state.brushStamp, fg)
        case .eraser:
            let pen = Stamp.square(state.eraserSize)
            if button == 0 {
                bitmap.strokeLine(a, b, pen, state.secondary)
            } else {
                // Color eraser: only the foreground color turns into the background color.
                let from = state.primary, to = state.secondary, bmp = bitmap
                bresenham(a, b) { x, y in
                    for o in pen.offsets {
                        let px = x + o.0, py = y + o.1
                        if bmp.contains(px, py) && bmp.get(px, py) == from { bmp.plot(px, py, to) }
                    }
                }
            }
        case .airbrush:
            spray(at: b)
        default:
            break
        }
        changed()
    }

    private func startSpray() {
        sprayTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(sprayTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        sprayTimer = t
    }

    @objc private func sprayTick() {
        spray(at: lastPt)
        changed()
    }

    private func stopSpray() {
        sprayTimer?.invalidate()
        sprayTimer = nil
    }

    private func spray(at p: IPoint) {
        let r = state.airbrushRadius, c = fg
        for _ in 0..<(r * 2) {
            let a = Double.random(in: 0..<(2 * .pi)), d = Double(r) * Double.random(in: 0...1).squareRoot()
            bitmap.plot(p.x + Int((d * cos(a)).rounded()), p.y + Int((d * sin(a)).rounded()), c)
        }
    }

    private func pickColor(at p: IPoint) {
        guard bitmap.contains(p.x, p.y) else { return }
        let c = bitmap.get(p.x, p.y)
        if button == 0 { state.primary = c } else { state.secondary = c }
    }

    // MARK: Shapes

    private func constrain45(_ from: IPoint, _ p: IPoint) -> IPoint {
        let dx = p.x - from.x, dy = p.y - from.y
        if abs(dx) > 2 * abs(dy) { return IPoint(x: p.x, y: from.y) }
        if abs(dy) > 2 * abs(dx) { return IPoint(x: from.x, y: p.y) }
        let d = max(abs(dx), abs(dy))
        return IPoint(x: from.x + (dx < 0 ? -d : d), y: from.y + (dy < 0 ? -d : d))
    }

    private func constrainSquare(_ from: IPoint, _ p: IPoint) -> IPoint {
        let dx = p.x - from.x, dy = p.y - from.y, d = max(abs(dx), abs(dy))
        return IPoint(x: from.x + (dx < 0 ? -d : d), y: from.y + (dy < 0 ? -d : d))
    }

    private func drawShape() {
        guard let b = base else { return }
        bitmap.restore(b)
        let tool = state.tool
        let p = shift ? (tool == .line ? constrain45(startPt, rawPt) : constrainSquare(startPt, rawPt)) : rawPt
        lastPt = p
        if tool == .line {
            bitmap.strokeLine(startPt, p, .pen(state.lineWidth), fg)
        } else {
            drawBox(tool, IRect.spanning(startPt, p))
        }
        changed()
    }

    /// Rectangle, ellipse or rounded rectangle in the selected fill style:
    /// outline in the drawing color, fill in the other color (or the drawing
    /// color when there is no outline).
    private func drawBox(_ tool: Tool, _ r: IRect) {
        let style = state.fillStyle, w = state.lineWidth
        let outline = style != 2
        let fillColor = style == 2 ? fg : bg
        let pen = Stamp.pen(w)
        // Outline pixel centers, inset so thick pens stay inside the box.
        let inset = outline ? Double(w - 1) / 2 : 0
        let x0 = Double(r.x) + inset, y0 = Double(r.y) + inset
        let x1 = max(x0, Double(r.maxX - 1) - inset), y1 = max(y0, Double(r.maxY - 1) - inset)
        switch tool {
        case .rectangle:
            if style != 0 { bitmap.fill(outline ? r.insetBy(w) : r, fillColor) }
            if outline { bitmap.strokeRect(r, w, fg) }
        case .ellipse:
            if outline {
                if style == 1 {
                    bitmap.fillPath(CGPath(ellipseIn: CGRect(x: x0 + 0.5, y: y0 + 0.5, width: x1 - x0, height: y1 - y0), transform: nil), fillColor)
                }
                bitmap.strokePolyline(ellipsePoints(x0, y0, x1, y1), closed: true, pen, fg)
            } else {
                bitmap.fillPath(CGPath(ellipseIn: r.cg, transform: nil), fillColor)
            }
        case .roundedRect:
            let radius = min(8, (x1 - x0) / 2, (y1 - y0) / 2)
            if outline {
                if style == 1 {
                    let rr = CGRect(x: x0 + 0.5, y: y0 + 0.5, width: x1 - x0, height: y1 - y0)
                    bitmap.fillPath(CGPath(roundedRect: rr, cornerWidth: max(0, min(radius, rr.width / 2)),
                                           cornerHeight: max(0, min(radius, rr.height / 2)), transform: nil), fillColor)
                }
                bitmap.strokePolyline(roundedPoints(x0, y0, x1, y1, radius), closed: true, pen, fg)
            } else {
                let rr = r.cg
                bitmap.fillPath(CGPath(roundedRect: rr, cornerWidth: min(8, rr.width / 2), cornerHeight: min(8, rr.height / 2), transform: nil), fillColor)
            }
        default:
            break
        }
    }

    private func ellipsePoints(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [IPoint] {
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = (x1 - x0) / 2, ry = (y1 - y0) / 2
        let n = max(16, Int((2 * .pi * max(rx, ry)).rounded(.up)))
        return (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            return IPoint(x: Int((cx + rx * cos(a)).rounded()), y: Int((cy + ry * sin(a)).rounded()))
        }
    }

    private func roundedPoints(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ r: Double) -> [IPoint] {
        let corners: [(Double, Double, Double)] = [
            (x0 + r, y0 + r, .pi), (x1 - r, y0 + r, 1.5 * .pi), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 0.5 * .pi),
        ]
        let steps = max(2, Int(r.rounded(.up)))
        var pts: [IPoint] = []
        for (cx, cy, start) in corners {
            for i in 0...steps {
                let a = start + Double(i) / Double(steps) * .pi / 2
                pts.append(IPoint(x: Int((cx + r * cos(a)).rounded()), y: Int((cy + r * sin(a)).rounded())))
            }
        }
        return pts
    }

    private func bend(_ p: IPoint) {
        if curveStage == 1 {
            curve[2] = p
            curve[3] = p
        } else {
            curve[3] = p
        }
    }

    private func drawCurve() {
        guard let b = base else { return }
        bitmap.restore(b)
        let pen = Stamp.pen(state.lineWidth)
        if curveStage == 0 {
            bitmap.strokeLine(curve[0], curve[1], pen, fg)
        } else {
            let p0 = curve[0], p3 = curve[1], c1 = curve[2], c2 = curve[3]
            func dist(_ a: IPoint, _ b: IPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }
            let n = max(16, Int(dist(p0, c1) + dist(c1, c2) + dist(c2, p3)))
            var pts: [IPoint] = []
            for i in 0...n {
                let t = Double(i) / Double(n), u = 1 - t
                let x = u * u * u * Double(p0.x) + 3 * u * u * t * Double(c1.x) + 3 * u * t * t * Double(c2.x) + t * t * t * Double(p3.x)
                let y = u * u * u * Double(p0.y) + 3 * u * u * t * Double(c1.y) + 3 * u * t * t * Double(c2.y) + t * t * t * Double(p3.y)
                let pt = IPoint(x: Int(x.rounded()), y: Int(y.rounded()))
                if pt != pts.last { pts.append(pt) }
            }
            bitmap.strokePolyline(pts, closed: false, pen, fg)
        }
        changed()
    }

    private func finishCurve() {
        curveActive = false
        curveStage = 0
        curve = []
        finishStroke(Tool.curve.title)
    }

    private func constrainedTail(_ p: IPoint) -> IPoint {
        guard shift, let last = poly.last else { return p }
        return constrain45(last, p)
    }

    private func drawPolygon(closed: Bool) {
        guard let b = base else { return }
        bitmap.restore(b)
        var pts = poly
        if !closed, let t = polyTail { pts.append(t) }
        let style = state.fillStyle
        if closed && style != 0 {
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: Double($0.x) + 0.5, y: Double($0.y) + 0.5) })
            path.closeSubpath()
            bitmap.fillPath(path, style == 2 ? fg : bg)
        }
        if closed && style == 2 {
            bitmap.strokePolyline(pts, closed: true, .dot, fg)
        } else {
            bitmap.strokePolyline(pts, closed: closed, .pen(state.lineWidth), fg)
        }
        changed()
    }

    private func finishPolygon() {
        polyTail = nil
        if poly.count > 1 {
            drawPolygon(closed: true)
            finishStroke(Tool.polygon.title)
        } else {
            if let b = base { bitmap.restore(b) }
            base = nil
            changed()
        }
        poly = []
    }

    // MARK: Selection

    private func pressSelect(_ p: IPoint, _ e: NSEvent) {
        if let sel = selection {
            if sel.rect.contains(p) {
                mode = .moveSelection
                moveOrigin = sel.rect
                // Ctrl- or Option-drag leaves a copy behind.
                if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control) {
                    markSelectionDirty("Copy")
                    stampSelection()
                }
                return
            }
            commitSelection()
        }
        if state.tool == .select {
            mode = .selectRect
            dragRect = IRect(x: p.x, y: p.y, w: 1, h: 1)
        } else {
            mode = .selectFree
            freePath = [p]
        }
    }

    private func liftRect(_ r: IRect) {
        let r = r.intersection(bitmap.bounds)
        guard !r.isEmpty else { return }
        let pre = bitmap.snapshot()
        let content = bitmap.crop(r)
        bitmap.fill(r, state.secondary)
        selection = Selection(content: content, rect: r, preLift: pre, dirty: false)
        changed()
    }

    private func liftFree(_ pts: [IPoint]) {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let r = IRect(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()! + 1, h: ys.max()! - ys.min()! + 1)
            .intersection(bitmap.bounds)
        guard !r.isEmpty else { return }
        var mask = [UInt8](repeating: 0, count: r.w * r.h)
        mask.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: r.w, height: r.h, bitsPerComponent: 8, bytesPerRow: r.w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(r.h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(false)
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: CGFloat($0.x - r.x) + 0.5, y: CGFloat($0.y - r.y) + 0.5) })
            path.closeSubpath()
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineWidth(1)
            ctx.addPath(path)
            ctx.strokePath()
        }
        guard mask.contains(where: { $0 != 0 }) else { return }
        let pre = bitmap.snapshot()
        let content = bitmap.crop(r)
        let hole = state.secondary
        for y in 0..<r.h {
            for x in 0..<r.w {
                if mask[y * r.w + x] == 0 {
                    content.pixels[y * r.w + x] = 0
                } else {
                    bitmap.pixels[(r.y + y) * bitmap.width + r.x + x] = hole
                }
            }
        }
        content.touch()
        selection = Selection(content: content, rect: r, preLift: pre, dirty: false)
        changed()
    }

    /// Drops the selection back into the picture.
    func commitSelection() {
        guard let sel = selection else { return }
        selection = nil
        if sel.dirty {
            bitmap.draw(sel.overlay(transparentKey: transparentKey), in: sel.rect.cg)
        } else if sel.preLift.width == bitmap.width && sel.preLift.height == bitmap.height {
            bitmap.restore(sel.preLift)
        }
        changed()
        updateStatus()
    }

    /// The first change to a selection becomes one undo step back to before it was lifted.
    private func markSelectionDirty(_ name: String) {
        guard let sel = selection, !sel.dirty else { return }
        sel.dirty = true
        registerUndo(sel.preLift, name)
    }

    private func stampSelection() {
        guard let sel = selection else { return }
        bitmap.draw(sel.overlay(transparentKey: transparentKey), in: sel.rect.cg)
    }

    private func moveSelection(to p: IPoint) {
        guard let sel = selection else { return }
        markSelectionDirty("Move")
        sel.rect.x = moveOrigin.x + p.x - startPt.x
        sel.rect.y = moveOrigin.y + p.y - startPt.y
        // Shift-drag smears copies along the way.
        if shift { stampSelection() }
        needsDisplay = true
    }

    private func resizeSelection(_ h: Int, to p: IPoint) {
        guard let sel = selection else { return }
        markSelectionDirty("Stretch")
        let dx = p.x - startPt.x, dy = p.y - startPt.y
        var x0 = moveOrigin.x, y0 = moveOrigin.y, x1 = moveOrigin.maxX, y1 = moveOrigin.maxY
        let left = [0, 6, 7].contains(h), top = [0, 1, 2].contains(h)
        if left { x0 += dx }
        if [2, 3, 4].contains(h) { x1 += dx }
        if top { y0 += dy }
        if [4, 5, 6].contains(h) { y1 += dy }
        if x1 - x0 < 1 { if left { x0 = x1 - 1 } else { x1 = x0 + 1 } }
        if y1 - y0 < 1 { if top { y0 = y1 - 1 } else { y1 = y0 + 1 } }
        sel.rect = IRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        needsDisplay = true
    }

    private func handleCenters(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func selectionHandle(at vp: CGPoint) -> Int? {
        guard let sel = selection else { return nil }
        let tol = 5 / zoom
        for (i, c) in handleCenters(viewRect(sel.rect)).enumerated() where abs(c.x - vp.x) <= tol && abs(c.y - vp.y) <= tol {
            return i
        }
        return nil
    }

    /// The three canvas-size handles: right (3), corner (4) and bottom (5).
    private func canvasHandleRects() -> [(Int, CGRect)] {
        let s = 5 / zoom, m = margin
        let w = CGFloat(canvasDrag?.w ?? bitmap.width), h = CGFloat(canvasDrag?.h ?? bitmap.height)
        return [(3, CGRect(x: m + w, y: m + h / 2 - s / 2, width: s, height: s)),
                (4, CGRect(x: m + w, y: m + h, width: s, height: s)),
                (5, CGRect(x: m + w / 2 - s / 2, y: m + h, width: s, height: s))]
    }

    private func canvasHandle(at vp: CGPoint) -> Int? {
        let tol = 2 / zoom
        return canvasHandleRects().first { $0.1.insetBy(dx: -tol, dy: -tol).contains(vp) }?.0
    }

    // MARK: Text

    private func beginText(_ r: IRect, clicked: Bool) {
        var r = r
        let lineHeight = Int(NSLayoutManager().defaultLineHeight(for: state.textFont()).rounded(.up))
        if clicked || r.w < 8 { r.w = max(r.w, min(240, max(40, bitmap.width - r.x))) }
        if clicked || r.h < lineHeight { r.h = max(r.h, lineHeight + 2) }
        textRect = r

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat(r.w), height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = PaintTextView(frame: NSRect(x: margin + CGFloat(r.x), y: margin + CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h)),
                               textContainer: container)
        tv.textContainerInset = .zero
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = tv.frame.size
        tv.maxSize = NSSize(width: CGFloat(r.w), height: 100_000)
        tv.focusRingType = .none
        tv.onEscape = { [weak self] in self?.commitText() }
        tv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(textFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: tv)
        NotificationCenter.default.addObserver(self, selector: #selector(textFrameChanged(_:)), name: NSText.didChangeNotification, object: tv)
        addSubview(tv)
        textView = tv
        applyTextStyle()
        window?.makeFirstResponder(tv)
        if state.showTextToolbar { FontBar.shared.show(near: window) }
        needsDisplay = true
    }

    @objc private func textFrameChanged(_ n: Notification) { needsDisplay = true }

    private func textHandle(at vp: CGPoint) -> Int? {
        guard textView != nil else { return nil }
        let tol = 5 / zoom
        for (i, c) in handleCenters(viewRect(textBoxRect)).enumerated() where abs(c.x - vp.x) <= tol && abs(c.y - vp.y) <= tol {
            return i
        }
        return nil
    }

    /// Within a few screen points of the text box's dashed border.
    private func onTextBorder(_ vp: CGPoint) -> Bool {
        guard textView != nil else { return false }
        let r = viewRect(textBoxRect), tol = 3 / zoom
        return r.insetBy(dx: -tol, dy: -tol).contains(vp) && !r.insetBy(dx: tol, dy: tol).contains(vp)
    }

    /// Handles and border sit partly over the text view; take those clicks here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if textView != nil, let sv = superview {
            let p = convert(point, from: sv)
            if textHandle(at: p) != nil || onTextBorder(p) { return self }
        }
        return super.hitTest(point)
    }

    private func beginTextDrag(_ m: Mode, _ e: NSEvent) {
        let p = pixel(viewPoint(e))
        dragging = true
        activeRight = e.type == .rightMouseDown
        startPt = p
        rawPt = p
        mode = m
        moveOrigin = textBoxRect
    }

    private func setTextBox(_ r: IRect) {
        guard let tv = textView else { return }
        textRect = r
        tv.minSize = NSSize(width: CGFloat(r.w), height: CGFloat(r.h))
        tv.maxSize = NSSize(width: CGFloat(r.w), height: 100_000)
        tv.frame = NSRect(x: margin + CGFloat(r.x), y: margin + CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h))
        tv.sizeToFit()  // grows back to fit the text when the box is too short
        needsDisplay = true
    }

    private func resizeTextBox(_ h: Int, to p: IPoint) {
        let dx = p.x - startPt.x, dy = p.y - startPt.y
        let minW = 10, minH = Int(NSLayoutManager().defaultLineHeight(for: state.textFont()).rounded(.up))
        var x0 = moveOrigin.x, y0 = moveOrigin.y, x1 = moveOrigin.maxX, y1 = moveOrigin.maxY
        let left = [0, 6, 7].contains(h), top = [0, 1, 2].contains(h)
        if left { x0 += dx }
        if [2, 3, 4].contains(h) { x1 += dx }
        if top { y0 += dy }
        if [4, 5, 6].contains(h) { y1 += dy }
        if x1 - x0 < minW { if left { x0 = x1 - minW } else { x1 = x0 + minW } }
        if y1 - y0 < minH { if top { y0 = y1 - minH } else { y1 = y0 + minH } }
        setTextBox(IRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0))
    }

    private func moveTextBox(to p: IPoint) {
        var r = textRect
        r.x = moveOrigin.x + p.x - startPt.x
        r.y = moveOrigin.y + p.y - startPt.y
        setTextBox(IRect(x: r.x, y: r.y, w: moveOrigin.w, h: moveOrigin.h))
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: state.textFont(), .foregroundColor: color]
        if state.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// The text view only handles typing, the caret and selection; its letters are
    /// invisible and the canvas draws `renderedText()` instead, so the preview is
    /// pixel-for-pixel what gets placed.
    private func applyTextStyle() {
        guard let tv = textView else { return }
        let attrs = textAttributes(color: .clear)
        tv.typingAttributes = attrs
        if let ts = tv.textStorage { ts.setAttributes(attrs, range: NSRange(location: 0, length: ts.length)) }
        tv.insertionPointColor = state.primary.nsColor
        tv.drawsBackground = false
        needsDisplay = true
    }

    private var textBoxRect: IRect {
        IRect(x: textRect.x, y: textRect.y, w: textRect.w, h: max(textRect.h, Int((textView?.frame.height ?? 0).rounded(.up))))
    }

    /// The text box as it will be placed: no antialiasing (like Paint), on the
    /// background color when Draw Opaque is on, transparent otherwise.
    private func renderedText() -> Bitmap? {
        guard let tv = textView else { return nil }
        let r = textBoxRect
        let out = Bitmap(width: r.w, height: r.h, fill: state.transparentSelection ? 0 : state.secondary)
        guard !tv.string.isEmpty else { return out }
        // Same layout settings as the text view, with the real color.
        let storage = NSTextStorage(string: tv.string, attributes: textAttributes(color: state.primary.nsColor))
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: CGFloat(r.w), height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let ctx = out.context
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setShouldAntialias(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        lm.drawGlyphs(forGlyphRange: lm.glyphRange(for: tc), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        out.touch()
        return out
    }

    /// Places the text box into the picture.
    func commitText() {
        guard let tv = textView else { return }
        let rendered = tv.string.isEmpty ? nil : renderedText()
        let r = textBoxRect
        textView = nil
        window?.makeFirstResponder(self)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: tv)
        NotificationCenter.default.removeObserver(self, name: NSText.didChangeNotification, object: tv)
        if let rendered {
            let s = bitmap.snapshot()
            bitmap.draw(rendered.image, in: r.cg)
            registerUndo(s, Tool.text.title)
        }
        tv.removeFromSuperview()
        FontBar.shared.orderOut(nil)
        changed()
    }

    // MARK: Undo support

    /// Called before an undo/redo replaces the picture.
    func prepareForUndo() {
        if dragging || curveActive || !poly.isEmpty { cancelCurrent() }
        if let tv = textView {
            textView = nil
            window?.makeFirstResponder(self)
            tv.removeFromSuperview()
            FontBar.shared.orderOut(nil)
        }
        commitSelection()
    }

    /// The document was reverted or reloaded: drop everything in progress.
    func reset() {
        stopSpray()
        dragging = false
        mode = .idle
        base = nil
        curveActive = false
        curveStage = 0
        poly = []
        polyTail = nil
        dragRect = nil
        canvasDrag = nil
        selection = nil
        if let tv = textView {
            textView = nil
            tv.removeFromSuperview()
            FontBar.shared.orderOut(nil)
        }
        bitmapDidChange()
    }

    /// File > Open in this window: show another document's picture.
    func attach(_ doc: PaintDocument) {
        document = doc
        doc.canvas = self
        reset()
        enclosingScrollView?.magnification = 1
        updateFrame()
        scroll(.zero)
    }

    /// The picture including a floating selection.
    func flattened() -> Bitmap {
        let b = bitmap.copy()
        if let sel = selection {
            if sel.dirty {
                b.draw(sel.overlay(transparentKey: transparentKey), in: sel.rect.cg)
            } else if sel.preLift.width == b.width && sel.preLift.height == b.height {
                b.restore(sel.preLift)
            }
        }
        return b
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Classic.workspace.setFill()
        dirtyRect.fill()

        let ir = imageRect
        ctx.saveGState()
        ctx.interpolationQuality = .none
        drawImage(ctx, bitmap.image, ir)
        if let sel = selection {
            ctx.clip(to: ir)
            drawImage(ctx, sel.overlay(transparentKey: transparentKey), viewRect(sel.rect))
        }
        if let text = renderedText() {
            ctx.clip(to: ir)
            drawImage(ctx, text.image, viewRect(textBoxRect))
        }
        ctx.restoreGState()

        if state.showGrid && zoom >= 4 { drawGrid(ir.intersection(dirtyRect)) }

        if let r = dragRect { dashed(viewRect(r)) }
        if freePath.count > 1 {
            let path = NSBezierPath()
            path.move(to: center(freePath[0]))
            for p in freePath.dropFirst() { path.line(to: center(p)) }
            path.lineWidth = 1 / zoom
            NSColor.black.setStroke()
            path.stroke()
        }
        if let sel = selection {
            let r = viewRect(sel.rect)
            dashed(r)
            if isSelectTool { handles(handleCenters(r)) }
        }
        if textView != nil {
            let r = viewRect(textBoxRect)
            dashed(r)
            handles(handleCenters(r))
        }
        if let d = canvasDrag { dashed(CGRect(x: margin, y: margin, width: CGFloat(d.w), height: CGFloat(d.h))) }
        Classic.navy.setFill()
        for (_, r) in canvasHandleRects() { r.fill() }
    }

    private func drawImage(_ ctx: CGContext, _ img: CGImage, _ r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    private func dashed(_ r: CGRect) {
        let lw = 1 / zoom
        let path = NSBezierPath(rect: r.insetBy(dx: -lw / 2, dy: -lw / 2))
        path.lineWidth = lw
        NSColor.white.setStroke()
        path.stroke()
        path.setLineDash([4 * lw, 4 * lw], count: 2, phase: 0)
        NSColor.black.setStroke()
        path.stroke()
    }

    private func handles(_ centers: [CGPoint]) {
        let s = 5 / zoom
        Classic.navy.setFill()
        for c in centers { NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s).fill() }
    }

    private func drawGrid(_ r: CGRect) {
        guard !r.isEmpty else { return }
        let m = margin, path = NSBezierPath()
        for x in Int(floor(r.minX - m))...Int(ceil(r.maxX - m)) {
            path.move(to: NSPoint(x: m + CGFloat(x), y: r.minY))
            path.line(to: NSPoint(x: m + CGFloat(x), y: r.maxY))
        }
        for y in Int(floor(r.minY - m))...Int(ceil(r.maxY - m)) {
            path.move(to: NSPoint(x: r.minX, y: m + CGFloat(y)))
            path.line(to: NSPoint(x: r.maxX, y: m + CGFloat(y)))
        }
        path.lineWidth = 1 / zoom
        NSColor(white: 0.5, alpha: 0.8).setStroke()
        path.stroke()
    }

    // MARK: Cursor and status bar

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func cursorUpdate(with e: NSEvent) { cursor(at: viewPoint(e)).set() }

    override func mouseMoved(with e: NSEvent) {
        let vp = viewPoint(e)
        cursor(at: vp).set()
        updateStatus(at: pixel(vp))
    }

    override func mouseExited(with e: NSEvent) { statusBar?.position = "" }

    private func refreshCursor() {
        guard let w = window, w.isKeyWindow else { return }
        let vp = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(vp) { cursor(at: vp).set() }
    }

    private func cursor(at vp: CGPoint) -> NSCursor {
        if textView != nil {
            if let h = textHandle(at: vp) { return resizeCursor(h) }
            if onTextBorder(vp) { return PixelArt.moveCursor }
            if viewRect(textBoxRect).contains(vp) { return .iBeam }
        }
        if isSelectTool, let h = selectionHandle(at: vp) { return resizeCursor(h) }
        if let h = canvasHandle(at: vp) { return resizeCursor(h) }
        if isSelectTool, let sel = selection, sel.rect.contains(pixel(vp)) { return PixelArt.moveCursor }
        guard imageRect.contains(vp) else { return .arrow }
        switch state.tool {
        case .pencil: return PixelArt.pencilCursor
        case .fill: return PixelArt.fillCursor
        case .pick: return PixelArt.pickCursor
        case .magnifier: return PixelArt.magnifierCursor
        case .eraser: return PixelArt.eraserCursor(size: state.eraserSize, zoom: zoom)
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    private func resizeCursor(_ h: Int) -> NSCursor {
        switch h {
        case 1, 5: return .resizeUpDown
        case 3, 7: return .resizeLeftRight
        case 0, 4: return PixelArt.diagonalDownCursor
        default: return PixelArt.diagonalUpCursor
        }
    }

    func updateStatus(at p: IPoint? = nil) {
        guard let sb = statusBar else { return }
        if let p { sb.position = bitmap.contains(p.x, p.y) || dragging ? "\(p.x), \(p.y)" : "" }
        var size = ""
        if dragging {
            switch mode {
            case .shape: size = "\(abs(lastPt.x - startPt.x) + 1) × \(abs(lastPt.y - startPt.y) + 1)"
            case .selectRect, .textBox: if let r = dragRect { size = "\(r.w) × \(r.h)" }
            case .resizeCanvas: if let d = canvasDrag { size = "\(d.w) × \(d.h)" }
            default: break
            }
        }
        if size.isEmpty, let sel = selection { size = "\(sel.rect.w) × \(sel.rect.h)" }
        sb.selectionSize = size
        sb.imageSize = "\(bitmap.width) × \(bitmap.height)px"
        sb.zoom = "\(Int((zoom * 100).rounded()))%"
    }

    @objc private func stateChanged(_ n: Notification) {
        if state.tool != lastTool {
            lastTool = state.tool
            finishPending()
            commitText()
            commitSelection()
        }
        selection?.invalidate()
        applyTextStyle()
        needsDisplay = true
        refreshCursor()
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        switch Int(e.keyCode) {
        case 53: // Esc
            if dragging || curveActive || !poly.isEmpty { cancelCurrent() } else { commitSelection() }
        case 51, 117: // Backspace, Delete
            if selection != nil { delete(nil) } else { NSSound.beep() }
        case 123: nudge(-1, 0, e)
        case 124: nudge(1, 0, e)
        case 125: nudge(0, 1, e)
        case 126: nudge(0, -1, e)
        case 36, 76: // Return finishes a curve or polygon
            finishPending()
        default:
            super.keyDown(with: e)
        }
    }

    private func nudge(_ dx: Int, _ dy: Int, _ e: NSEvent) {
        guard let sel = selection, !dragging else { super.keyDown(with: e); return }
        let step = e.modifierFlags.contains(.shift) ? 10 : 1
        markSelectionDirty("Move")
        sel.rect.x += dx * step
        sel.rect.y += dy * step
        needsDisplay = true
    }

    override func flagsChanged(with e: NSEvent) {
        let s = e.modifierFlags.contains(.shift)
        guard s != shift else { return }
        shift = s
        if dragging, case .shape = mode { drawShape() }
    }

    // MARK: Zoom

    private static let zoomSteps: [CGFloat] = [0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16]

    func setZoom(_ z: CGFloat, around pixelPoint: CGPoint? = nil) {
        guard let sv = enclosingScrollView else { return }
        let vis = visibleRect
        let c = pixelPoint ?? CGPoint(x: vis.midX - margin, y: vis.midY - margin)
        sv.magnification = min(max(z, sv.minMagnification), sv.maxMagnification)
        updateFrame()
        let clip = sv.contentView
        let size = clip.bounds.size
        let target = NSRect(x: margin + c.x - size.width / 2, y: margin + c.y - size.height / 2, width: size.width, height: size.height)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        sv.reflectScrolledClipView(clip)
        refreshCursor()
    }

    @objc func zoomNormal(_ sender: Any?) { setZoom(1) }
    @objc func zoomLarge(_ sender: Any?) { setZoom(4) }
    @objc func zoomIn(_ sender: Any?) { setZoom(CanvasView.zoomSteps.first { $0 > zoom + 0.001 } ?? 16) }
    @objc func zoomOut(_ sender: Any?) { setZoom(CanvasView.zoomSteps.last { $0 < zoom - 0.001 } ?? 0.125) }
    @objc func zoomCustom(_ sender: Any?) { if let z = Dialogs.customZoom(current: zoom) { setZoom(z) } }

    @objc func viewBitmap(_ sender: Any?) {
        commitText()
        ViewBitmapWindow.show(flattened().image)
    }

    // MARK: Edit menu

    @objc func cut(_ sender: Any?) {
        copy(sender)
        delete(sender)
    }

    @objc func copy(_ sender: Any?) {
        guard let sel = selection else { return }
        sel.bake()
        Clipboard.write(sel.content.flattened(onto: state.secondary))
    }

    @objc func paste(_ sender: Any?) {
        guard let img = Clipboard.read() else { NSSound.beep(); return }
        place(img, name: "Paste")
    }

    /// Edit > Clear Selection.
    @objc func delete(_ sender: Any?) {
        guard selection != nil else { return }
        markSelectionDirty("Clear Selection")
        selection = nil
        changed()
        updateStatus()
    }

    override func selectAll(_ sender: Any?) {
        finishPending()
        commitText()
        commitSelection()
        state.selectTool(.select)
        liftRect(bitmap.bounds)
        updateStatus()
    }

    @objc func copyTo(_ sender: Any?) {
        guard let sel = selection, let window else { return }
        sel.bake()
        let image = sel.content.flattened(onto: state.secondary)
        let panel = NSSavePanel()
        panel.allowedContentTypes = PaintDocument.fileTypes
        panel.nameFieldStringValue = "Selection.png"
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.png.identifier
            if let data = image.encoded(as: uti) {
                do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
            }
        }
    }

    @objc func pasteFrom(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let img = Bitmap.load(data) else { return }
            self?.place(img, name: "Paste From")
        }
    }

    /// Pastes an image as a floating selection at the top-left of the visible area.
    private func place(_ img: Bitmap, name: String) {
        finishPending()
        commitText()
        commitSelection()
        let pre = bitmap.snapshot()
        if img.width > bitmap.width || img.height > bitmap.height {
            guard let enlarge = Dialogs.confirmEnlarge() else { return }
            if enlarge {
                bitmap.replace(with: bitmap.crop(IRect(x: 0, y: 0, w: max(img.width, bitmap.width), h: max(img.height, bitmap.height)),
                                                 fill: state.secondary))
                updateFrame()
            }
        }
        state.selectTool(.select)
        let vis = visibleRect
        let x = min(max(0, Int(floor(vis.minX - margin))), max(0, bitmap.width - img.width))
        let y = min(max(0, Int(floor(vis.minY - margin))), max(0, bitmap.height - img.height))
        selection = Selection(content: img, rect: IRect(x: x, y: y, w: img.width, h: img.height), preLift: pre, dirty: true)
        registerUndo(pre, name)
        changed()
        updateStatus()
    }

    // MARK: Image menu

    /// Applies `f` to the selection if there is one, otherwise to the whole picture.
    private func transform(_ name: String, _ f: (Bitmap, _ isSelection: Bool) -> Bitmap) {
        finishPending()
        commitText()
        if let sel = selection {
            markSelectionDirty(name)
            sel.bake()
            let nb = f(sel.content, true)
            sel.content = nb
            sel.rect.w = nb.width
            sel.rect.h = nb.height
            sel.invalidate()
        } else {
            let s = bitmap.snapshot()
            bitmap.replace(with: f(bitmap, false))
            registerUndo(s, name)
        }
        updateFrame()
        changed()
    }

    @objc func flipRotate(_ sender: Any?) {
        guard let op = Dialogs.flipRotate() else { return }
        transform("Flip/Rotate") { b, _ in
            switch op {
            case .flipHorizontal: return b.flippedHorizontally()
            case .flipVertical: return b.flippedVertically()
            case .rotate(let q): return b.rotated(q)
            }
        }
    }

    @objc func stretchSkew(_ sender: Any?) {
        guard let v = Dialogs.stretchSkew() else { return }
        let fill = state.secondary
        transform("Stretch/Skew") { b, isSelection in
            var out = b
            if v.stretchX != 100 || v.stretchY != 100 {
                out = out.scaled(max(1, Int((Double(b.width) * v.stretchX / 100).rounded())),
                                 max(1, Int((Double(b.height) * v.stretchY / 100).rounded())))
            }
            if v.skewX != 0 || v.skewY != 0 {
                out = out.skewed(degreesX: v.skewX, degreesY: v.skewY, fill: isSelection ? 0 : fill)
            }
            return out
        }
    }

    @objc func invertColors(_ sender: Any?) {
        transform("Invert Colors") { b, _ in b.inverted() }
    }

    @objc func imageAttributes(_ sender: Any?) {
        guard let (w, h) = Dialogs.attributes(width: bitmap.width, height: bitmap.height) else { return }
        finishPending()
        commitText()
        commitSelection()
        state.defaultImageSize = (w, h)
        resizeCanvas(w, h, name: "Attributes")
    }

    func resizeCanvas(_ w: Int, _ h: Int, name: String = "Resize") {
        guard w != bitmap.width || h != bitmap.height else { return }
        let s = bitmap.snapshot()
        bitmap.replace(with: bitmap.crop(IRect(x: 0, y: 0, w: w, h: h), fill: state.secondary))
        registerUndo(s, name)
        bitmapDidChange()
    }

    @objc func clearImage(_ sender: Any?) {
        finishPending()
        commitText()
        if selection != nil { delete(sender); return }
        let s = bitmap.snapshot()
        bitmap.fill(bitmap.bounds, state.secondary)
        registerUndo(s, "Clear Image")
        changed()
    }

    @objc func cropToSelection(_ sender: Any?) {
        guard let sel = selection else { return }
        finishPending()
        commitText()
        markSelectionDirty("Crop")
        sel.bake()
        let out = sel.content.flattened(onto: state.secondary)
        selection = nil
        bitmap.replace(with: out)
        bitmapDidChange()
    }

    @objc func setWallpaperCentered(_ sender: Any?) { setWallpaper(.scaleNone) }
    @objc func setWallpaperStretched(_ sender: Any?) { setWallpaper(.scaleAxesIndependently) }

    private func setWallpaper(_ scaling: NSImageScaling) {
        commitText()
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Classic Paint", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let old = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Wallpaper-") }
            // A new name each time: macOS caches desktop pictures by URL.
            let url = dir.appendingPathComponent("Wallpaper-\(UUID().uuidString).png")
            guard let data = flattened().encoded(as: UTType.png.identifier) else { return }
            try data.write(to: url)
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: scaling.rawValue,
                    .allowClipping: scaling != .scaleNone,
                    .fillColor: state.secondary.nsColor,
                ])
            }
            for f in old { try? fm.removeItem(at: f) }
        } catch {
            presentError(error)
        }
    }
}

extension CanvasView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(delete(_:)), #selector(copyTo(_:)), #selector(cropToSelection(_:)):
            return selection != nil
        case #selector(paste(_:)):
            return Clipboard.hasImage
        case #selector(zoomNormal(_:)):
            item.state = abs(zoom - 1) < 0.001 ? .on : .off
        case #selector(zoomLarge(_:)):
            item.state = abs(zoom - 4) < 0.001 ? .on : .off
        case #selector(zoomIn(_:)):
            return zoom < 16
        case #selector(zoomOut(_:)):
            return zoom > 0.125
        default:
            break
        }
        return true
    }
}
