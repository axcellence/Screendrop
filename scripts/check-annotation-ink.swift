import AppKit
import CoreGraphics
import Foundation

// Checks the hand-drawn shape style against the real annotation engine,
// without launching the app:
//
// files=(Screendrop/Engine/*.swift)
// files=(${files:#*AnnoCanvasLayerView.swift}); files=(${files:#*AnnoTextEditorOverlay.swift})
// xcrun swiftc -module-cache-path /tmp/screendrop-ink-module-cache -default-isolation MainActor \
//   -swift-version 5 "${files[@]}" Screendrop/AnnotationSwatch.swift Screendrop/AnnotationTool.swift \
//   Screendrop/AnnotationRedactionImageProcessor.swift Screendrop/AnnoRedactionPreviewCache.swift \
//   Screendrop/AnnotationPresetStore.swift Screendrop/AnnotationMetrics.swift \
//   Screendrop/BoundedCGImageCache.swift scripts/check-annotation-ink.swift \
//   -o /tmp/screendrop-ink-check && /tmp/screendrop-ink-check
//
// Pass a directory as the first argument to also write PNG contact sheets there.
@main
struct AnnotationInkChecks {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { failures.append(message()) }
    }

    // MARK: - Rendering helpers

    /// An RGBA bitmap with page space mapped 1:1, y-down, the way the exporter lays it out.
    final class Bitmap {
        let width: Int
        let height: Int
        let context: CGContext

        init(width: Int, height: Int, background: NSColor?) {
            self.width = width
            self.height = height
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            if let background {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        /// Page space (y-down) to this bitmap (y-up).
        var pageTransform: CGAffineTransform {
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        }

        /// Fill a page-space rect, for laying down fake "text" under a highlight.
        func fillPageRect(_ rect: CGRect, _ color: NSColor) {
            context.setFillColor(color.cgColor)
            context.fill(rect.applying(pageTransform))
        }

        /// Premultiplied RGBA at a page-space pixel, each 0...1.
        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            guard x >= 0, y >= 0, x < width, y < height, let data = context.data else { return (0, 0, 0, 0) }
            let p = data.assumingMemoryBound(to: UInt8.self) + (y * width + x) * 4
            return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255, Double(p[3]) / 255)
        }

        func isInked(_ x: Int, _ y: Int) -> Bool { pixel(x, y).a > 0.5 }

        var inkedPixelCount: Int {
            var count = 0
            for y in 0..<height { for x in 0..<width where isInked(x, y) { count += 1 } }
            return count
        }

        var image: CGImage { context.makeImage()! }

        func writePNG(to url: URL) {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    static func document(_ shapes: [AnnoShape]) -> AnnoDocument {
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(shapes: shapes, bindings: []))
        return document
    }

    /// Draw shapes the way the exporter does: straight onto whatever is already in the bitmap.
    /// `sampling` hands the engine the exporter's view of what has been composed so far.
    static func export(_ shapes: [AnnoShape], onto bitmap: Bitmap, sampling: Bool = false) {
        let context = bitmap.context
        let target = AnnoShapeDrawing.Target(
            transform: bitmap.pageTransform,
            pageSize: CGSize(width: bitmap.width, height: bitmap.height),
            sample: !sampling ? nil : { rect in
                guard let snapshot = context.makeImage() else { return nil }
                let flipped = CGRect(
                    x: rect.minX, y: CGFloat(snapshot.height) - rect.maxY, width: rect.width, height: rect.height
                ).integral.intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
                guard flipped.width >= 1, flipped.height >= 1 else { return nil }
                return snapshot.cropping(to: flipped)
            },
            spotlightClip: nil,
            isFlippedContext: false
        )
        AnnoShapeDrawing.draw(document(shapes), in: bitmap.context, target: target)
    }

    static func rectangle(
        id: String, w: Double = 300, h: Double = 180, strokeWidth: Double = 8, dash: DashStyle
    ) -> AnnoShape {
        var props = GeoProps()
        props.geo = .rectangle
        props.w = w
        props.h = h
        props.strokeWidth = strokeWidth
        props.dash = dash
        return AnnoShape(id: AnnoShapeID(id), x: 60, y: 60, kind: .geo(props))
    }

    static func ellipse(
        id: String, w: Double = 300, h: Double = 180, strokeWidth: Double = 8, dash: DashStyle
    ) -> AnnoShape {
        var props = GeoProps()
        props.geo = .ellipse
        props.w = w
        props.h = h
        props.strokeWidth = strokeWidth
        props.dash = dash
        return AnnoShape(id: AnnoShapeID(id), x: 60, y: 60, kind: .geo(props))
    }

    static func arrow(
        id: String, to end: Vec = Vec(300, 120), strokeWidth: Double = 8, dash: DashStyle,
        head: Arrowhead = .arrow, bend: Double = 0
    ) -> AnnoShape {
        var props = ArrowProps()
        props.start = Vec(0, 0)
        props.end = end
        props.bend = bend
        props.strokeWidth = strokeWidth
        props.dash = dash
        props.arrowheadEnd = head
        return AnnoShape(id: AnnoShapeID(id), x: 60, y: 60, kind: .arrow(props))
    }

    /// Points along a straight drag, a few pixels apart like real pointer events.
    static func swipe(from a: Vec, to b: Vec, step: Double = 5) -> [Vec] {
        let count = Swift.max(2, Int(Vec.dist(a, b) / step))
        return (0...count).map { Vec.lrp(a, b, Double($0) / Double(count)) }
    }

    static func elements(_ shape: AnnoShape) -> [RenderElement] {
        AnnoShapeRenderer.elements(for: shape, in: document([shape]))
    }

    static func pathBounds(_ shape: AnnoShape) -> CGRect {
        elements(shape).compactMap { $0.cgPath?.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
    }

    static func samePath(_ a: AnnoShape, _ b: AnnoShape) -> Bool {
        let ea = elements(a), eb = elements(b)
        guard ea.count == eb.count else { return false }
        return zip(ea, eb).allSatisfy { $0.cgPath == $1.cgPath }
    }

    // MARK: - Hand-drawn shapes

    static func checkHandDrawnShapes() {
        // A hand-drawn outline is brush ink: a filled shape with thick and thin parts, not a
        // constant-width stroke of the clean path.
        for shape in [rectangle(id: "r1", dash: .draw), ellipse(id: "e1", dash: .draw)] {
            let drawn = elements(shape)
            expect(!drawn.isEmpty, "\(shape.tool) hand-drawn: renders something")
            expect(drawn.allSatisfy { $0.fill != nil && $0.stroke == nil },
                   "\(shape.tool) hand-drawn: is filled brush ink, not a stroked path")
        }

        // The clean style is untouched: one stroked path, exactly the shape's own outline.
        let clean = elements(rectangle(id: "r1", dash: .solid))
        expect(clean.count == 1 && clean[0].stroke != nil && clean[0].fill == nil,
               "rectangle clean: still a single stroked path")
        expect(clean.first?.cgPath?.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 300, height: 180),
               "rectangle clean: path is exactly the box")

        // Mild wobble: the ink stays close to the box it was dragged out as.
        for shape in [rectangle(id: "r1", dash: .draw), ellipse(id: "e1", dash: .draw)] {
            let bounds = pathBounds(shape)
            let box = CGRect(x: 0, y: 0, width: 300, height: 180)
            let slack: CGFloat = 8 * 2.5
            expect(box.insetBy(dx: -slack, dy: -slack).contains(bounds),
                   "\(shape.tool) hand-drawn: ink stays within \(slack)px of its box, got \(bounds)")
            expect(bounds.width > box.width - slack && bounds.height > box.height - slack,
                   "\(shape.tool) hand-drawn: ink still spans its box, got \(bounds)")
        }

        // Each shape has its own wobble, and keeps it: the same shape always draws the same way,
        // wherever it is moved, and two shapes never share one wobble.
        expect(samePath(rectangle(id: "r1", dash: .draw), rectangle(id: "r1", dash: .draw)),
               "rectangle hand-drawn: same shape draws identically every time")
        var moved = rectangle(id: "r1", dash: .draw)
        moved.x += 240
        moved.y -= 13
        expect(samePath(rectangle(id: "r1", dash: .draw), moved),
               "rectangle hand-drawn: moving a shape does not re-jiggle it")
        expect(!samePath(rectangle(id: "r1", dash: .draw), rectangle(id: "r2", dash: .draw)),
               "rectangle hand-drawn: two rectangles have different wobble")
        expect(!samePath(ellipse(id: "e1", dash: .draw), ellipse(id: "e2", dash: .draw)),
               "ellipse hand-drawn: two ellipses have different wobble")

        // The stroke width setting still means something: averaged along the outline, the ink is
        // about as heavy as the clean stroke would be.
        for (shape, cleanShape) in [
            (rectangle(id: "r1", dash: .draw), rectangle(id: "r1", dash: .solid)),
            (ellipse(id: "e1", dash: .draw), ellipse(id: "e1", dash: .solid)),
        ] {
            let drawn = Bitmap(width: 420, height: 300, background: nil)
            export([shape], onto: drawn)
            let reference = Bitmap(width: 420, height: 300, background: nil)
            export([cleanShape], onto: reference)
            let ratio = Double(drawn.inkedPixelCount) / Double(reference.inkedPixelCount)
            expect(ratio > 0.7 && ratio < 1.3,
                   "\(shape.tool) hand-drawn: ink weight is close to the clean stroke's, ratio \(ratio)")
        }

        // Thick and thin: the ink is not one even width all the way round.
        do {
            let bitmap = Bitmap(width: 420, height: 300, background: nil)
            export([rectangle(id: "r1", dash: .draw)], onto: bitmap)
            // Thickness of the top and bottom edges, measured down columns through each.
            var thicknesses: [Int] = []
            for x in stride(from: 120, through: 300, by: 12) {
                var top = 0
                for y in 30..<110 where bitmap.isInked(x, y) { top += 1 }
                var bottom = 0
                for y in 200..<280 where bitmap.isInked(x, y) { bottom += 1 }
                thicknesses.append(top)
                thicknesses.append(bottom)
            }
            let thinnest = thicknesses.min() ?? 0
            let thickest = thicknesses.max() ?? 0
            expect(thinnest >= 3, "rectangle hand-drawn: no gaps along its edges, thinnest \(thinnest)px")
            expect(thickest - thinnest >= 2,
                   "rectangle hand-drawn: has thick and thin parts, \(thinnest)...\(thickest)px")
        }
    }

    static func checkHandDrawnArrows() {
        let drawn = elements(arrow(id: "a1", dash: .draw))
        expect(!drawn.isEmpty && drawn.allSatisfy { $0.fill != nil && $0.stroke == nil },
               "arrow hand-drawn: body and head are filled brush ink")

        let clean = elements(arrow(id: "a1", dash: .solid))
        expect(clean.count == 2 && clean.allSatisfy { $0.stroke != nil },
               "arrow clean: still a stroked body and a stroked head")

        expect(!samePath(arrow(id: "a1", dash: .draw), arrow(id: "a2", dash: .draw)),
               "arrow hand-drawn: two arrows have different wobble")
        expect(samePath(arrow(id: "a1", dash: .draw), arrow(id: "a1", dash: .draw)),
               "arrow hand-drawn: same arrow draws identically every time")

        // The arrow still points where it was dragged to: ink reaches the tip, and the tail.
        for (name, shape) in [
            ("straight", arrow(id: "a1", dash: .draw)),
            ("bent", arrow(id: "a1", dash: .draw, bend: 60)),
            ("line", arrow(id: "a1", dash: .draw, head: .none)),
        ] {
            let bitmap = Bitmap(width: 460, height: 300, background: nil)
            export([shape], onto: bitmap)
            func inkNear(_ p: Vec, radius: Int) -> Bool {
                for dy in -radius...radius {
                    for dx in -radius...radius where bitmap.isInked(Int(p.x) + dx, Int(p.y) + dy) {
                        return true
                    }
                }
                return false
            }
            expect(inkNear(Vec(60 + 300, 60 + 120), radius: 8), "arrow hand-drawn (\(name)): ink reaches the tip")
            expect(inkNear(Vec(60, 60), radius: 8), "arrow hand-drawn (\(name)): ink reaches the tail")
        }

        // A line has no head, so it is a single brush stroke.
        expect(elements(arrow(id: "a1", dash: .draw, head: .none)).count == 1,
               "line hand-drawn: a single brush stroke")

        // Non-default heads keep their clean geometry, so they stay recognisable.
        let triangle = elements(arrow(id: "a1", dash: .draw, head: .triangle))
        expect(triangle.count == 2, "arrow hand-drawn with a triangle head: body plus head")
    }

    // MARK: - Editor

    /// An editor over a 1800px-wide screenshot shown at half size, with one drag performed.
    static func editorAfterDrag(
        tool: AnnotationTool, from a: Vec, to b: Vec, configure: (AnnoEditor) -> Void = { _ in }
    ) -> AnnoEditor {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(
            imageFrame: CGRect(x: 0, y: 0, width: 900, height: 600),
            imageSize: CGSize(width: 1800, height: 1200)
        )
        configure(editor)
        editor.tool = tool
        let points = swipe(from: a, to: b, step: 12)
        func pointer(_ page: Vec) -> PointerInfo {
            PointerInfo(screenPoint: editor.pageToScreen(page), pagePoint: page)
        }
        editor.pointerDown(pointer(points[0]))
        for point in points.dropFirst() { editor.pointerMove(pointer(point)) }
        editor.pointerUp(pointer(points[points.count - 1]))
        return editor
    }

    static func checkEditor() {
        // New outlines and lines are hand-drawn unless clean is chosen.
        for tool in [AnnotationTool.rectangle, .ellipse, .arrow, .line] {
            let drawn = editorAfterDrag(tool: tool, from: Vec(200, 300), to: Vec(700, 600))
            let dash = drawn.shapes.first?.geoProps?.dash ?? drawn.shapes.first?.arrowProps?.dash
            expect(dash == .draw, "editor: a new \(tool.title.lowercased()) is hand-drawn by default, got \(String(describing: dash))")

            let clean = editorAfterDrag(tool: tool, from: Vec(200, 300), to: Vec(700, 600)) { $0.currentDash = .solid }
            let cleanDash = clean.shapes.first?.geoProps?.dash ?? clean.shapes.first?.arrowProps?.dash
            expect(cleanDash == .solid, "editor: a new \(tool.title.lowercased()) is clean when clean is chosen")
        }

        // A solid rectangle has no outline to draw by hand; it stays as it was.
        do {
            let editor = editorAfterDrag(tool: .filledRectangle, from: Vec(200, 300), to: Vec(700, 600))
            if let shape = editor.shapes.first {
                let drawn = elements(shape)
                expect(drawn.count == 1 && drawn[0].cgPath?.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 500, height: 300),
                       "editor: a solid rectangle is still an exact filled box")
            } else {
                expect(false, "editor: a solid rectangle was created")
            }
        }
    }

    static func checkPreset() {
        // Preferences saved by a build without these features must still load, with their existing
        // values intact, and default to hand-drawn shapes.
        let legacy = Data("""
        {"selectedToolRawValue":"arrow","swatchID":"blue","strokeWidth":6,"redactionDensity":0.4,
         "textFontName":"SF Pro","textFontSize":32,"textIsBold":false,"textIsItalic":true,
         "textIsUnderline":false,"textAlignmentRawValue":0}
        """.utf8)
        do {
            let preset = try JSONDecoder().decode(AnnotationStylePreset.self, from: legacy)
            expect(preset.selectedTool == .arrow && preset.swatch == .blue && preset.strokeWidth == 6,
                   "preset: existing preferences survive")
            expect(preset.resolvedIsHandDrawn, "preset: shapes default to hand-drawn")
        } catch {
            expect(false, "preset: preferences saved before these features failed to load: \(error)")
        }

        // Choices are remembered.
        do {
            var preset = AnnotationStylePreset()
            preset.isHandDrawn = false
            let reloaded = try JSONDecoder().decode(AnnotationStylePreset.self, from: JSONEncoder().encode(preset))
            expect(!reloaded.resolvedIsHandDrawn, "preset: choosing clean is remembered")
        } catch {
            expect(false, "preset: round trip threw \(error)")
        }
    }

    // MARK: - Contact sheet

    static func writeSheets(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func sheet(_ name: String, _ shapes: [AnnoShape], size: CGSize) {
            let bitmap = Bitmap(width: Int(size.width), height: Int(size.height), background: NSColor(white: 0.98, alpha: 1))
            export(shapes, onto: bitmap)
            bitmap.writePNG(to: directory.appendingPathComponent("\(name).png"))
        }

        func place(_ shape: AnnoShape, _ x: Double, _ y: Double) -> AnnoShape {
            var shape = shape
            shape.x = x
            shape.y = y
            return shape
        }

        var shapes: [AnnoShape] = []
        for (row, dash) in [DashStyle.draw, .solid].enumerated() {
            let y = 60 + Double(row) * 300
            shapes.append(place(ellipse(id: "sheet-e\(row)", w: 320, h: 190, strokeWidth: 9, dash: dash), 60, y))
            shapes.append(place(rectangle(id: "sheet-r\(row)", w: 260, h: 150, strokeWidth: 9, dash: dash), 460, y + 20))
            shapes.append(place(arrow(id: "sheet-a\(row)", to: Vec(-380, -90), strokeWidth: 9, dash: dash), 1200, y + 170))
            shapes.append(place(arrow(id: "sheet-l\(row)", to: Vec(300, 40), strokeWidth: 9, dash: dash, head: .none), 800, y + 210))
        }
        sheet("hand-drawn", shapes, size: CGSize(width: 1280, height: 660))

        // Sizes and weights, to see the style hold up at the extremes.
        var extremes: [AnnoShape] = []
        var x = 40.0
        for (i, sw) in [3.0, 6.0, 12.0, 20.0].enumerated() {
            extremes.append(place(rectangle(id: "x-r\(i)", w: 40 + sw * 12, h: 30 + sw * 6, strokeWidth: sw, dash: .draw), x, 40))
            extremes.append(place(ellipse(id: "x-e\(i)", w: 40 + sw * 12, h: 30 + sw * 6, strokeWidth: sw, dash: .draw), x, 240))
            extremes.append(place(arrow(id: "x-a\(i)", to: Vec(40 + sw * 12, -(20 + sw * 4)), strokeWidth: sw, dash: .draw), x, 520))
            extremes.append(place(arrow(id: "x-b\(i)", to: Vec(40 + sw * 12, 30), strokeWidth: sw, dash: .draw, bend: 30 + sw * 3), x, 580))
            x += 80 + sw * 12
        }
        extremes.append(place(rectangle(id: "x-tiny", w: 24, h: 16, strokeWidth: 6, dash: .draw), 40, 700))
        extremes.append(place(ellipse(id: "x-tiny-e", w: 24, h: 24, strokeWidth: 6, dash: .draw), 100, 700))
        extremes.append(place(rectangle(id: "x-wide", w: 700, h: 40, strokeWidth: 6, dash: .draw), 180, 690))
        sheet("hand-drawn-sizes", extremes, size: CGSize(width: 960, height: 780))
    }

    static func main() {
        checkHandDrawnShapes()
        checkHandDrawnArrows()
        checkEditor()
        checkPreset()

        if CommandLine.arguments.count > 1 {
            writeSheets(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }

        if failures.isEmpty {
            print("Annotation ink checks passed: \(checks)")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("Annotation ink checks: \(failures.count) of \(checks) failed")
            exit(1)
        }
    }
}
