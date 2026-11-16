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

    static func imageURLs(in urls: [URL]) -> [URL] {
        urls.filter { url in
            url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }
}
