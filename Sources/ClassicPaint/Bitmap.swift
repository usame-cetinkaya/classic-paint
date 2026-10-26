import AppKit
import UniformTypeIdentifiers

/// One pixel, laid out in memory as R, G, B, A (premultiplied). Paint images are
/// always opaque; alpha 0 only appears inside free-form selections.
typealias Pixel = UInt32

@inline(__always) func rgb(_ r: Int, _ g: Int, _ b: Int) -> Pixel {
    0xFF00_0000 | Pixel(b & 255) << 16 | Pixel(g & 255) << 8 | Pixel(r & 255)
}

extension Pixel {
    static let black = rgb(0, 0, 0)
    static let white = rgb(255, 255, 255)

    var red: Int { Int(self & 0xFF) }
    var green: Int { Int((self >> 8) & 0xFF) }
    var blue: Int { Int((self >> 16) & 0xFF) }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> Int { Int((Swift.min(Swift.max(v, 0), 1) * 255).rounded()) }
        self = rgb(byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

struct IPoint: Equatable {
    var x: Int
    var y: Int
}

struct IRect: Equatable {
    var x: Int, y: Int, w: Int, h: Int

    var maxX: Int { x + w }
    var maxY: Int { y + h }
    var isEmpty: Bool { w <= 0 || h <= 0 }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    func contains(_ p: IPoint) -> Bool { p.x >= x && p.y >= y && p.x < maxX && p.y < maxY }

    func intersection(_ o: IRect) -> IRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return IRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }

    func insetBy(_ d: Int) -> IRect { IRect(x: x + d, y: y + d, w: w - 2 * d, h: h - 2 * d) }

    /// The rectangle with `a` and `b` as opposite corner pixels (both included).
    static func spanning(_ a: IPoint, _ b: IPoint) -> IRect {
        IRect(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(a.x - b.x) + 1, h: abs(a.y - b.y) + 1)
    }
}

struct Snapshot {
    let width: Int
    let height: Int
    let pixels: [Pixel]
}

/// A brush tip: the pixels painted around each point of a stroke.
struct Stamp {
    let offsets: [(Int, Int)]

    static let dot = Stamp(offsets: [(0, 0)])
    private static let pens = (0...16).map { disk($0) }

    static func pen(_ width: Int) -> Stamp { pens[min(max(width, 1), 16)] }

    static func disk(_ d: Int) -> Stamp {
        guard d > 1 else { return .dot }
        let r = Double(d) / 2
        var o: [(Int, Int)] = []
        for j in 0..<d {
            for i in 0..<d {
                let dx = Double(i) + 0.5 - r, dy = Double(j) + 0.5 - r
                if dx * dx + dy * dy <= r * r + 0.25 { o.append((i - d / 2, j - d / 2)) }
            }
        }
        return Stamp(offsets: o)
    }

    static func square(_ d: Int) -> Stamp {
        var o: [(Int, Int)] = []
        for j in 0..<d { for i in 0..<d { o.append((i - d / 2, j - d / 2)) } }
        return Stamp(offsets: o)
    }

