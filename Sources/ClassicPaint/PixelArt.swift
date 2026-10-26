import AppKit

/// Windows Classic look: 3D bevels in the "button face" palette.
enum Classic {
    static let face = NSColor(srgbRed: 212 / 255, green: 208 / 255, blue: 200 / 255, alpha: 1)
    static let pressed = NSColor(srgbRed: 236 / 255, green: 234 / 255, blue: 230 / 255, alpha: 1)
    static let light = NSColor.white
    static let shadow = NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1)
    static let dark = NSColor(srgbRed: 64 / 255, green: 64 / 255, blue: 64 / 255, alpha: 1)
    static let navy = NSColor(srgbRed: 10 / 255, green: 36 / 255, blue: 106 / 255, alpha: 1)
    static let workspace = NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1)

    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
        c.setFill()
        NSRect(x: x, y: y, width: w, height: h).fill()
    }

    /// Raised button edge (flipped coordinates).
    static func raised(_ r: NSRect) {
        box(r.minX, r.minY, r.width - 1, 1, light)
        box(r.minX, r.minY, 1, r.height - 1, light)
        box(r.minX, r.maxY - 1, r.width, 1, dark)
        box(r.maxX - 1, r.minY, 1, r.height, dark)
        box(r.minX + 1, r.maxY - 2, r.width - 2, 1, shadow)
        box(r.maxX - 2, r.minY + 1, 1, r.height - 2, shadow)
    }

    /// Sunken well edge (flipped coordinates).
    static func sunken(_ r: NSRect) {
        box(r.minX, r.minY, r.width - 1, 1, shadow)
        box(r.minX, r.minY, 1, r.height - 1, shadow)
        box(r.minX, r.maxY - 1, r.width, 1, light)
        box(r.maxX - 1, r.minY, 1, r.height, light)
        box(r.minX + 1, r.minY + 1, r.width - 3, 1, dark)
        box(r.minX + 1, r.minY + 1, 1, r.height - 3, dark)
    }

    /// One-pixel sunken edge, used by status bar panes.
    static func thinSunken(_ r: NSRect) {
        box(r.minX, r.minY, r.width, 1, shadow)
        box(r.minX, r.minY, 1, r.height, shadow)
        box(r.minX, r.maxY - 1, r.width, 1, light)
        box(r.maxX - 1, r.minY, 1, r.height, light)
    }
}

