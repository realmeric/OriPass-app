import AppKit

/// The icon the bundle carries, which `scripts/make-icon.swift` drew into
/// `Assets.xcassets` and the build compiled. The Dock and the Finder draw
/// it, and in the app the About room does. `make shots` writes it beside
/// the surfaces at the three sizes a card asked for, to be looked at.
enum AppIcon {
    static let name = "AppIcon"

    /// Nil when the bundle has none. `NSApp.applicationIconImage` would
    /// answer with the system's blank application instead, and say nothing.
    static var image: NSImage? { Bundle.main.image(forResource: name) }

    /// In points: the Dock at its smallest, a row of the Finder's list, and
    /// the size the artwork is judged at.
    static let renders = [16, 32, 512]

    static func file(_ points: Int) -> String { "icon-\(points).png" }

    enum Failure: Error { case noBitmap }

    /// `icon` at `points`, two pixels to the point as every shot is, on
    /// nothing: the image picks the size it holds for that many pixels, so
    /// the sixteen is the file drawn for sixteen and not the largest made
    /// small.
    static func png(of icon: NSImage, points: Int) throws -> Data {
        let pixels = points * 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw Failure.noBitmap }
        // Before the context is made, which takes its scale from this.
        bitmap.size = NSSize(width: points, height: points)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.noBitmap }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(origin: .zero, size: bitmap.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.noBitmap }
        return png
    }
}
