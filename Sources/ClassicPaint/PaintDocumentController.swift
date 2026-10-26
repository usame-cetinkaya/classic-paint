import AppKit

/// Like Paint, opening a file replaces the picture in the front window
/// (after offering to save it) instead of opening another window.
final class PaintDocumentController: NSDocumentController {
    private struct PendingOpen {
        let url: URL
        let windowController: PaintWindowController
        let completion: (NSDocument?, Bool, Error?) -> Void
    }

    private var pending: PendingOpen?

    override func openDocument(withContentsOf url: URL, display: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard display, pending == nil, document(for: url) == nil,
              let window = NSApp.mainWindow ?? NSApp.orderedWindows.first(where: { $0.windowController is PaintWindowController }),
              let wc = window.windowController as? PaintWindowController,
              let current = wc.document as? PaintDocument else {
            super.openDocument(withContentsOf: url, display: display, completionHandler: completionHandler)
            return
        }
        pending = PendingOpen(url: url, windowController: wc, completion: completionHandler)
        // Shows "Do you want to save the changes…?" when the picture is edited.
        current.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let p = pending else { return }
        pending = nil
        guard shouldClose else {
            p.completion(nil, false, CocoaError(.userCancelled))
            return
        }
        super.openDocument(withContentsOf: p.url, display: false) { newDoc, wasOpen, error in
            guard let newDoc = newDoc as? PaintDocument, !wasOpen else {
                newDoc?.showWindows()
                p.completion(newDoc, wasOpen, error)
                return
            }
            let wc = p.windowController
            doc.removeWindowController(wc)
            newDoc.addWindowController(wc)
            wc.canvas.attach(newDoc)
            wc.synchronizeWindowTitleWithDocumentName()
            doc.close()
            newDoc.showWindows()
            p.completion(newDoc, false, nil)
        }
    }
}
