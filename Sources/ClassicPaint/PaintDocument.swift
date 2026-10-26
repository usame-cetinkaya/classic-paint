import AppKit
import UniformTypeIdentifiers

@objc(PaintDocument)
final class PaintDocument: NSDocument {
    static let fileTypes: [UTType] = [.png, .bmp, .jpeg, .gif, .tiff]

    let bitmap: Bitmap
    weak var canvas: CanvasView?

    override init() {
        let (w, h) = PaintState.shared.defaultImageSize
        bitmap = Bitmap(width: w, height: h, fill: .white)
        super.init()
        undoManager?.levelsOfUndo = 50
        // Every picture change is registered as its own explicit group (see registerUndo).
        undoManager?.groupsByEvent = false
    }

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(PaintWindowController(document: self))
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        PaintDocument.fileTypes.map(\.identifier)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let img = Bitmap.load(data) else { throw CocoaError(.fileReadCorruptFile) }
        bitmap.replace(with: img)
        canvas?.reset()
    }

    override func data(ofType typeName: String) throws -> Data {
        let image = canvas?.flattened() ?? bitmap
        guard let data = image.encoded(as: typeName) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        canvas?.commitText()
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let image = canvas?.flattened() ?? bitmap
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
        view.image = NSImage(cgImage: image.image, size: view.frame.size)
        view.imageScaling = .scaleProportionallyDown
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        return NSPrintOperation(view: view, printInfo: info)
    }

    // MARK: Undo

    /// Registers an undo step that puts `snapshot` back.
    func registerUndo(_ snapshot: Snapshot, _ name: String) {
        guard let um = undoManager else { return }
        let explicit = !um.isUndoing && !um.isRedoing
        if explicit { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { doc in doc.applyUndo(snapshot, name) }
        um.setActionName(name)
        if explicit { um.endUndoGrouping() }
    }

    private func applyUndo(_ snapshot: Snapshot, _ name: String) {
        canvas?.prepareForUndo()
        let current = bitmap.snapshot()
        bitmap.restore(snapshot)
        registerUndo(current, name)
        canvas?.bitmapDidChange()
    }
}
