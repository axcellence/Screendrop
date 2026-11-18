import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Checks pictures brought into the screenshot editor - placement, proportions, z-order, the
// export, and the canvas preview of blur and highlighter over them - against the real engine and
// exporter, without launching the app:
//
// engine=$(ls Screendrop/Engine/*.swift | grep -v -e AnnoCanvasLayerView -e AnnoTextEditorOverlay)
// xcrun swiftc -module-cache-path /tmp/screendrop-image-module-cache -default-isolation MainActor \
//   -swift-version 5 $=engine Screendrop/AnnotationSwatch.swift Screendrop/AnnotationTool.swift \
//   Screendrop/AnnotationRedactionImageProcessor.swift Screendrop/AnnoRedactionPreviewCache.swift \
//   Screendrop/AnnotationPresetStore.swift Screendrop/AnnotationMetrics.swift \
//   Screendrop/BoundedCGImageCache.swift Screendrop/AnnotationCanvasGrowth.swift \
//   Screendrop/AnnotationRenderer.swift Screendrop/AnnotationBackgroundRenderer.swift \
//   Screendrop/AnnotationBackgroundLayout.swift Screendrop/AnnotationBackground.swift \
//   Screendrop/AnnotationScreenshotFrameGeometry.swift Screendrop/PerCornerRadii.swift \
//   Screendrop/AnnotationShadowStyle.swift Screendrop/AnnotationMockupEffectsRenderer.swift \
//   Screendrop/AnnotationCameraGeometry.swift Screendrop/AnnotationWallpaperPreviewCache.swift \
//   Screendrop/AnnotationProgressiveBlurGeometry.swift Screendrop/AnnotationDocument.swift \
//   Screendrop/AnnotationImagePlacement.swift scripts/check-image-shapes.swift -o /tmp/screendrop-image-check && /tmp/screendrop-image-check
//
// (`$=engine` is zsh; in bash, leave `$engine` unquoted.) Pass a directory as the first argument
// to also write the export and the canvas preview there.

/// The exporter reads the JPEG quality from the app's preferences; PNG exports never use it.
enum ScreendropPreferences {
    static var compressionQuality: Double { 0.9 }
}

