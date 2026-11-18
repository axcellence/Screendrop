import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures that image shapes draw, by stored file name.
///
/// A file is named after a hash of its PNG bytes, so the same picture brought in twice is stored
/// once and a name means the same pixels wherever it is found: in the editor's working folder
/// before a save, or in a capture's `.assets` folder after one. Both register here, and the canvas
/// and the off-main exporter look pictures up by name alone.
nonisolated final class AnnoImageAssets: @unchecked Sendable {
    static let shared = AnnoImageAssets()

    private let lock = NSLock()
    private var locations: [String: URL] = [:]
    private var decoded: [String: CGImage] = [:]

    /// Where pictures wait between being brought in and the save that moves them next to the
    /// capture. The names are content hashes, so editors can share it.
    static var workingDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Screendrop Image Assets", isDirectory: true)
    }

    // MARK: - Locating

    func register(_ url: URL, name: String) {
        lock.withLock { locations[name] = url }
    }

    /// Registers every stored picture in a folder, such as a capture's `.assets` folder.
    func registerContents(of directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        lock.withLock {
            for name in names where !name.hasPrefix(".") {
                locations[name] = directory.appendingPathComponent(name)
            }
        }
    }

    func url(for name: String) -> URL? {
        if let url = lock.withLock({ locations[name] }), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let working = Self.workingDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: working.path) else { return nil }
        register(working, name: name)
        return working
    }

    // MARK: - Decoding

    /// The picture's full-resolution pixels, decoded once and kept until `releaseDecoded`.
    func image(named name: String) -> CGImage? {
        if let image = lock.withLock({ decoded[name] }) { return image }
        guard let url = url(for: name),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        lock.withLock { decoded[name] = image }
        return image
    }

    /// Drops every decoded picture. They decode again on the next draw that needs them.
    func releaseDecoded() {
        lock.withLock { decoded.removeAll() }
    }

    // MARK: - Storing

    /// Stores a picture from a file and returns its name and pixel size. An upright PNG keeps its
    /// own bytes; anything else is re-encoded as PNG, turned the way its orientation tag says.
    func store(contentsOf url: URL) throws -> (name: String, size: CGSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return try store(source) { try Data(contentsOf: url) }
    }

    /// Stores raw image data from the pasteboard (PNG, TIFF or anything ImageIO reads).
    func store(data: Data) throws -> (name: String, size: CGSize) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return try store(source) { data }
    }

    private func store(_ source: CGImageSource, bytes: () throws -> Data) throws -> (name: String, size: CGSize) {
        guard let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if UTType(type as String) == .png, orientation == 1 {
            return (try store(pngData: try bytes()), CGSize(width: width, height: height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try store(image)
    }

    func store(_ image: CGImage) throws -> (name: String, size: CGSize) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return (try store(pngData: data as Data), CGSize(width: image.width, height: image.height))
    }

    private func store(pngData data: Data) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(digest.prefix(32)).png"
        if url(for: name) != nil { return name }
        let directory = Self.workingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        register(destination, name: name)
        return name
    }
}
