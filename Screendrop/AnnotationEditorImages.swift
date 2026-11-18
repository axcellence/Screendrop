//
//  AnnotationEditorImages.swift
//  Screendrop
//
//  Bringing another picture into the editor - dropped or pasted - as a shape beside the
//  screenshot, so two captures can be compared and marked up as one image.
//

import AppKit
import UniformTypeIdentifiers

extension AnnotationEditorModel {
    /// Pastes the pictures on `pasteboard`: image files if it holds any, otherwise image data.
    /// Returns false when there is nothing to paste, so the key can do whatever it would have.
    @discardableResult
    func insertImages(from pasteboard: NSPasteboard) -> Bool {
        guard canInsertImages else { return false }
        let files = Self.imageFileURLs(in: pasteboard)
        if !files.isEmpty {
            return insertImages(fileURLs: files)
        }
        // A file copied in Finder also carries its icon as TIFF, so files are checked first.
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type) else { return false }
        storeAndInsert { [try AnnoImageAssets.shared.store(data: data)] }
        return true
    }

    /// Inserts the image files among `urls`. Returns false when none is an image.
    @discardableResult
    func insertImages(fileURLs urls: [URL]) -> Bool {
        guard canInsertImages else { return false }
        let images = urls.filter(Self.isImageFile)
        guard !images.isEmpty else { return false }
        storeAndInsert { try images.map { try AnnoImageAssets.shared.store(contentsOf: $0) } }
        return true
    }

    private var canInsertImages: Bool {
        !isCropping && !isCommitting && imageSize.width > 0 && imageSize.height > 0
    }

    /// Encodes and stores off the main thread, since a large TIFF takes a moment to become a PNG.
    private func storeAndInsert(_ store: @escaping @Sendable () throws -> [(name: String, size: CGSize)]) {
        Task {
            do {
                let stored = try await Task.detached(priority: .userInitiated) { try store() }.value
                insertStoredImages(stored)
            } catch {
                errorMessage = "Couldn't add that image."
            }
        }
    }

    private func insertStoredImages(_ stored: [(name: String, size: CGSize)]) {
        guard canInsertImages, !stored.isEmpty else { return }
        let existing = engine.shapes.filter(\.isImage).compactMap { shape -> CGRect? in
            guard let box = engine.document.pageBounds(shape.id) else { return nil }
            return CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
        }
        let frames = AnnoImagePlacement.frames(
            for: stored.map(\.size),
            screenshot: CGRect(origin: .zero, size: imageSize),
            existing: existing
        )
        let shapes = zip(stored, frames).map { item, frame in
            AnnoShape(
                x: frame.minX,
                y: frame.minY,
                kind: .image(ImageProps(asset: item.name, w: frame.width, h: frame.height))
            )
        }
        // Fit first, so the canvas animates out to show the picture where it landed.
        fitCanvas()
        engine.insertImages(shapes)
        selectedTool = .select
        errorMessage = nil
    }

    private static func imageFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter(isImageFile)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}
