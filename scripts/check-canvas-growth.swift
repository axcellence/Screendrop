import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Checks that the screenshot editor's canvas grows to hold annotations drawn outside the
// screenshot, against the real engine, layout and exporter, without launching the app:
//
// engine=$(ls Screendrop/Engine/*.swift | grep -v -e AnnoCanvasLayerView -e AnnoTextEditorOverlay)
// xcrun swiftc -module-cache-path /tmp/screendrop-growth-module-cache -default-isolation MainActor \
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
//   scripts/check-canvas-growth.swift -o /tmp/screendrop-growth-check && /tmp/screendrop-growth-check
//
// (`$=engine` is zsh; in bash, leave `$engine` unquoted.) Pass a directory as the first argument
// to also write exported PNGs there: a flat-edged and a busy-edged screenshot with a note beside
// them, a gradient background with a note below the card, and one with nothing outside.

/// The exporter reads the JPEG quality from the app's preferences; PNG exports never use it.
enum ScreendropPreferences {
    static var compressionQuality: Double { 0.9 }
}

@main
struct CanvasGrowthChecks {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { failures.append(message()) }
    }

    static let workDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screendrop-growth-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: - Shapes

    static func arrow(from start: Vec, to end: Vec, strokeWidth: Double = 6, dash: DashStyle = .draw) -> AnnoShape {
        var props = ArrowProps()
        props.start = Vec(0, 0)
        props.end = Vec(end.x - start.x, end.y - start.y)
        props.strokeWidth = strokeWidth
        props.dash = dash
        props.arrowheadEnd = .arrow
        props.swatch = .red
        return AnnoShape(x: start.x, y: start.y, kind: .arrow(props))
    }

    static func ellipse(_ rect: CGRect, strokeWidth: Double = 6) -> AnnoShape {
        var props = GeoProps()
        props.geo = .ellipse
        props.w = rect.width
        props.h = rect.height
        props.strokeWidth = strokeWidth
        props.dash = .draw
        props.swatch = .red
        return AnnoShape(x: rect.minX, y: rect.minY, kind: .geo(props))
    }

    static func text(_ string: String, at point: Vec, size: Double = 26) -> AnnoShape {
        var props = TextProps()
        props.text = string
        props.fontSize = size
        props.swatch = .red
        return AnnoShape(x: point.x, y: point.y, kind: .text(props))
    }

    static func layout(
        _ size: CGSize, _ settings: AnnotationBackgroundSettings = AnnotationBackgroundSettings(), _ shapes: [AnnoShape]
    ) -> AnnotationBackgroundLayout {
        AnnotationBackgroundLayout.make(
            contentSize: size,
            settings: settings,
            annotationExtents: AnnotationCanvasGrowth.extents(of: shapes)
        )
    }

    static func sameLayout(_ a: AnnotationBackgroundLayout, _ b: AnnotationBackgroundLayout) -> Bool {
        a.canvasSize == b.canvasSize && a.imageRect == b.imageRect && a.cardRect == b.cardRect
    }

    static var gradientSettings: AnnotationBackgroundSettings {
        var settings = AnnotationBackgroundSettings()
        settings.style = .gradient(AnnotationBackgroundGradient.presets[0])
        return settings
    }

    // MARK: - Images

    final class Image {
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

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        /// Fill a rect given top-down, like page space.
        func fill(_ rect: CGRect, _ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) {
            context.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a))
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }

        /// RGBA bytes at a top-down pixel.
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let p = context.data!.assumingMemoryBound(to: UInt8.self) + (y * width + x) * 4
            return [p[0], p[1], p[2], p[3]]
        }

        var bytes: Data { Data(bytes: context.data!, count: width * height * 4) }
        var cgImage: CGImage { context.makeImage()! }

        func write(_ name: String) -> URL {
            let url = workDirectory.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
            return url
        }
    }

    /// A light app window: flat grey edge, a sidebar and some content blocks inside.
    static func flatScreenshot() -> Image {
        let image = Image(width: 640, height: 400)
        image.fill(CGRect(x: 0, y: 0, width: 640, height: 400), 236, 238, 242)
        image.fill(CGRect(x: 24, y: 24, width: 150, height: 352), 222, 226, 233)
        image.fill(CGRect(x: 200, y: 40, width: 400, height: 36), 40, 44, 52)
        for row in 0..<5 {
            image.fill(CGRect(x: 200, y: 100 + row * 50, width: 360 - row * 30, height: 18), 120, 128, 140)
        }
        image.fill(CGRect(x: 440, y: 320, width: 150, height: 40), 37, 99, 235)
        return image
    }

    /// A photo-like screenshot: a colourful gradient runs right to the edge.
    static func busyScreenshot() -> Image {
        let image = Image(width: 640, height: 400)
        let colors = [
            CGColor(srgbRed: 0.95, green: 0.45, blue: 0.2, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1),
            CGColor(srgbRed: 0.3, green: 0.8, blue: 0.5, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: nil)!
        image.context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 640, y: 400), options: [])
        image.fill(CGRect(x: 180, y: 120, width: 280, height: 160), 255, 255, 255, 0.85)
        return image
    }

    /// A window capture: the window sits inside a transparent shadow margin.
    static func transparentEdgeScreenshot() -> Image {
        let image = Image(width: 320, height: 200)
        image.fill(CGRect(x: 30, y: 30, width: 260, height: 140), 250, 250, 250)
        return image
    }

    static func render(_ source: URL, _ shapes: [AnnoShape], _ settings: AnnotationBackgroundSettings, to name: String) -> Image {
        let url = workDirectory.appendingPathComponent(name)
        try! AnnotationRenderer.render(
            sourceURL: source, shapes: shapes, backgroundSettings: settings, destinationURL: url, contentType: .png
        )
        let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return Image(CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!)
    }

    static func components(_ color: CGColor) -> [Int] {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
        return srgb.components!.prefix(3).map { Int(($0 * 255).rounded()) }
    }

    // MARK: - Growth

    static func checkGrowth() {
        let size = CGSize(width: 640, height: 400)
        let margin = 400 * AnnotationCanvasGrowth.marginFraction
        let base = AnnotationBackgroundLayout.make(contentSize: size, settings: AnnotationBackgroundSettings())

        // Nothing outside: exactly today's canvas.
        let inside = [ellipse(CGRect(x: 100, y: 100, width: 200, height: 120)), arrow(from: Vec(50, 50), to: Vec(300, 300))]
        expect(sameLayout(layout(size, AnnotationBackgroundSettings(), inside), base),
               "shapes inside the screenshot changed the canvas: \(layout(size, AnnotationBackgroundSettings(), inside).canvasSize)")
        expect(sameLayout(layout(size, gradientSettings, inside),
                          AnnotationBackgroundLayout.make(contentSize: size, settings: gradientSettings)),
               "shapes inside the screenshot changed the padded canvas")
        // A stroke brushing the edge (geometry on the edge, ink just past it) is as before.
        let hugging = ellipse(CGRect(x: 0, y: 0, width: 640, height: 400), strokeWidth: 12)
        expect(sameLayout(layout(size, AnnotationBackgroundSettings(), [hugging]), base),
               "a shape drawn up to the edge grew the canvas")

        // Past the right edge: only the right side grows, by the ink's overhang plus the margin.
        let out = arrow(from: Vec(560, 200), to: Vec(820, 200))
        let ink = AnnotationCanvasGrowth.extents(of: [out])[0].ink
        let grown = layout(size, AnnotationBackgroundSettings(), [out])
        let expectedRight = (ink.maxX - 640 + margin).rounded(.up)
        expect(grown.growth == AnnotationCanvasGrowth(top: 0, left: 0, bottom: 0, right: expectedRight),
               "right overhang grew \(grown.growth), wanted right \(expectedRight)")
        expect(grown.canvasSize == CGSize(width: 640 + expectedRight, height: 400),
               "right overhang canvas is \(grown.canvasSize)")
        expect(grown.imageRect == CGRect(origin: .zero, size: size),
               "right overhang moved the screenshot to \(grown.imageRect)")

        // Past the left and top: the screenshot moves right and down by the growth.
        let leftTop = text("Note", at: Vec(-180, -60))
        let grownLeftTop = layout(size, AnnotationBackgroundSettings(), [leftTop])
        expect(grownLeftTop.growth.left > 180 && grownLeftTop.growth.top > 60
               && grownLeftTop.growth.right == 0 && grownLeftTop.growth.bottom == 0,
               "a note above-left grew \(grownLeftTop.growth)")
        expect(grownLeftTop.imageRect.origin == CGPoint(x: grownLeftTop.growth.left, y: grownLeftTop.growth.top),
               "a note above-left left the screenshot at \(grownLeftTop.imageRect.origin)")

        // Removing the shape gives the original canvas back.
        expect(sameLayout(layout(size, AnnotationBackgroundSettings(), []), base), "removing the shape kept the growth")

        // A thick stroke and an arrowhead at the new edge sit inside the canvas, with room to spare.
        let thick = arrow(from: Vec(500, 100), to: Vec(900, 380), strokeWidth: 40)
        let thickExtent = AnnotationCanvasGrowth.extents(of: [thick])[0]
        let thickLayout = layout(size, AnnotationBackgroundSettings(), [thick])
        let thickInk = thickExtent.ink.offsetBy(dx: thickLayout.imageRect.minX, dy: thickLayout.imageRect.minY)
        expect(CGRect(origin: .zero, size: thickLayout.canvasSize).insetBy(dx: margin - 1, dy: 0).contains(
                CGRect(x: thickInk.minX, y: 0, width: thickInk.width, height: 1)),
               "thick arrow ink \(thickInk) is not inside the grown canvas \(thickLayout.canvasSize) with its margin")
        expect(thickExtent.ink.maxX > 900 + 20 - 1,
               "ink extent \(thickExtent.ink) leaves out the stroke width")

        // With a background: the padded canvas grows on the needed side only...
        let padded = AnnotationBackgroundLayout.make(contentSize: size, settings: gradientSettings)
        let below = text("The footer is cut off", at: Vec(120, 400 + padded.padding + 30))
        let paddedGrown = layout(size, gradientSettings, [below])
        expect(paddedGrown.growth.bottom > 0 && paddedGrown.growth.top == 0
               && paddedGrown.growth.left == 0 && paddedGrown.growth.right == 0,
               "a note below the card grew \(paddedGrown.growth)")
        expect(paddedGrown.canvasSize == CGSize(width: padded.canvasSize.width,
                                                height: padded.canvasSize.height + paddedGrown.growth.bottom),
               "padded canvas grew to \(paddedGrown.canvasSize) from \(padded.canvasSize)")
        expect(paddedGrown.imageRect == padded.imageRect, "a note below the card moved the card")
        // ...and a note inside the padding doesn't grow it at all.
        let inPadding = text("ok", at: Vec(10, 400 + 4), size: 12)
        expect(sameLayout(layout(size, gradientSettings, [inPadding]), padded), "a note inside the padding grew the canvas")

        // A fixed aspect ratio still holds once grown, and the note is still inside.
        var ratioSettings = gradientSettings
        ratioSettings.aspectRatio = .sixteenNine
        let ratioGrown = layout(size, ratioSettings, [below])
        let ratio = ratioGrown.canvasSize.width / ratioGrown.canvasSize.height
        expect(abs(ratio - 16.0 / 9.0) < 0.0001, "16:9 canvas came out \(ratioGrown.canvasSize)")
        let belowInk = AnnotationCanvasGrowth.extents(of: [below])[0].ink
            .offsetBy(dx: ratioGrown.imageRect.minX, dy: ratioGrown.imageRect.minY)
        expect(CGRect(origin: .zero, size: ratioGrown.canvasSize).contains(belowInk),
               "16:9 canvas \(ratioGrown.canvasSize) cut off the note at \(belowInk)")

        // Blur, pixelate and the spotlight never grow the canvas.
        var redaction = RedactionProps()
        redaction.w = 300
        redaction.h = 100
        let blur = AnnoShape(x: 500, y: 350, kind: .redaction(redaction))
        let spotlight = AnnoShape(x: -50, y: -50, kind: .highlight(HighlightProps(w: 200, h: 200)))
        expect(sameLayout(layout(size, AnnotationBackgroundSettings(), [blur, spotlight]), base),
               "a redaction or spotlight past the edge grew the canvas")

        // A stray shape far away cannot make an absurd canvas.
        let stray = arrow(from: Vec(600, 200), to: Vec(60_000, 200))
        let strayLayout = layout(size, AnnotationBackgroundSettings(), [stray])
        expect(strayLayout.canvasSize.width <= AnnotationCanvasGrowth.maximumCanvasDimension,
               "a stray shape grew the canvas to \(strayLayout.canvasSize)")

        // A note much wider than a small screenshot still fits beside it.
        let small = CGSize(width: 200, height: 120)
        let longNote = arrow(from: Vec(150, 60), to: Vec(900, 60))
        let smallLayout = layout(small, AnnotationBackgroundSettings(), [longNote])
        expect(smallLayout.canvasSize.width >= 900,
               "a note wider than a small screenshot was cut off: canvas \(smallLayout.canvasSize)")
    }

    // MARK: - Edge colour

    static func checkEdgeColor() {
        expect(components(AnnotationEdgeColor.match(flatScreenshot().cgImage)) == [236, 238, 242],
               "flat edge matched \(components(AnnotationEdgeColor.match(flatScreenshot().cgImage)))")
        expect(components(AnnotationEdgeColor.match(busyScreenshot().cgImage)) == [255, 255, 255],
               "busy edge matched \(components(AnnotationEdgeColor.match(busyScreenshot().cgImage)))")
        expect(components(AnnotationEdgeColor.match(transparentEdgeScreenshot().cgImage)) == [255, 255, 255],
               "transparent edge matched \(components(AnnotationEdgeColor.match(transparentEdgeScreenshot().cgImage)))")
        // A little noise on a flat edge still counts as flat.
        let noisy = flatScreenshot()
        for x in stride(from: 0, to: 640, by: 7) { noisy.fill(CGRect(x: x, y: 0, width: 1, height: 1), 240, 241, 245) }
        expect(components(AnnotationEdgeColor.match(noisy.cgImage)) == [236, 238, 242],
               "slightly noisy edge matched \(components(AnnotationEdgeColor.match(noisy.cgImage)))")
    }

    // MARK: - Export

    static func checkExport(writingTo directory: URL?) {
        let flatURL = flatScreenshot().write("flat.png")
        let busyURL = busyScreenshot().write("busy.png")
        let plain = AnnotationBackgroundSettings()
        let note = [
            ellipse(CGRect(x: 420, y: 300, width: 200, height: 80)),
            arrow(from: Vec(600, 320), to: Vec(760, 210)),
            text("Too far from\nthe content", at: Vec(700, 150)),
        ]

        // Flat edge: grows right, and the fill is the edge colour with no seam.
        let flat = render(flatURL, note, plain, to: "export-flat-edge.png")
        let flatLayout = layout(CGSize(width: 640, height: 400), plain, note)
        expect(CGFloat(flat.width) == flatLayout.canvasSize.width && flat.height == 400 && flat.width > 640,
               "flat export is \(flat.width)x\(flat.height), layout \(flatLayout.canvasSize)")
        expect(flat.pixel(640, 5) == [236, 238, 242, 255] && flat.pixel(flat.width - 1, 395) == [236, 238, 242, 255],
               "flat export's grown fill is \(flat.pixel(640, 5)), \(flat.pixel(flat.width - 1, 395))")
        expect(flat.pixel(639, 5) == flat.pixel(640, 5), "flat export has a seam at the old edge")
        var redInFill = 0
        for y in 0..<flat.height {
            for x in 640..<flat.width {
                let p = flat.pixel(x, y)
                if p[0] > 150 && p[1] < 120 { redInFill += 1 }
            }
        }
        expect(redInFill > 500, "the note beside the screenshot was not exported (\(redInFill) red pixels)")

        // Busy edge: white fill.
        let busy = render(busyURL, note, plain, to: "export-busy-edge.png")
        expect(busy.width == flat.width && busy.pixel(busy.width - 1, 395) == [255, 255, 255, 255],
               "busy export's fill is \(busy.pixel(busy.width - 1, 395))")

        // A picked colour wins over the matched one.
        var picked = plain
        picked.extensionFill = AnnotationBackgroundColor("custom", title: "Custom", red: 1, green: 0.95, blue: 0.8)
        let pickedImage = render(flatURL, note, picked, to: "export-picked-fill.png")
        expect(pickedImage.pixel(pickedImage.width - 1, 395) == [255, 242, 204, 255],
               "picked fill exported as \(pickedImage.pixel(pickedImage.width - 1, 395))")

        // Gradient background with a note below the card.
        let padded = AnnotationBackgroundLayout.make(contentSize: CGSize(width: 640, height: 400), settings: gradientSettings)
        let belowNote = [
            arrow(from: Vec(300, 360), to: Vec(260, 400 + padded.padding + 40)),
            text("Footer is cut off", at: Vec(150, 400 + padded.padding + 50)),
        ]
        let gradient = render(flatURL, belowNote, gradientSettings, to: "export-gradient-below.png")
        let gradientLayout = layout(CGSize(width: 640, height: 400), gradientSettings, belowNote)
        expect(CGFloat(gradient.height) == gradientLayout.canvasSize.height && gradient.height > Int(padded.canvasSize.height)
               && CGFloat(gradient.width) == padded.canvasSize.width,
               "gradient export is \(gradient.width)x\(gradient.height), padded canvas \(padded.canvasSize)")

        // Nothing outside: the same size and the same pixels as before, with and without a background.
        let insideShapes = [ellipse(CGRect(x: 200, y: 90, width: 300, height: 120)), arrow(from: Vec(100, 300), to: Vec(400, 200))]
        let inside = render(flatURL, insideShapes, plain, to: "export-inside.png")
        let reference = Image(flatScreenshot().cgImage)
        AnnotationRenderer.drawAnnotations(
            insideShapes, in: CGRect(x: 0, y: 0, width: 640, height: 400), pageSize: CGSize(width: 640, height: 400),
            canvasSize: CGSize(width: 640, height: 400), context: reference.context,
            colorSpace: reference.context.colorSpace!, highlightClipPath: nil
        )
        expect(inside.width == 640 && inside.height == 400, "inside export is \(inside.width)x\(inside.height)")
        expect(inside.bytes == reference.bytes, "inside export differs from the plain render")

        let insideGradient = render(flatURL, insideShapes, gradientSettings, to: "export-inside-gradient.png")
        let flatSource = flatScreenshot().cgImage
        let gradientReference = Image(try! AnnotationBackgroundRenderer.compose(
            contentImage: flatSource, settings: gradientSettings, colorSpace: flatSource.colorSpace!,
            foregroundOverlay: { context, layout, imageRect, clip in
                AnnotationRenderer.drawAnnotations(
                    insideShapes, in: imageRect, pageSize: CGSize(width: 640, height: 400),
                    canvasSize: layout.canvasSize, context: context, colorSpace: flatSource.colorSpace!,
                    highlightClipPath: clip
                )
            }
        ))
        expect(insideGradient.width == gradientReference.width && insideGradient.bytes == gradientReference.bytes,
               "inside export with a background differs from the ungrown compose")

        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["export-flat-edge.png", "export-busy-edge.png", "export-picked-fill.png",
                         "export-gradient-below.png", "export-inside.png", "flat.png", "busy.png"] {
                let destination = directory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: workDirectory.appendingPathComponent(name), to: destination)
                print("wrote \(destination.path)")
            }
        }
    }

    // MARK: - Document

    static func checkDocument() {
        // A document saved before the canvas could grow has no fill and opens as it did.
        let old = AnnotationDocument(shapes: [], background: AnnotationBackgroundSettings())
        var json = String(data: try! JSONEncoder().encode(old), encoding: .utf8)!
        expect(!json.contains("extensionFill"), "an unpicked fill is written to the document")
        json = json.replacingOccurrences(of: "\"extensionFill\":null,", with: "")
        let decoded = try! JSONDecoder().decode(AnnotationDocument.self, from: json.data(using: .utf8)!)
        expect(decoded.backgroundSettings.extensionFill == nil && decoded == old, "an old document did not round-trip")

        var settings = AnnotationBackgroundSettings()
        settings.extensionFill = AnnotationBackgroundColor("custom", title: "Custom", red: 0.2, green: 0.3, blue: 0.4)
        let picked = AnnotationDocument(shapes: [], background: settings)
        let reopened = try! JSONDecoder().decode(AnnotationDocument.self, from: try! JSONEncoder().encode(picked))
        expect(reopened.backgroundSettings.extensionFill == settings.extensionFill, "a picked fill did not survive reopening")
    }

    static func main() {
        checkGrowth()
        checkEdgeColor()
        checkExport(writingTo: CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil)
        checkDocument()
        try? FileManager.default.removeItem(at: workDirectory)

        if failures.isEmpty {
            print("Canvas growth checks passed: \(checks)")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("Canvas growth checks: \(failures.count) of \(checks) failed")
            exit(1)
        }
    }
}