@main
struct ImageShapeChecks {
    static var checks = 0
    static var failures: [String] = []
    static var outputDirectory: URL?

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { failures.append(message()) }
    }

    static let workDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screendrop-image-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Bitmaps

    final class Bitmap {
        let width: Int
        let height: Int
        let context: CGContext

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }

        convenience init(_ image: CGImage) {
            self.init(width: image.width, height: image.height)
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        /// Fill a rect given top-down, like page space.
        func fill(_ rect: CGRect, _ rgb: [Int]) {
            context.setFillColor(CGColor(
                srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1
            ))
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }

        /// RGB at a top-down pixel.
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let p = context.data!.assumingMemoryBound(to: UInt8.self) + (y * width + x) * 4
            return [Int(p[0]), Int(p[1]), Int(p[2])]
        }

        var cgImage: CGImage { context.makeImage()! }

        @discardableResult
        func write(to url: URL) -> URL {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
            return url
        }
    }

    static func close(_ a: [Int], _ b: [Int], within tolerance: Int = 6) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static let red = [220, 40, 40]
    static let green = [40, 200, 80]
    static let blue = [40, 80, 220]

    /// A flat red screenshot.
    static func screenshot(width: Int, height: Int) -> Bitmap {
        let image = Bitmap(width: width, height: height)
        image.fill(CGRect(x: 0, y: 0, width: width, height: height), red)
        return image
    }

    /// The picture being brought in: green over its top half, blue below, so a flip shows.
    static func picture(width: Int, height: Int) -> Bitmap {
        let image = Bitmap(width: width, height: height)
        image.fill(CGRect(x: 0, y: 0, width: width, height: height / 2), green)
        image.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2), blue)
        return image
    }

    static func imageShape(_ name: String, _ frame: CGRect) -> AnnoShape {
        AnnoShape(x: frame.minX, y: frame.minY, kind: .image(ImageProps(asset: name, w: frame.width, h: frame.height)))
    }

    // MARK: - Placement

    static func checkPlacement() {
        let wide = CGRect(x: 0, y: 0, width: 1600, height: 800)
        let gap = (800 * AnnotationCanvasGrowth.marginFraction).rounded(.up)
        let below = AnnoImagePlacement.frames(for: [CGSize(width: 1200, height: 700)], screenshot: wide, existing: [])
        expect(below == [CGRect(x: 0, y: 800 + gap, width: 1200, height: 700)],
               "a picture beside a wide screenshot should stack below it, got \(below)")

        let tall = CGRect(x: 0, y: 0, width: 600, height: 1200)
        let tallGap = (600 * AnnotationCanvasGrowth.marginFraction).rounded(.up)
        let right = AnnoImagePlacement.frames(for: [CGSize(width: 500, height: 900)], screenshot: tall, existing: [])
        expect(right == [CGRect(x: 600 + tallGap, y: 0, width: 500, height: 900)],
               "a picture beside a tall screenshot should go to its right, got \(right)")

        // Two at once, and one more later: none overlaps the screenshot or another.
        let two = AnnoImagePlacement.frames(
            for: [CGSize(width: 1600, height: 800), CGSize(width: 1600, height: 800)], screenshot: wide, existing: []
        )
        expect(two.count == 2 && !two[0].intersects(two[1]) && two.allSatisfy { !$0.intersects(wide) },
               "pictures placed together overlap: \(two)")
        let third = AnnoImagePlacement.frames(for: [CGSize(width: 1600, height: 800)], screenshot: wide, existing: two)
        expect(third.count == 1 && two.allSatisfy { !$0.intersects(third[0]) } && !third[0].intersects(wide),
               "a later picture lands on an earlier one: \(third) vs \(two)")

        // A picture that would push the canvas past its cap is scaled down, keeping its shape.
        let huge = AnnoImagePlacement.frames(for: [CGSize(width: 20_000, height: 10_000)], screenshot: wide, existing: [])
        let whole = huge[0].union(wide)
        expect(whole.width <= AnnotationCanvasGrowth.maximumCanvasDimension
               && whole.height <= AnnotationCanvasGrowth.maximumCanvasDimension,
               "a huge picture pushes the canvas past the cap: \(huge)")
        expect(abs(huge[0].width / huge[0].height - 2) < 0.01, "a scaled-down picture lost its proportions: \(huge)")

        // Picture after picture beside a 4K screenshot: every one lands inside the cap, and once
        // there is no room the rest are left out rather than placed off the canvas.
        let fourK = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        var placed: [CGRect] = []
        for _ in 0..<20 {
            placed += AnnoImagePlacement.frames(for: [fourK.size], screenshot: fourK, existing: placed)
        }
        let cap = AnnotationCanvasGrowth.maximumCanvasDimension
        let everything = placed.reduce(fourK) { $0.union($1) }
        let margin = (2160 * AnnotationCanvasGrowth.marginFraction).rounded(.up)
        expect(everything.width + 2 * margin <= cap && everything.height + 2 * margin <= cap,
               "repeated pictures pushed the canvas past the cap: \(everything.size)")
        expect(placed.count < 20 && placed.allSatisfy { $0.width >= 1 && $0.height >= 1 },
               "placement never ran out of room, or produced an empty frame: \(placed.count)")
    }

    // MARK: - Assets and document

    static func checkAssets() -> String {
        let picture = picture(width: 300, height: 200)
        let url = picture.write(to: workDirectory.appendingPathComponent("picture.png"))
        let stored = try! AnnoImageAssets.shared.store(contentsOf: url)
        expect(stored.size == CGSize(width: 300, height: 200), "stored size is \(stored.size)")
        let again = try! AnnoImageAssets.shared.store(data: try! Data(contentsOf: url))
        expect(again.name == stored.name, "the same picture stored twice got two names")

        // Two captures holding the same picture: losing one copy leaves the other in use.
        let first = workDirectory.appendingPathComponent("first.assets")
        let second = workDirectory.appendingPathComponent("second.assets")
        for directory in [first, second] {
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try! FileManager.default.copyItem(at: AnnoImageAssets.shared.url(for: stored.name)!, to: directory.appendingPathComponent(stored.name))
        }
        AnnoImageAssets.shared.registerContents(of: first)
        AnnoImageAssets.shared.registerContents(of: second)
        try! FileManager.default.removeItem(at: AnnoImageAssets.workingDirectory.appendingPathComponent(stored.name))
        try! FileManager.default.removeItem(at: second)
        expect(AnnoImageAssets.shared.url(for: stored.name) == first.appendingPathComponent(stored.name),
               "losing one capture's copy stranded the other: \(String(describing: AnnoImageAssets.shared.url(for: stored.name)))")

        // TIFF from the pasteboard is re-encoded and still decodes the right way up.
        let tiff = NSBitmapImageRep(cgImage: picture.cgImage).tiffRepresentation!
        let fromTIFF = try! AnnoImageAssets.shared.store(data: tiff)
        let decoded = Bitmap(AnnoImageAssets.shared.image(named: fromTIFF.name)!)
        expect(close(decoded.rgb(150, 20), green) && close(decoded.rgb(150, 180), blue),
               "a pasted TIFF came back wrong: top \(decoded.rgb(150, 20)) bottom \(decoded.rgb(150, 180))")

        let shape = imageShape(stored.name, CGRect(x: 10, y: 20, width: 300, height: 200))
        let document = AnnotationDocument(shapes: [shape], background: AnnotationBackgroundSettings())
        let reopened = try! JSONDecoder().decode(AnnotationDocument.self, from: try! JSONEncoder().encode(document))
        expect(reopened.shapes == [shape], "an image shape did not survive the sidecar")
        let json = String(data: try! JSONEncoder().encode(document), encoding: .utf8)!
        expect(json.count < 2_000, "the sidecar carries picture bytes (\(json.count) characters)")
        return stored.name
    }

    // MARK: - Export

    static func render(_ source: URL, _ shapes: [AnnoShape], name: String) -> Bitmap {
        let url = (outputDirectory ?? workDirectory).appendingPathComponent(name)
        try! AnnotationRenderer.render(
            sourceURL: source, shapes: shapes, backgroundSettings: AnnotationBackgroundSettings(),
            destinationURL: url, contentType: .png
        )
        let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return Bitmap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!)
    }

    static func checkExport(asset: String) {
        let source = screenshot(width: 400, height: 300).write(to: workDirectory.appendingPathComponent("shot.png"))
        let frame = AnnoImagePlacement.frames(
            for: [CGSize(width: 300, height: 200)], screenshot: CGRect(x: 0, y: 0, width: 400, height: 300), existing: []
        )[0]
        let picture = imageShape(asset, frame)
        let plain = render(source, [picture], name: "image-export.png")
        let layout = AnnotationBackgroundLayout.make(
            contentSize: CGSize(width: 400, height: 300),
            settings: AnnotationBackgroundSettings(),
            annotationExtents: AnnotationCanvasGrowth.extents(of: [picture])
        )
        expect(layout.isGrown && plain.width == Int(layout.canvasSize.width) && plain.height == Int(layout.canvasSize.height),
               "the canvas did not grow to hold the picture: \(plain.width)x\(plain.height)")
        let origin = layout.imageRect.origin
        func at(_ x: CGFloat, _ y: CGFloat) -> [Int] { plain.rgb(Int(origin.x + x), Int(origin.y + y)) }
        expect(close(at(200, 150), red), "the screenshot moved or changed: \(at(200, 150))")
        expect(close(at(frame.midX, frame.minY + 20), green) && close(at(frame.midX, frame.maxY - 20), blue),
               "the picture is missing or upside down: top \(at(frame.midX, frame.minY + 20)) bottom \(at(frame.midX, frame.maxY - 20))")

        // Annotations land on top of the picture even when the picture came last.
        var box = GeoProps()
        box.w = 60; box.h = 60; box.fill = .solid; box.swatch = .yellow; box.dash = .solid
        let onTop = AnnoShape(x: frame.minX + 20, y: frame.minY + 20, kind: .geo(box))
        let layered = render(source, [onTop, picture], name: "image-under-box.png")
        let boxPixel = layered.rgb(Int(origin.x + frame.minX + 50), Int(origin.y + frame.minY + 50))
        expect(!close(boxPixel, green, within: 30), "a box drawn before the picture went under it: \(boxPixel)")

        // A blur across the picture's two halves mixes them in the export.
        var redaction = RedactionProps()
        redaction.kind = .blur; redaction.w = 120; redaction.h = 80; redaction.density = 1
        let blur = AnnoShape(x: frame.midX - 60, y: frame.midY - 40, kind: .redaction(redaction))
        let blurred = render(source, [picture, blur], name: "image-blurred.png")
        let seam = blurred.rgb(Int(origin.x + frame.midX), Int(origin.y + frame.midY - 2))
        expect(!close(seam, green, within: 20) && !close(seam, blue, within: 20),
               "blur over the picture left its seam sharp: \(seam)")
    }

    // MARK: - Canvas preview

    /// Draws the document the way `AnnoCanvasNSView` does: a flipped (y-down) context, the
    /// screenshot as the backdrop, and the grown fill as the surround.
    static func canvasPreview(_ shapes: [AnnoShape], screenshot: CGImage, size: CGSize, name: String) -> Bitmap {
        let bitmap = Bitmap(width: Int(size.width), height: Int(size.height))
        bitmap.context.translateBy(x: 0, y: size.height)
        bitmap.context.scaleBy(x: 1, y: -1)
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(shapes: shapes, bindings: []))
        let target = AnnoShapeDrawing.Target(
            transform: .identity,
            pageSize: CGSize(width: screenshot.width, height: screenshot.height),
            sample: { rect in
                let crop = rect.integral.intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
                return crop.width >= 1 && crop.height >= 1 ? screenshot.cropping(to: crop) : nil
            },
            spotlightClip: nil,
            isFlippedContext: true,
            backdrop: screenshot,
            surround: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        )
        AnnoShapeDrawing.draw(document, in: bitmap.context, target: target)
        if let outputDirectory { bitmap.write(to: outputDirectory.appendingPathComponent(name)) }
        return bitmap
    }

    static func checkCanvasPreview(asset: String) {
        let shot = screenshot(width: 400, height: 300).cgImage
        let frame = CGRect(x: 0, y: 320, width: 300, height: 200)
        let picture = imageShape(asset, frame)
        let size = CGSize(width: 420, height: 540)

        let alone = canvasPreview([picture], screenshot: shot, size: size, name: "canvas-image.png")
        expect(close(alone.rgb(150, 340), green) && close(alone.rgb(150, 500), blue),
               "the canvas draws the picture wrong: top \(alone.rgb(150, 340)) bottom \(alone.rgb(150, 500))")

        // Blur over the picture on the canvas blurs the picture, not the screenshot or the fill.
        var redaction = RedactionProps()
        redaction.kind = .blur; redaction.w = 120; redaction.h = 80; redaction.density = 1
        let blur = AnnoShape(x: frame.midX - 60, y: frame.midY - 40, kind: .redaction(redaction))
        let blurred = canvasPreview([picture, blur], screenshot: shot, size: size, name: "canvas-image-blurred.png")
        let seam = blurred.rgb(Int(frame.midX), Int(frame.midY - 2))
        let inside = blurred.rgb(Int(frame.midX), Int(frame.midY - 35))
        expect(!close(seam, green, within: 20) && !close(seam, blue, within: 20) && !close(seam, [255, 255, 255], within: 30),
               "blur over the picture on the canvas did not blur it: \(seam)")
        expect(close(inside, green, within: 40), "blur on the canvas sampled something other than the picture: \(inside)")

        // The highlighter over the picture tints the picture rather than painting the fill over it.
        var marker = DrawProps()
        marker.ink = .marker
        marker.points = [Vec(0, 0, 0.5), Vec(200, 0, 0.5)]
        marker.isComplete = true
        marker.strokeWidth = 30
        marker.swatch = .markerYellow
        let stroke = AnnoShape(x: frame.minX + 40, y: frame.minY + 40, kind: .draw(marker))
        let marked = canvasPreview([picture, stroke], screenshot: shot, size: size, name: "canvas-image-marker.png")
        let tinted = marked.rgb(Int(frame.minX + 140), Int(frame.minY + 40))
        // Yellow multiplied into green stays green-dominant with little red; over the white fill
        // it would come out bright yellow instead.
        expect(tinted[0] < 120 && tinted[1] > 120 && tinted[1] > tinted[2],
               "the highlighter over the picture covered it: \(tinted)")
    }

    // MARK: - Editing

    static func checkEditing(asset: String) {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(
            imageFrame: CGRect(x: 0, y: 0, width: 400, height: 300), imageSize: CGSize(width: 400, height: 300)
        )
        let frame = CGRect(x: 0, y: 320, width: 300, height: 200)
        editor.insertImages([imageShape(asset, frame)])
        expect(editor.tool == .select && editor.selectedIds.count == 1, "an inserted picture is not selected")
        editor.undo()
        expect(editor.shapes.isEmpty, "one undo did not remove the insertion")
        editor.redo()

        let id = editor.shapes[0].id
        editor.selectedIds = [id]
        // Edge handles are gone; corners scale it uniformly even when dragged off the diagonal.
        expect(editor.handle(at: Vec(frame.maxX, frame.midY)) == nil, "a picture offers an edge handle")
        let corner = Vec(frame.maxX, frame.maxY)
        expect(editor.handle(at: corner) == .bottomRight, "a picture has no corner handle")
        editor.pointerDown(PointerInfo(screenPoint: corner, pagePoint: corner))
        let dragged = Vec(frame.maxX + 150, frame.maxY + 20)
        editor.pointerMove(PointerInfo(screenPoint: dragged, pagePoint: dragged))
        editor.pointerUp(PointerInfo(screenPoint: dragged, pagePoint: dragged))
        let props = editor.shapes[0].imageProps!
        expect(abs(props.w / props.h - 1.5) < 0.001 && props.w > 300, "resizing changed the proportions: \(props.w)x\(props.h)")

        // Dragging the corner straight in from the side shrinks it, still in proportion.
        let grown = editor.shapes[0]
        let grownCorner = Vec(grown.x + props.w, grown.y + props.h)
        let inward = Vec(grownCorner.x - 100, grownCorner.y)
        editor.pointerDown(PointerInfo(screenPoint: grownCorner, pagePoint: grownCorner))
        editor.pointerMove(PointerInfo(screenPoint: inward, pagePoint: inward))
        editor.pointerUp(PointerInfo(screenPoint: inward, pagePoint: inward))
        let shrunk = editor.shapes[0].imageProps!
        expect(shrunk.w < props.w - 20 && abs(shrunk.w / shrunk.h - 1.5) < 0.001,
               "a sideways drag inward did not shrink the picture in proportion: \(shrunk.w)x\(shrunk.h) from \(props.w)x\(props.h)")
        expect(editor.shapes[0].x == grown.x && editor.shapes[0].y == grown.y, "shrinking moved the opposite corner")

        // Shrunk as far as it goes, a long thin picture keeps its shape rather than flattening.
        let thin = imageShape(asset, CGRect(x: 0, y: 320, width: 300, height: 50))
        editor.replaceDocument(shapes: [thin])
        editor.selectedIds = [thin.id]
        let thinCorner = Vec(300, 370)
        let collapsed = Vec(-200, 300)
        editor.pointerDown(PointerInfo(screenPoint: thinCorner, pagePoint: thinCorner))
        editor.pointerMove(PointerInfo(screenPoint: collapsed, pagePoint: collapsed))
        editor.pointerUp(PointerInfo(screenPoint: collapsed, pagePoint: collapsed))
        let tiny = editor.shapes[0].imageProps!
        expect(tiny.h >= 1 && abs(tiny.w / tiny.h - 6) < 0.001, "a picture at its smallest lost its shape: \(tiny.w)x\(tiny.h)")

        // Shrunk to its smallest from the top-left, the bottom-right corner stays put.
        editor.replaceDocument(shapes: [thin])
        editor.selectedIds = [thin.id]
        let topLeft = Vec(0, 320)
        let past = Vec(700, 900)
        editor.pointerDown(PointerInfo(screenPoint: topLeft, pagePoint: topLeft))
        editor.pointerMove(PointerInfo(screenPoint: past, pagePoint: past))
        editor.pointerUp(PointerInfo(screenPoint: past, pagePoint: past))
        let pinned = editor.shapes[0]
        let pinnedProps = pinned.imageProps!
        expect(abs(pinnedProps.w - 6) < 0.001 && abs(pinnedProps.h - 1) < 0.001,
               "dragging the top-left past the far corner did not shrink the picture: \(pinnedProps.w)x\(pinnedProps.h)")
        expect(abs(pinned.x + pinnedProps.w - 300) < 0.001 && abs(pinned.y + pinnedProps.h - 370) < 0.001,
               "shrinking from the top-left moved the bottom-right corner: \(pinned.x + pinnedProps.w), \(pinned.y + pinnedProps.h)")

        // A rotated picture in a group scales by the group's factor, not more.
        var tilted = imageShape(asset, CGRect(x: 0, y: 320, width: 300, height: 200))
        tilted.rotation = .pi / 4
        var boxProps = GeoProps()
        boxProps.w = 50; boxProps.h = 50
        let box = AnnoShape(x: 600, y: 600, kind: .geo(boxProps))
        editor.replaceDocument(shapes: [tilted, box])
        editor.selectedIds = [tilted.id, box.id]
        let group = editor.selectionBounds!
        let groupCorner = editor.pageToScreen(group.pagePoint(Vec(1, 1)))
        let doubled = editor.pageToScreen(group.pagePoint(Vec(2, 2)))
        editor.pointerDown(PointerInfo(screenPoint: groupCorner, pagePoint: editor.screenToPage(groupCorner)))
        editor.pointerMove(PointerInfo(screenPoint: doubled, pagePoint: editor.screenToPage(doubled)))
        editor.pointerUp(PointerInfo(screenPoint: doubled, pagePoint: editor.screenToPage(doubled)))
        let scaled = editor.shapes[0].imageProps!
        expect(abs(scaled.w - 600) < 1 && abs(scaled.h - 400) < 1, "a rotated picture in a group scaled wrongly: \(scaled.w)x\(scaled.h)")

        // An arrow drawn onto a picture ends where it is dropped instead of binding to it.
        editor.replaceDocument(shapes: [imageShape(asset, frame)])
        editor.tool = .arrow
        let from = Vec(100, 100)
        let onto = Vec(150, 420)
        editor.pointerDown(PointerInfo(screenPoint: from, pagePoint: from))
        editor.pointerMove(PointerInfo(screenPoint: onto, pagePoint: onto))
        editor.pointerUp(PointerInfo(screenPoint: onto, pagePoint: onto))
        expect(editor.shapes.contains(where: \.isArrow) && editor.document.bindings.isEmpty,
               "an arrow onto a picture bound to it: \(editor.document.bindings.count) bindings")
        editor.tool = .select

        // An arrow drawn after the picture is clicked before it, since it is drawn on top.
        var arrowProps = ArrowProps()
        arrowProps.end = Vec(100, 0)
        let arrow = AnnoShape(x: 50, y: 360, kind: .arrow(arrowProps))
        editor.replaceDocument(shapes: [imageShape(asset, frame), arrow])
        expect(editor.hitShape(at: Vec(100, 360))?.isArrow == true, "a click on an arrow over a picture picks the picture")
        let image = imageShape(asset, frame)
        editor.replaceDocument(shapes: [arrow, image])
        expect(editor.hitShape(at: Vec(100, 360))?.isArrow == true, "a picture added later steals clicks from the arrow on it")
        expect(editor.hitShape(at: Vec(250, 450))?.isImage == true, "a picture cannot be clicked")
    }

    static func main() {
        if CommandLine.arguments.count > 1 {
            outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
            try? FileManager.default.createDirectory(at: outputDirectory!, withIntermediateDirectories: true)
        }
        checkPlacement()
        let asset = checkAssets()
        checkExport(asset: asset)
        checkCanvasPreview(asset: asset)
        checkEditing(asset: asset)
        try? FileManager.default.removeItem(at: workDirectory)

        if failures.isEmpty {
            print("Image shape checks passed: \(checks)")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("Image shape checks: \(failures.count) of \(checks) failed")
            exit(1)
        }
    }
}
