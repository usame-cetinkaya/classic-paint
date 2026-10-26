import AppKit

// `ClassicPaint --render-icon <dir>` writes the app icon as an .iconset (used by scripts/build.sh).
let args = CommandLine.arguments
if args.count == 3, args[1] == "--render-icon" {
    do {
        try PixelArt.renderAppIcon(to: args[2])
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