/// 16×16 pixel-art icons and cursors, described as text grids.
enum PixelArt {
    static let colors: [Character: NSColor] = [
        "k": .black, "w": .white,
        "g": NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        "l": NSColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1),
        "r": NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        "m": NSColor(srgbRed: 0.5, green: 0, blue: 0, alpha: 1),
        "y": NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1),
        "o": NSColor(srgbRed: 0.5, green: 0.5, blue: 0, alpha: 1),
        "b": NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        "n": NSColor(srgbRed: 0, green: 0, blue: 0.5, alpha: 1),
        "c": NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1),
        "t": NSColor(srgbRed: 0, green: 0.5, blue: 0.5, alpha: 1),
        "e": NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1),
        "p": NSColor(srgbRed: 1, green: 0.6, blue: 0.75, alpha: 1),
    ]

    static func image(_ rows: [String], size: Int = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = colors[ch] else { continue }
                    c.setFill()
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
    }

    private static var iconCache: [Tool: NSImage] = [:]

    static func icon(_ tool: Tool) -> NSImage {
        if let i = iconCache[tool] { return i }
        let i = image(art[tool.rawValue])
        iconCache[tool] = i
        return i
    }

    static let art: [[String]] = [
        [ // free-form select
            "................",
            "......k.k.k.....",
            "....k.......k...",
            "..k...........k.",
            "................",
            ".k............k.",
            "...............k",
            ".k..............",
            "..............k.",
            "..k.............",
            "...k.........k..",
            "............k...",
            "....k.k...k.....",
            "........k.......",
        ],
        [ // select
            "................",
            "................",
            ".k.k.k.k.k.k.k..",
            "................",
            ".k...........k..",
            "................",
            ".k...........k..",
            "................",
            ".k...........k..",
            "................",
            ".k...........k..",
            "................",
            ".k.k.k.k.k.k.k..",
        ],
        [ // eraser
            "................",
            "................",
            "................",
            ".......kkkkkkkk.",
            "......kwwwwwwkk.",
            ".....kwwwwwwkyk.",
            "....kwwwwwwkyyk.",
            "...kwwwwwwkyyk..",
            "..kkkkkkkkyyk...",
            "..kyyyyyykyk....",
            "..kyyyyyykk.....",
            "..kkkkkkkk......",
        ],
        [ // fill with color
            "................",
            ".....kk.........",
            "....k..k........",
            "....k..kk.......",
            "....k.kwlk......",
            "...kkwwwllk.....",
            "..kwkwwwwllk....",
            ".kwwwkwwwwllk...",
            "kwwwwwkwwwwlkb..",
            ".kwwwwwkwwlk.bb.",
            "..kwwwwwwlk..bb.",
            "...kwwwwlk...bbb",
            "....kwwlk....bbb",
            ".....kkk......b.",
        ],
        [ // pick color
            "................",
            "...........kkk..",
            "..........kkkkk.",
            "..........kkkkk.",
            ".........kkkkk..",
            "........kwkkk...",
            ".......kwwk.....",
            "......kwwk......",
            ".....kwwk.......",
            "....kwwk........",
            "...kwwk.........",
            "..kwwk..........",
            "..kwk...........",
            ".k.k............",
            "k...............",
        ],
        [ // magnifier
            "................",
            "....kkkk........",
            "...k....k.......",
            "..k.ww...k......",
            "..k.w....k......",
            "..k......k......",
            "..k......k......",
            "...k....k.......",
            "....kkkkk.......",
            "........kk......",
            ".........kk.....",
            "..........kk....",
            "...........kk...",
            "............k...",
        ],
        [ // pencil
            "................",
            "............kk..",
            "...........kmmk.",
            "..........kwkmk.",
            ".........kyyykk.",
            "........kyyyk...",
            ".......kyyyk....",
            "......kyyyk.....",
            ".....kyyyk......",
            "....kyyyk.......",
            "...kwyyk........",
            "...kwwk.........",
            "..kkkk..........",
            "..kk............",
        ],
        [ // brush
            "................",
            "............kk..",
            "...........kook.",
            "..........kook..",
            ".........kook...",
            "........kook....",
            ".......kllk.....",
            "......kllk......",
            ".....kbbk.......",
            "....kbbbk.......",
            "...kbbbk........",
            "...kbbk.........",
            "..kbk...........",
            "..kk............",
        ],
        [ // airbrush
            "................",
            ".k..k...........",
            "...k..k.kk......",
            ".k..k..kggk.....",
            "...k..k.kk......",
            ".k..k..kkkk.....",
            "......klllk.....",
            "......klllk.....",
            "......kgggk.....",
            "......kgggk.....",
            "......kgggk.....",
            "......kgggk.....",
            "......kgggk.....",
            "......kkkkk.....",
        ],
        [ // text
            "................",
            "................",
            ".......k........",
            "......kkk.......",
            "......kkk.......",
            ".....kk.kk......",
            ".....kk.kk......",
            "....kk...kk.....",
            "....kkkkkkk.....",
            "...kk.....kk....",
            "...kk.....kk....",
            "..kkkk...kkkk...",
        ],
        [ // line
            "................",
            "..............k.",
            ".............k..",
            "............k...",
            "...........k....",
            "..........k.....",
            ".........k......",
            "........k.......",
            ".......k........",
            "......k.........",
            ".....k..........",
            "....k...........",
            "...k............",
            "..k.............",
            ".k..............",
        ],
        [ // curve
            "................",
            "................",
            "...........kk...",
            "..........k..k..",
            ".........k......",
            "........k.......",
            "........k.......",
            ".......k........",
            ".......k........",
            "......k.........",
            "..k..k..........",
            "...kk...........",
        ],
        [ // rectangle
            "................",
            "................",
            "................",
            "..kkkkkkkkkkkk..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..kkkkkkkkkkkk..",
        ],
        [ // polygon
            "................",
            "................",
            "....kkkkkkk.....",
            "....k.....k.....",
            "....k......k....",
            "....k.......k...",
            "...k.........k..",
            "...k.........k..",
            "..k......kkkkk..",
            "..k......k......",
            "..kkkkkkkk......",
        ],
        [ // ellipse
            "................",
            "................",
            "................",
            ".....kkkkkk.....",
            "...kk......kk...",
            "..k..........k..",
            ".k............k.",
            ".k............k.",
            ".k............k.",
            "..k..........k..",
            "...kk......kk...",
            ".....kkkkkk.....",
        ],
        [ // rounded rectangle
            "................",
            "................",
            "................",
            "...kkkkkkkkkk...",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "..k..........k..",
            "...kkkkkkkkkk...",
        ],
    ]

    // MARK: Cursors

    private static func cursor(_ rows: [String], _ x: Int, _ y: Int) -> NSCursor {
        NSCursor(image: image(rows), hotSpot: NSPoint(x: x, y: y))
    }

    static let pencilCursor = cursor(art[Tool.pencil.rawValue], 2, 13)
    static let fillCursor = cursor(art[Tool.fill.rawValue], 14, 13)
    static let pickCursor = cursor(art[Tool.pick.rawValue], 0, 14)
    static let magnifierCursor = cursor(art[Tool.magnifier.rawValue], 5, 5)

    static let moveCursor = cursor([
        ".......k.......",
        "......kwk......",
        ".....kwwwk.....",
        "....kkkwkkk....",
        "...k..kwk..k...",
        "..kk..kwk..kk..",
        ".kwkkkkwkkkkwk.",
        "kwwwwwwwwwwwwwk",
        ".kwkkkkwkkkkwk.",
        "..kk..kwk..kk..",
        "...k..kwk..k...",
        "....kkkwkkk....",
        ".....kwwwk.....",
        "......kwk......",
        ".......k.......",
    ], 7, 7)

    private static let diagonalRows = [
        "kkkkkk.........",
        "kwwwwk.........",
        "kwwwk..........",
        "kwwwwk.........",
        "kwk.kwk........",
        "kk...kwk.......",
        "......kwk......",
        ".......kwk.....",
        "........kwk...k",
        ".........kwk.kk",
        "..........kwkwk",
        "...........wwwk",
        "..........kwwwk",
        ".........kwwwwk",
        ".........kkkkkk",
    ]
    /// Resize cursor for the top-left / bottom-right corners.
    static let diagonalDownCursor = cursor(diagonalRows, 7, 7)
    /// Resize cursor for the top-right / bottom-left corners.
    static let diagonalUpCursor = cursor(diagonalRows.map { String($0.reversed()) }, 7, 7)

    private static var eraserCursors: [Int: NSCursor] = [:]

    /// A square outline the size of the eraser at the current zoom.
    static func eraserCursor(size: Int, zoom: CGFloat) -> NSCursor {
        let side = max(4, min(128, (CGFloat(size) * zoom).rounded()))
        let key = Int(side)
        if let c = eraserCursors[key] { return c }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSColor.white.setFill()
            r.fill()
            NSColor.black.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: side / 2, y: side / 2))
        eraserCursors[key] = c
        return c
    }

    // MARK: App icon

    static let appIconArt = [
        "................",
        ".kkkkkkkkkkkk...",
        ".kwwwwwwwwwwk...",
        ".kwcccccyycwk...",
        ".kwccccyyyywk..k",
        ".kwcccccyycwk.ko",
        ".kwccccccccwkkok",
        ".kweeccccccwkok.",
        ".kweeeecceekok..",
        ".kweeeeeeekok...",
        ".kwwwwwwwkok....",
        ".kkkkkkkklk.....",
        "........klk.....",
        "......krk.......",
        ".....krk........",
        "....kk..........",
    ]

    static func drawAppIcon(size s: CGFloat) {
        let inset = s * 0.09
        let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: body, xRadius: s * 0.19, yRadius: s * 0.19)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.92, blue: 0.89, alpha: 1),
                                  ending: NSColor(srgbRed: 0.78, green: 0.76, blue: 0.72, alpha: 1))
        gradient?.draw(in: path, angle: -90)
        NSColor(white: 0.35, alpha: 1).setStroke()
        path.lineWidth = max(1, s / 160)
        path.stroke()

        let cell = body.width * 0.8 / 16
        let ox = (s - cell * 16) / 2, oy = (s - cell * 16) / 2
        for (y, row) in appIconArt.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let c = colors[ch] else { continue }
                c.setFill()
                // Unflipped context: row 0 at the top.
                NSRect(x: ox + CGFloat(x) * cell, y: s - oy - CGFloat(y + 1) * cell, width: cell, height: cell).fill()
            }
        }
    }

    /// Writes an .iconset folder for `iconutil`.
    static func renderAppIcon(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                drawAppIcon(size: CGFloat(px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
