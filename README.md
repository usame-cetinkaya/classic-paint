# Classic Paint

A native macOS (AppKit, Apple Silicon) recreation of the classic Windows XP/7 Paint: toolbox, color box, aliased pixel drawing and the Windows keyboard shortcuts.

## Build

```bash
scripts/build.sh                      # dist/Classic Paint.app
INSTALL=1 scripts/build.sh            # also copies it to /Applications
CONFIGURATION=debug scripts/build.sh  # debug build (includes the self-test)
```

Only the Command Line Tools are needed (no Xcode). Release builds also produce `dist/Classic-Paint-<version>-arm64.dmg`.

## Releases

Pushing a version tag builds the DMG on GitHub Actions (Apple Silicon runner) and publishes it as a GitHub release:

```bash
git tag 1.0.0 && git push origin 1.0.0
```

The app is ad-hoc signed (no Developer ID), so the first launch needs right-click → Open, or System Settings → Privacy & Security → Open Anyway.

## Features

- All 16 tools: Free-Form Select, Select, Eraser/Color Eraser, Fill With Color, Pick Color, Magnifier, Pencil, Brush (12 tips), Airbrush, Text, Line, Curve, Rectangle, Polygon, Ellipse, Rounded Rectangle, with the classic options box.
- Left button draws with the foreground color, right button (or Ctrl-click) with the background color.
- Selections: move, Ctrl/Option-drag copy, Shift-drag smear, stretch handles, arrow-key nudge, Draw Opaque / transparent mode.
- Image menu: Flip/Rotate, Stretch/Skew, Invert Colors, Attributes (size in pixels, inches or cm; a Resolution setting, default 96 ppi, that you can set to your screen's pixels per inch so cm match a ruler at 100%, and that saved files and prints use), Clear Image, Crop.
- Zoom 12.5%–1600% (pinch too) with the pixel grid, View Bitmap, canvas resize handles.
- Opens and saves PNG, BMP, JPEG, GIF and TIFF; print; set as desktop background.
- Unlimited-ish undo (50 steps) and Repeat.

## Keyboard

Every ⌘ shortcut also works with Ctrl, as on Windows. Help > Help Topics (⌘?) lists them all.

| | |
|---|---|
| Undo / Repeat | ⌘Z / ⌘Y |
| Cut / Copy / Paste / Select All | ⌘X / ⌘C / ⌘V / ⌘A |
| Clear Selection | Delete |
| Tool Box / Color Box | ⌘T / ⌘L |
| Normal / Large size | ⌃PgUp / ⌃PgDn (also ⌘0) |
| Zoom in / out | ⌘= / ⌘- |
| Show Grid / View Bitmap | ⌘G / ⌘F |
| Flip/Rotate · Stretch/Skew | ⌘R · ⌃W |
| Invert Colors · Attributes | ⌘I · ⌘E |
| Clear Image · Crop | ⇧⌘N · ⇧⌘X |
| Brush/line size | ⌃+ / ⌃- |
| Bold / Italic / Underline (text) | ⌘B / ⌘I / ⌘U |

## Layout

- `CanvasView.swift`: all mouse tools, selections, text, zoom, Image/Edit menu actions.
- `Bitmap.swift`: RGBA pixel buffer + non-antialiased CoreGraphics context, flood fill, transforms, file encoding.
- `Selection.swift`: floating selection (lifted immediately; committed or undone as a single step).
- `PaintDocument.swift`: NSDocument file I/O, print, snapshot-based undo (one explicit group per change).
- `PaintState.swift`: tool/colors/options shared by all windows.
- `Toolbox.swift`, `PixelArt.swift`: toolbox, color box, status bar, pixel-art icons and cursors.
- `Panels.swift`, `Dialogs.swift`, `AppDelegate.swift`: text box, Fonts toolbar, dialogs, menus, Ctrl→⌘ shortcut mapping.
- `SelfTest.swift` (debug only): `CLASSIC_PAINT_SELFTEST=<dir>` drives a window with synthetic mouse events and writes screenshots.
