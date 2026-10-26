import AppKit

/// A selection floating above the canvas. It is lifted out of the picture as soon
/// as it is made (leaving the background color behind), so moving, stretching,
/// flipping, etc. only touch `content` until it is dropped back with `commit`.
final class Selection {
    /// Pixels of the selection; alpha 0 outside a free-form outline.
    var content: Bitmap
    /// Where the content sits on the canvas; may differ in size when stretched.
    var rect: IRect
    /// The canvas before lifting. Committing an unchanged selection restores it
    /// exactly, and it is the undo state of a changed one.
    let preLift: Snapshot
    /// Moved or modified (an undo step has been registered).
    var dirty: Bool

    private var overlayCache: CGImage?
    private var overlayKey: Int64 = -2

    init(content: Bitmap, rect: IRect, preLift: Snapshot, dirty: Bool) {
        self.content = content
        self.rect = rect
        self.preLift = preLift
        self.dirty = dirty
    }

    /// The content as drawn: with `transparentKey`, pixels of that color are see-through.
    func overlay(transparentKey: Pixel?) -> CGImage {
        let key = transparentKey.map { Int64($0) } ?? -1
        if let overlayCache, overlayKey == key { return overlayCache }
        let img: CGImage
        if let k = transparentKey {
            let b = content.copy()
            for i in 0..<b.count where b.pixels[i] == k { b.pixels[i] = 0 }
            b.touch()
            img = b.image
        } else {
            img = content.image
        }
        overlayCache = img
        overlayKey = key
        return img
    }

    func invalidate() { overlayCache = nil }

    /// Applies a pending stretch so `content` matches `rect`.
    func bake() {
        guard rect.w != content.width || rect.h != content.height else { return }
        content = content.scaled(rect.w, rect.h)
        invalidate()
    }
}
