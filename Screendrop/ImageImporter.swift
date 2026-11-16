import AppKit
import UniformTypeIdentifiers

/// Brings images from outside Screendrop into the Library and opens them in
/// the annotation editor. Finder's Open With and File → Open… both land here.
/// The import copies the file, so the original is never edited.
final class ImageImporter {
    static let shared = ImageImporter()

    /// Opens a history image in an annotation editor. The app scene sets it,
    /// since only a scene can reach `openWindow`.
    var openEditor: ((URL) -> Void)?

    private init() {}

    /// Imports each image and opens it in its own editor. Anything that is
    /// not an image is skipped.
    func open(_ urls: [URL]) {
        for url in Self.imageURLs(in: urls) {
            openEditor?(ScreenshotHistoryStore.shared.importScreenshot(from: url))
        }
    }

    func presentOpenPanel() {
        // From the menu bar the app is usually inactive, and the panel
        // would open behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Open Image"
        panel.message = "Choose images to annotate. Screendrop edits a copy and leaves the originals unchanged."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            self.open(panel.urls)
        }
    }

    /// Opens the image on the clipboard in an editor. Image files copied in
    /// Finder open as themselves; Finder also puts their icons on the
    /// clipboard, so files are checked before image data. Beeps when the
    /// clipboard holds no image.
    func annotateClipboard() {
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            open(fileURLs)
            return
        }

        guard let fileURL = Self.writeClipboardImage(from: pasteboard) else {
            NSSound.beep()
            return
        }
        let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: fileURL)
        // A failed import hands back the source, which the editor still needs.
        if historyURL != fileURL { try? FileManager.default.removeItem(at: fileURL) }
        openEditor?(historyURL)
    }

    /// Writes the clipboard's image to a temporary PNG. PNG data is kept
    /// byte for byte; any other image type is re-encoded at full pixel size.
    private static func writeClipboardImage(from pasteboard: NSPasteboard) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pasted-\(UUID().uuidString)")
            .appendingPathExtension("png")

        if let png = pasteboard.data(forType: .png) {
            return (try? png.write(to: url)) == nil ? nil : url
        }

        let imageType = pasteboard.types?.first { UTType($0.rawValue)?.conforms(to: .image) == true }
        let cgImage: CGImage? = if let imageType,
            let data = pasteboard.data(forType: imageType),
            let source = CGImageSourceCreateWithData(data as CFData, nil) {
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            // PDF and other drawable content NSImage can read but ImageIO can't.
            NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    static func imageURLs(in urls: [URL]) -> [URL] {
        urls.filter { url in
            url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }
}