    static func slash(_ n: Int) -> Stamp { Stamp(offsets: (0..<n).map { ($0 - n / 2, n - 1 - $0 - n / 2) }) }
    static func backslash(_ n: Int) -> Stamp { Stamp(offsets: (0..<n).map { ($0 - n / 2, $0 - n / 2) }) }
}

/// Calls `plot` for every pixel on the line from `a` to `b`.
func bresenham(_ a: IPoint, _ b: IPoint, _ plot: (Int, Int) -> Void) {
    var x = a.x, y = a.y
    let dx = abs(b.x - x), sx = x < b.x ? 1 : -1
    let dy = -abs(b.y - y), sy = y < b.y ? 1 : -1
    var err = dx + dy
    while true {
        plot(x, y)
        if x == b.x && y == b.y { break }
        let e2 = 2 * err
        if e2 >= dy { err += dy; x += sx }
        if e2 <= dx { err += dx; y += sy }
    }
}

/// A pixel buffer with a CoreGraphics context drawing into it. The context uses
/// top-left origin coordinates and never antialiases, like the original Paint.
final class Bitmap {
    /// Pixels per inch, set in Image > Attributes (default 96 like Windows). Set it to the
    /// screen's real pixels per inch and 100% zoom shows true size. Attributes converts
    /// inches/cm with it, and saved files and prints carry it.
    static var dpi: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "Resolution")
            return v > 0 ? v : 96
        }
        set { UserDefaults.standard.set(newValue, forKey: "Resolution") }
    }
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: UnsafeMutablePointer<Pixel>
    private(set) var context: CGContext
    private var cachedImage: CGImage?

    var count: Int { width * height }
    var bounds: IRect { IRect(x: 0, y: 0, w: width, h: height) }

    init(width: Int, height: Int, fill: Pixel) {
        let w = max(1, width), h = max(1, height)
        self.width = w
        self.height = h
        pixels = .allocate(capacity: w * h)
        pixels.initialize(repeating: fill, count: w * h)
        context = Bitmap.makeContext(pixels, w, h)
    }

    /// Loads an image, flattening any transparency onto `background`.
    convenience init(cgImage: CGImage, background: Pixel = .white) {
        self.init(width: cgImage.width, height: cgImage.height, fill: background)
        draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    deinit { pixels.deallocate() }

    private static func makeContext(_ p: UnsafeMutablePointer<Pixel>, _ w: Int, _ h: Int) -> CGContext {
        let ctx = CGContext(data: p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: colorSpace, bitmapInfo: bitmapInfo)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        return ctx
    }

    private func reallocate(_ w: Int, _ h: Int) {
        pixels.deallocate()
        width = w
        height = h
        pixels = .allocate(capacity: w * h)
        context = Bitmap.makeContext(pixels, w, h)
        cachedImage = nil
    }

    /// Must be called after writing to `pixels` directly.
    func touch() { cachedImage = nil }

    var image: CGImage {
        if let cachedImage { return cachedImage }
        let data = Data(bytes: pixels, count: count * 4) as CFData
        let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                          space: Bitmap.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Bitmap.bitmapInfo),
                          provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
                          intent: .defaultIntent)!
        cachedImage = img
        return img
    }

    // MARK: Pixels

    @inline(__always) func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }
    @inline(__always) func get(_ x: Int, _ y: Int) -> Pixel { pixels[y * width + x] }
    @inline(__always) func plot(_ x: Int, _ y: Int, _ c: Pixel) {
        if contains(x, y) { pixels[y * width + x] = c }
    }

    func snapshot() -> Snapshot {
        Snapshot(width: width, height: height, pixels: Array(UnsafeBufferPointer(start: pixels, count: count)))
    }

    func restore(_ s: Snapshot) {
        if s.width != width || s.height != height { reallocate(s.width, s.height) }
        s.pixels.withUnsafeBufferPointer { pixels.update(from: $0.baseAddress!, count: count) }
        touch()
    }

    func replace(with other: Bitmap) {
        if other.width != width || other.height != height { reallocate(other.width, other.height) }
        pixels.update(from: other.pixels, count: count)
        touch()
    }

    func copy() -> Bitmap {
        let b = Bitmap(width: width, height: height, fill: 0)
        b.pixels.update(from: pixels, count: count)
        return b
    }

    /// The pixels inside `r`; parts of `r` outside the image become `fill`.
    func crop(_ r: IRect, fill: Pixel = 0) -> Bitmap {
        let out = Bitmap(width: r.w, height: r.h, fill: fill)
        let i = r.intersection(bounds)
        guard !i.isEmpty else { return out }
        for y in i.y..<i.maxY {
            (out.pixels + (y - r.y) * out.width + (i.x - r.x)).update(from: pixels + y * width + i.x, count: i.w)
        }
        return out
    }

    func fill(_ r: IRect, _ c: Pixel) {
        let i = r.intersection(bounds)
        guard !i.isEmpty else { return }
        for y in i.y..<i.maxY { (pixels + y * width + i.x).update(repeating: c, count: i.w) }
        touch()
    }

    /// Draws `img` upright into `r` (top-left coordinates), nearest-neighbor scaled.
    func draw(_ img: CGImage, in r: CGRect) {
        context.saveGState()
        context.translateBy(x: r.minX, y: r.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(img, in: CGRect(origin: .zero, size: r.size))
        context.restoreGState()
        touch()
    }

    func fillPath(_ path: CGPath, _ c: Pixel) {
        context.setFillColor(c.cgColor)
        context.addPath(path)
        context.fillPath()
        touch()
    }

    // MARK: Strokes

    func stamp(_ s: Stamp, _ x: Int, _ y: Int, _ c: Pixel) {
        for o in s.offsets { plot(x + o.0, y + o.1, c) }
    }

    func strokeLine(_ a: IPoint, _ b: IPoint, _ pen: Stamp, _ c: Pixel) {
        bresenham(a, b) { x, y in stamp(pen, x, y, c) }
        touch()
    }

    func strokePolyline(_ pts: [IPoint], closed: Bool, _ pen: Stamp, _ c: Pixel) {
        guard let first = pts.first else { return }
        if pts.count == 1 { stamp(pen, first.x, first.y, c) }
        for i in 1..<max(pts.count, 1) { strokeLine(pts[i - 1], pts[i], pen, c) }
        if closed, pts.count > 2 { strokeLine(pts[pts.count - 1], first, pen, c) }
        touch()
    }

    /// A rectangle outline `w` pixels thick, drawn inside `r`.
    func strokeRect(_ r: IRect, _ w: Int, _ c: Pixel) {
        fill(IRect(x: r.x, y: r.y, w: r.w, h: min(w, r.h)), c)
        fill(IRect(x: r.x, y: r.maxY - w, w: r.w, h: min(w, r.h)), c)
        fill(IRect(x: r.x, y: r.y, w: min(w, r.w), h: r.h), c)
        fill(IRect(x: r.maxX - w, y: r.y, w: min(w, r.w), h: r.h), c)
    }

    /// Scanline flood fill of the area that has exactly the color at (x, y).
    @discardableResult
    func floodFill(_ x: Int, _ y: Int, _ color: Pixel) -> Bool {
        guard contains(x, y) else { return false }
        let target = get(x, y)
        guard target != color else { return false }
        let w = width, h = height, p = pixels
        var stack = [(x, y)]
        while let (sx, sy) = stack.popLast() {
            let row = sy * w
            guard p[row + sx] == target else { continue }
            var l = sx, r = sx
            while l > 0 && p[row + l - 1] == target { l -= 1 }
            while r < w - 1 && p[row + r + 1] == target { r += 1 }
            for i in l...r { p[row + i] = color }
            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < h {
                let nrow = ny * w
                var i = l
                while i <= r {
                    if p[nrow + i] == target {
                        stack.append((i, ny))
                        while i <= r && p[nrow + i] == target { i += 1 }
                    } else {
                        i += 1
                    }
                }
            }
        }
        touch()
        return true
    }

    // MARK: Image transforms (return new bitmaps)

    private func remapped(_ w: Int, _ h: Int, _ source: (Int, Int) -> (Int, Int)) -> Bitmap {
        let out = Bitmap(width: w, height: h, fill: 0)
        for y in 0..<h {
            for x in 0..<w {
                let (sx, sy) = source(x, y)
                out.pixels[y * w + x] = pixels[sy * width + sx]
            }
        }
        return out
    }

    func flippedHorizontally() -> Bitmap { remapped(width, height) { (self.width - 1 - $0, $1) } }
    func flippedVertically() -> Bitmap { remapped(width, height) { ($0, self.height - 1 - $1) } }

    /// Rotates clockwise by 90° × `quarterTurns`.
    func rotated(_ quarterTurns: Int) -> Bitmap {
        let w = width, h = height
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: return remapped(h, w) { ($1, h - 1 - $0) }
        case 2: return remapped(w, h) { (w - 1 - $0, h - 1 - $1) }
        case 3: return remapped(h, w) { (w - 1 - $1, $0) }
        default: return copy()
        }
    }

    func inverted() -> Bitmap {
        let b = copy()
        for i in 0..<count where b.pixels[i] >> 24 != 0 { b.pixels[i] ^= 0x00FF_FFFF }
        return b
    }

    func scaled(_ w: Int, _ h: Int) -> Bitmap {
        let b = Bitmap(width: w, height: h, fill: 0)
        b.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return b
    }

    func skewed(degreesX: Double, degreesY: Double, fill: Pixel) -> Bitmap {
        var b = self
        if degreesX != 0 {
            let t = tan(degreesX * .pi / 180)
            let extra = Int((abs(t) * Double(b.height)).rounded())
            let out = Bitmap(width: b.width + extra, height: b.height, fill: fill)
            out.context.saveGState()
            out.context.concatenate(CGAffineTransform(a: 1, b: 0, c: CGFloat(t), d: 1, tx: t < 0 ? CGFloat(extra) : 0, ty: 0))
            out.draw(b.image, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
            out.context.restoreGState()
            b = out
        }
        if degreesY != 0 {
            let t = tan(degreesY * .pi / 180)
            let extra = Int((abs(t) * Double(b.width)).rounded())
            let out = Bitmap(width: b.width, height: b.height + extra, fill: fill)
            out.context.saveGState()
            out.context.concatenate(CGAffineTransform(a: 1, b: CGFloat(t), c: 0, d: 1, tx: 0, ty: t < 0 ? CGFloat(extra) : 0))
            out.draw(b.image, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
            out.context.restoreGState()
            b = out
        }
        return b === self ? copy() : b
    }

    /// This bitmap with transparent pixels filled with `background`.
    func flattened(onto background: Pixel) -> Bitmap {
        let b = Bitmap(width: width, height: height, fill: background)
        b.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return b
    }

    // MARK: Files

    static func load(_ data: Data) -> Bitmap? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return Bitmap(cgImage: img)
    }

    /// Encodes as the given UTI (PNG, BMP, JPEG, GIF or TIFF) without an alpha channel.
    func encoded(as uti: String) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Bitmap.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else { return nil }
        // Without this, other apps assume 72 dpi and show or print the picture a third too large.
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: Bitmap.dpi, kCGImagePropertyDPIHeight: Bitmap.dpi]
        if uti == UTType.jpeg.identifier { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, opaque, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
