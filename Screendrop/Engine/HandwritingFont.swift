import AppKit
import CoreText
import Foundation

/// Caveat, the marker-handwriting face behind `AnnoFontFamily.handwriting`.
///
/// It ships inside the app (`Caveat.ttf`, with its licence beside it) so text set in it looks the
/// same on every Mac. The file is a variable font with a weight axis from 400 to 700.
nonisolated enum HandwritingFont {
    /// Names a directory holding `Caveat.ttf`, for code that runs outside the app bundle, such as
    /// `scripts/check-annotation-ink.swift`. Set it before the first use.
    static let directoryEnvironmentKey = "SCREENDROP_FONTS_DIR"

    private static let weightAxis = 0x7767_6874 // 'wght'

    /// Loaded and registered with the process on first use. A `static let` is initialised once,
    /// atomically, so the canvas on the main actor and an export on a detached task can both reach
    /// it first. `nil` when the file is missing or unreadable, and text then falls back to SF Pro.
    private static let descriptor: NSFontDescriptor? = {
        guard let url = fontURL(),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        // Registering lets the text view and anything that round-trips the font by name resolve it.
        // An already-registered file reports an error here and is still usable.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return first as NSFontDescriptor
    }()

    private static func fontURL() -> URL? {
        if let directory = ProcessInfo.processInfo.environment[directoryEnvironmentKey] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("Caveat.ttf")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return Bundle.main.url(forResource: "Caveat", withExtension: "ttf")
    }

    /// Caveat at weight 700 when bold, 400 otherwise. It has no italic, and none is synthesised.
    static func font(size: CGFloat, isBold: Bool) -> NSFont? {
        guard let descriptor else { return nil }
        let weighted = descriptor.addingAttributes([
            kCTFontVariationAttribute as NSFontDescriptor.AttributeName: [weightAxis: isBold ? 700 : 400],
        ])
        return NSFont(descriptor: weighted, size: size)
    }
}
