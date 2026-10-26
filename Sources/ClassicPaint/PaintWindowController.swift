import AppKit

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Lays out the toolbox (left), color box and status bar (bottom) around the picture.
private final class PaintContentView: NSView {
    let toolbox: ToolboxView
    let colorBox: ColorBoxView
    let statusBar: StatusBarView
    let scrollView: NSScrollView

    init(toolbox: ToolboxView, colorBox: ColorBoxView, statusBar: StatusBarView, scrollView: NSScrollView) {
        self.toolbox = toolbox
        self.colorBox = colorBox
        self.statusBar = statusBar
        self.scrollView = scrollView
        super.init(frame: .zero)
        [scrollView, toolbox, colorBox, statusBar].forEach(addSubview)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: .paintStateChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc private func stateChanged() { arrange() }

    override func resizeSubviews(withOldSize oldSize: NSSize) { arrange() }

    func arrange() {
        let state = PaintState.shared
        let w = bounds.width
        var bottom = bounds.height
        statusBar.isHidden = !state.showStatusBar
        colorBox.isHidden = !state.showColorBox
        toolbox.isHidden = !state.showToolBox
        if state.showStatusBar {
            statusBar.frame = NSRect(x: 0, y: bottom - StatusBarView.height, width: w, height: StatusBarView.height)
            bottom -= StatusBarView.height
        }
        if state.showColorBox {
            colorBox.frame = NSRect(x: 0, y: bottom - ColorBoxView.height, width: w, height: ColorBoxView.height)
            bottom -= ColorBoxView.height
        }
        var left: CGFloat = 0
        if state.showToolBox {
            toolbox.frame = NSRect(x: 0, y: 0, width: ToolboxView.width, height: bottom)
            left = ToolboxView.width
        }
        scrollView.frame = NSRect(x: left, y: 0, width: max(0, w - left), height: max(0, bottom))
    }
}

final class PaintWindowController: NSWindowController, NSWindowDelegate {
    let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let statusBar = StatusBarView()

    init(document doc: PaintDocument) {
        canvas = CanvasView(document: doc)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 470)
        super.init(window: window)
        window.delegate = self

        scrollView.contentView = FlippedClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = Classic.workspace
        scrollView.drawsBackground = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.125
        scrollView.maxMagnification = 16

        let toolbox = ToolboxView(frame: .zero)
        toolbox.onHover = { [weak self] text in self?.statusBar.help = text ?? StatusBarView.defaultHelp }
        let content = PaintContentView(toolbox: toolbox, colorBox: ColorBoxView(frame: .zero), statusBar: statusBar, scrollView: scrollView)
        window.contentView = content
        content.arrange()

        canvas.statusBar = statusBar
        doc.canvas = canvas
        canvas.updateFrame()
        window.initialFirstResponder = canvas
        window.makeFirstResponder(canvas)
        window.center()
        windowFrameAutosaveName = "PaintWindow"
        shouldCascadeWindows = true

        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func magnified() { canvas.updateFrame() }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        "\(displayName) - Paint"
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }
}
