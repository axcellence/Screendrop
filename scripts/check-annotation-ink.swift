import AppKit
import CoreGraphics
import Foundation

// Checks the hand-drawn shape style, the highlighter and Handwriting text against the real
// annotation engine, without launching the app:
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
// Run it from the repository root: it points the engine at `Screendrop/Fonts` for Caveat, which
// the app reads from its bundle. Pass a directory as the first argument to also write PNG contact
// sheets there.
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

    // MARK: - Highlighter

    static let markerYellow = AnnotationSwatch("marker-yellow", title: "Yellow", red: 1, green: 0.93, blue: 0.2)

    /// A highlighter stroke through page-space points, as the editor would have recorded it.
    static func marker(
        id: String, through pagePoints: [Vec], width: Double = 30, complete: Bool = true,
        swatch: AnnotationSwatch = markerYellow
    ) -> AnnoShape {
        var props = DrawProps()
        props.ink = .marker
        props.strokeWidth = width
        props.swatch = swatch
        props.isComplete = complete
        let origin = pagePoints[0]
        props.points = pagePoints.map { Vec($0.x - origin.x, $0.y - origin.y, 0.5) }
        return AnnoShape(id: AnnoShapeID(id), x: origin.x, y: origin.y, kind: .draw(props))
    }

    /// How many separate bumps the right-hand end of a horizontal stroke has, counted across the
    /// middle of the band where a square corner cannot be mistaken for one.
    static func bumpsAtRightEnd(_ bitmap: Bitmap, rows: ClosedRange<Int>, searchFrom x0: Int) -> Int {
        var profile: [Int] = []
        for y in rows {
            var rightmost = x0
            for x in x0..<bitmap.width where bitmap.isInked(x, y) { rightmost = x }
            profile.append(rightmost)
        }
        // Count peaks that stand at least a pixel proud of the dips either side of them.
        var bumps = 0
        var low = profile[0]
        var high = profile[0]
        var rising = true
        for value in profile.dropFirst() {
            if rising {
                if value > high { high = value }
                if value <= high - 2 {
                    if high - low >= 2 { bumps += 1 }
                    rising = false
                    low = value
                }
            } else {
                if value < low { low = value }
                if value >= low + 2 {
                    rising = true
                    high = value
                }
            }
        }
        if rising, high - low >= 2 { bumps += 1 }
        return bumps
    }

    static func checkHighlighterModel() {
        let pen = AnnoShape(id: AnnoShapeID("pen"), x: 0, y: 0, kind: .draw(DrawProps()))
        let highlight = marker(id: "m", through: swipe(from: Vec(40, 60), to: Vec(340, 60)))
        expect(pen.tool == .freehand, "a pen stroke still belongs to the freehand tool")
        expect(highlight.tool == .marker, "a highlighter stroke belongs to the highlighter tool")
        expect(AnnotationTool.marker.title == "Highlighter", "the highlighter tool is called Highlighter")
        expect(AnnotationTool.highlight.title == "Highlight", "the spotlight tool keeps its name")

        // Screenshots annotated before the highlighter existed have no ink style on their strokes.
        // They must still open, as pen strokes.
        do {
            var penProps = DrawProps()
            penProps.points = [Vec(0, 0, 0.5), Vec(10, 4, 0.5)]
            penProps.isComplete = true
            let shape = AnnoShape(id: AnnoShapeID("old"), x: 5, y: 6, kind: .draw(penProps))
            let data = try JSONEncoder().encode(shape)

            func strippingInk(_ value: Any) -> Any {
                if let dictionary = value as? [String: Any] {
                    var copy: [String: Any] = [:]
                    for (key, inner) in dictionary where key != "ink" { copy[key] = strippingInk(inner) }
                    return copy
                }
                if let array = value as? [Any] { return array.map(strippingInk) }
                return value
            }
            let legacy = try JSONSerialization.data(
                withJSONObject: strippingInk(try JSONSerialization.jsonObject(with: data))
            )
            expect(!String(decoding: legacy, as: UTF8.self).contains("\"ink\""), "legacy fixture has no ink key")
            let decoded = try JSONDecoder().decode(AnnoShape.self, from: legacy)
            expect(decoded == shape, "a stroke saved without an ink style opens as the same pen stroke")

            let roundTripped = try JSONDecoder().decode(AnnoShape.self, from: JSONEncoder().encode(highlight))
            expect(roundTripped == highlight, "a highlighter stroke survives saving and reopening")
        } catch {
            expect(false, "stroke encoding threw \(error)")
        }
    }

    static func checkHighlighterShape() {
        // Constant width, whatever the speed: unevenly spaced points draw one even band.
        do {
            var points = swipe(from: Vec(40, 100), to: Vec(200, 100), step: 2)
            points += swipe(from: Vec(200, 100), to: Vec(440, 100), step: 24).dropFirst()
            let bitmap = Bitmap(width: 500, height: 200, background: nil)
            export([marker(id: "m", through: points, width: 30)], onto: bitmap)
            var heights: [Int] = []
            for x in stride(from: 90, through: 390, by: 20) {
                var height = 0
                for y in 0..<200 where bitmap.isInked(x, y) { height += 1 }
                heights.append(height)
            }
            expect(heights.allSatisfy { abs($0 - 30) <= 1 },
                   "highlighter: band is the chosen width along its whole length, got \(heights)")
        }

        // The marker edge: a finished stroke ends in a scalloped cut, not a round or square cap.
        do {
            let points = swipe(from: Vec(40, 100), to: Vec(340, 100))
            let finished = Bitmap(width: 420, height: 200, background: nil)
            export([marker(id: "m", through: points, width: 40)], onto: finished)
            let bumps = bumpsAtRightEnd(finished, rows: 84...116, searchFrom: 300)
            expect(bumps >= 2, "highlighter: a finished stroke has a scalloped end, found \(bumps) bump(s)")

            // The cut is shallow: it roughens the end without lengthening the stroke noticeably.
            var rightmost = 0
            for y in 80...120 { for x in 300..<420 where finished.isInked(x, y) { rightmost = Swift.max(rightmost, x) } }
            expect(rightmost >= 338 && rightmost <= 340 + 8,
                   "highlighter: the scalloped end stays at the pointer, reached x=\(rightmost)")

            // While the stroke is still being dragged, its leading end is plain.
            let dragging = Bitmap(width: 420, height: 200, background: nil)
            export([marker(id: "m", through: points, width: 40, complete: false)], onto: dragging)
            let liveBumps = bumpsAtRightEnd(dragging, rows: 84...116, searchFrom: 300)
            expect(liveBumps <= 1, "highlighter: the leading end is plain while dragging, found \(liveBumps) bump(s)")
        }

        // Each stroke has its own edge, and keeps it.
        do {
            let points = swipe(from: Vec(40, 100), to: Vec(340, 100))
            expect(samePath(marker(id: "m1", through: points), marker(id: "m1", through: points)),
                   "highlighter: the same stroke draws identically every time")
            expect(!samePath(marker(id: "m1", through: points), marker(id: "m2", through: points)),
                   "highlighter: two strokes have different marker edges")
        }

        // It can be grabbed anywhere on the band, not just along its centre line.
        do {
            let shape = marker(id: "m", through: swipe(from: Vec(40, 100), to: Vec(340, 100)), width: 40)
            let doc = document([shape])
            func hit(_ page: Vec) -> Bool {
                doc.geometry(shape).hitTestPoint(doc.pointInShapeSpace(shape, page), margin: 0, hitInside: shape.isFilled)
            }
            expect(hit(Vec(200, 100)), "highlighter: clicking the middle of the band grabs it")
            expect(hit(Vec(200, 116)), "highlighter: clicking near the band's edge grabs it")
            expect(!hit(Vec(200, 130)), "highlighter: clicking outside the band misses it")
            let bounds = doc.pageBounds(shape.id)
            expect(bounds.map { abs($0.h - 40) <= 3 && $0.w >= 300 } ?? false,
                   "highlighter: selection frame wraps the whole band, got \(String(describing: bounds))")
        }

        // A single click leaves a dab rather than nothing or a crash.
        do {
            let bitmap = Bitmap(width: 200, height: 200, background: nil)
            export([marker(id: "dab", through: [Vec(100, 100), Vec(101, 100)], width: 30)], onto: bitmap)
            expect(bitmap.isInked(100, 100), "highlighter: a tiny stroke still leaves a mark")
        }
    }

    /// White paper with a black bar across the top half, standing in for text.
    static func paper(width: Int = 400, height: Int = 200) -> Bitmap {
        let bitmap = Bitmap(width: width, height: height, background: .white)
        bitmap.fillPageRect(CGRect(x: 150, y: 40, width: 60, height: 40), .black)
        return bitmap
    }

    static func isYellow(_ p: (r: Double, g: Double, b: Double, a: Double)) -> Bool {
        p.r > 0.9 && p.g > 0.85 && p.b < 0.8 && p.b > 0.3
    }

    static func checkHighlighterInk() {
        let stroke = marker(id: "m", through: swipe(from: Vec(60, 60), to: Vec(340, 60)), width: 30)

        // Exported: the paper is tinted, and the text under the highlight stays as dark as it was.
        let exported = paper()
        export([stroke], onto: exported)
        expect(isYellow(exported.pixel(100, 60)), "highlighter export: paper is tinted yellow, got \(exported.pixel(100, 60))")
        let text = exported.pixel(180, 60)
        expect(text.r < 0.08 && text.g < 0.08 && text.b < 0.08,
               "highlighter export: text under the highlight stays dark, got \(text)")
        let untouched = exported.pixel(100, 150)
        expect(untouched.r > 0.99 && untouched.b > 0.99, "highlighter export: paper outside the stroke is untouched")

        // A pen stroke is unaffected by any of this: it still paints over what is beneath it.
        do {
            var props = DrawProps()
            props.strokeWidth = 12
            props.swatch = .red
            props.isComplete = true
            props.points = swipe(from: Vec(0, 0), to: Vec(280, 0)).map { Vec($0.x, $0.y, 0.5) }
            let penned = paper()
            export([AnnoShape(id: AnnoShapeID("pen"), x: 60, y: 60, kind: .draw(props))], onto: penned)
            let over = penned.pixel(180, 60)
            expect(over.r > 0.9 && over.g < 0.4, "pen: still paints over the text beneath it, got \(over)")
        }

        // On the canvas the annotation layer is transparent and sits above the screenshot, so the
        // highlight has to bring the screenshot's own pixels with it. Composited over the
        // screenshot, the result must match the export.
        for flipped in [false, true] {
            let backdrop = paper().image
            let layer = Bitmap(width: 400, height: 200, background: nil)
            var transform = layer.pageTransform
            if flipped {
                // An NSView-style flipped context: y-down already, so page space maps straight in.
                layer.context.translateBy(x: 0, y: 200)
                layer.context.scaleBy(x: 1, y: -1)
                transform = .identity
            }
            let target = AnnoShapeDrawing.Target(
                transform: transform,
                pageSize: CGSize(width: 400, height: 200),
                sample: nil,
                spotlightClip: nil,
                isFlippedContext: flipped,
                backdrop: backdrop
            )
            AnnoShapeDrawing.draw(document([stroke]), in: layer.context, target: target)

            let composed = paper()
            composed.context.draw(layer.image, in: CGRect(x: 0, y: 0, width: 400, height: 200))
            let name = flipped ? "flipped canvas" : "canvas"
            for (x, y) in [(100, 60), (180, 60), (180, 52), (100, 150), (180, 100), (300, 66)] {
                let a = composed.pixel(x, y)
                let b = exported.pixel(x, y)
                let same = abs(a.r - b.r) < 0.03 && abs(a.g - b.g) < 0.03 && abs(a.b - b.b) < 0.03
                expect(same, "highlighter \(name): matches the export at (\(x), \(y)), got \(a) vs \(b)")
            }
            expect(layer.pixel(100, 150).a < 0.01, "highlighter \(name): leaves the rest of the layer clear")
        }

        // Two strokes crossing darken where they meet, like a real marker...
        do {
            let across = marker(id: "across", through: swipe(from: Vec(40, 100), to: Vec(360, 100)), width: 30)
            let down = marker(id: "down", through: swipe(from: Vec(280, 20), to: Vec(280, 180)), width: 30)
            let bitmap = Bitmap(width: 400, height: 200, background: .white)
            export([across, down], onto: bitmap)
            let single = bitmap.pixel(120, 100)
            let crossing = bitmap.pixel(280, 100)
            expect(crossing.b < single.b - 0.1,
                   "highlighter: two strokes darken where they cross, \(crossing.b) vs \(single.b)")
        }

        // ...but one stroke doubling back over itself stays even.
        do {
            var points = swipe(from: Vec(60, 100), to: Vec(340, 100))
            points += swipe(from: Vec(340, 100), to: Vec(340, 110)).dropFirst()
            points += swipe(from: Vec(340, 110), to: Vec(120, 110)).dropFirst()
            let bitmap = Bitmap(width: 400, height: 220, background: .white)
            export([marker(id: "loop", through: points, width: 30)], onto: bitmap)
            let once = bitmap.pixel(80, 92)
            let twice = bitmap.pixel(220, 105)
            expect(isYellow(twice) && abs(once.b - twice.b) < 0.02 && abs(once.g - twice.g) < 0.02,
                   "highlighter: a stroke crossing itself stays one even tint, \(once) vs \(twice)")
        }

        // Highlights sit on the paper, beneath every other annotation.
        do {
            var props = GeoProps()
            props.w = 80
            props.h = 60
            props.fill = .solid
            props.swatch = .blue
            let box = AnnoShape(id: AnnoShapeID("box"), x: 160, y: 30, kind: .geo(props))
            let bitmap = Bitmap(width: 400, height: 200, background: .white)
            // The highlight is added after the box, yet must not tint it.
            export([box, stroke], onto: bitmap)
            let onBox = bitmap.pixel(200, 60)
            expect(abs(onBox.r - 0.18) < 0.03 && abs(onBox.b - 1) < 0.03,
                   "highlighter: other annotations stay on top of it, got \(onBox)")
        }
    }

    /// A dark-mode screenshot: near-black paper with a light bar standing in for text.
    static func darkPaper(width: Int = 400, height: Int = 200) -> Bitmap {
        let bitmap = Bitmap(width: width, height: height, background: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        bitmap.fillPageRect(CGRect(x: 150, y: 40, width: 60, height: 40), NSColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        return bitmap
    }

    static func checkHighlighterOnDarkScreenshots() {
        let stroke = marker(id: "m", through: swipe(from: Vec(60, 60), to: Vec(340, 60)), width: 30)

        // A multiply can only darken, which on a dark screenshot would leave no visible mark. There
        // the highlight lightens instead: the dark paper takes the colour and light text stays light.
        let exported = darkPaper()
        export([stroke], onto: exported, sampling: true)
        let paperPixel = exported.pixel(100, 60)
        expect(paperPixel.r > 0.35 && paperPixel.g > 0.3 && paperPixel.b < paperPixel.r - 0.2,
               "highlighter on dark: the paper visibly takes the colour, got \(paperPixel)")
        let text = exported.pixel(180, 60)
        expect(text.r > 0.85 && text.g > 0.85, "highlighter on dark: light text stays light, got \(text)")
        let untouched = exported.pixel(100, 150)
        expect(abs(untouched.r - 0.11) < 0.02, "highlighter on dark: paper outside the stroke is untouched")

        // And the canvas agrees with the export there too.
        let layer = Bitmap(width: 400, height: 200, background: nil)
        let target = AnnoShapeDrawing.Target(
            transform: layer.pageTransform,
            pageSize: CGSize(width: 400, height: 200),
            sample: nil,
            spotlightClip: nil,
            isFlippedContext: false,
            backdrop: darkPaper().image
        )
        AnnoShapeDrawing.draw(document([stroke]), in: layer.context, target: target)
        let composed = darkPaper()
        composed.context.draw(layer.image, in: CGRect(x: 0, y: 0, width: 400, height: 200))
        for (x, y) in [(100, 60), (180, 60), (100, 150), (300, 66)] {
            let a = composed.pixel(x, y)
            let b = exported.pixel(x, y)
            let same = abs(a.r - b.r) < 0.03 && abs(a.g - b.g) < 0.03 && abs(a.b - b.b) < 0.03
            expect(same, "highlighter on dark canvas: matches the export at (\(x), \(y)), got \(a) vs \(b)")
        }

        // A light screenshot with a lot of dark text on it is still a light screenshot.
        do {
            let busy = Bitmap(width: 400, height: 200, background: .white)
            for x in stride(from: 60, to: 340, by: 20) {
                busy.fillPageRect(CGRect(x: x, y: 48, width: 8, height: 24), .black)
            }
            export([stroke], onto: busy, sampling: true)
            let ink = busy.pixel(64, 60)
            expect(ink.r < 0.08 && ink.g < 0.08, "highlighter: dense dark text on white paper stays dark, got \(ink)")
            expect(isYellow(busy.pixel(74, 60)), "highlighter: white paper between dense text is still tinted yellow")
        }
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
        // Dragging with the highlighter leaves one highlighter stroke, in the highlighter's own
        // colour and size rather than the pen's, and stays on the tool for the next line.
        do {
            let editor = editorAfterDrag(tool: .marker, from: Vec(200, 300), to: Vec(900, 310)) { editor in
                editor.currentSwatch = .red
                editor.currentStrokeWidth = 4
            }
            let shape = editor.shapes.first
            expect(editor.shapes.count == 1 && shape?.isMarker == true, "editor: the highlighter tool draws a highlighter stroke")
            expect(shape?.swatch == .markerYellow, "editor: a new highlight is yellow by default, got \(String(describing: shape?.swatch?.id))")
            // 24 on the inspector's scale is authored against a 900px image; this one is 1800px.
            expect(shape?.strokeWidth == 48, "editor: a new highlight uses the highlighter's size, got \(String(describing: shape?.strokeWidth))")
            expect(shape?.drawProps?.isComplete == true, "editor: lifting the pointer finishes the stroke")
            expect(editor.tool == .marker, "editor: stays on the highlighter after a stroke")
        }

        // Its colour and size follow the highlighter's settings.
        do {
            let editor = editorAfterDrag(tool: .marker, from: Vec(200, 300), to: Vec(900, 310)) { editor in
                editor.currentMarkerSwatch = .green
                editor.currentMarkerWidth = 12
            }
            expect(editor.shapes.first?.swatch == .green, "editor: a highlight takes the chosen highlighter colour")
            expect(editor.shapes.first?.strokeWidth == 24, "editor: a highlight takes the chosen highlighter size")
        }

        // The pen is unchanged, and does not pick up the highlighter's settings.
        do {
            let editor = editorAfterDrag(tool: .freehand, from: Vec(200, 300), to: Vec(900, 310)) { editor in
                editor.currentSwatch = .red
                editor.currentStrokeWidth = 4
                editor.currentMarkerSwatch = .green
            }
            let shape = editor.shapes.first
            expect(shape?.tool == .freehand && shape?.swatch == .red && shape?.strokeWidth == 8,
                   "editor: the pen still draws a pen stroke in the pen's colour and width")
        }

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
        expect(AnnotationStylePreset().resolvedTextFontFamily == .handwriting
               && AnnoEditor().currentFontFamily == .handwriting,
               "preset: new text defaults to Handwriting")
        // Preferences saved by a build without these features must still load, with their existing
        // values intact, and default to hand-drawn shapes and a yellow highlighter.
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
            expect(preset.resolvedMarkerSwatch == .markerYellow, "preset: the highlighter defaults to yellow")
            expect(preset.resolvedMarkerWidth == 24, "preset: the highlighter defaults to a medium tip")
            expect(preset.resolvedTextFontFamily == .handwriting,
                   "preset: a text style remembered before Handwriting switches to it once")
            expect(preset.textFontSize == 32 && !preset.textIsBold && preset.textIsItalic,
                   "preset: the rest of the remembered text style survives")
        } catch {
            expect(false, "preset: preferences saved before these features failed to load: \(error)")
        }

        // Choices are remembered.
        do {
            var preset = AnnotationStylePreset()
            preset.selectedToolRawValue = AnnotationTool.marker.rawValue
            preset.isHandDrawn = false
            preset.markerSwatch = CodableSwatch(swatch: .pink)
            preset.markerWidth = 32
            preset.textFontFamily = AnnoFontFamily.pro.rawValue
            let reloaded = try JSONDecoder().decode(AnnotationStylePreset.self, from: JSONEncoder().encode(preset))
            expect(reloaded.selectedTool == .marker, "preset: the highlighter is remembered as the last tool")
            expect(!reloaded.resolvedIsHandDrawn, "preset: choosing clean is remembered")
            expect(reloaded.resolvedMarkerSwatch == .pink, "preset: the highlighter colour is remembered")
            expect(reloaded.resolvedMarkerWidth == 32, "preset: the highlighter size is remembered")
            expect(reloaded.resolvedTextFontFamily == .pro, "preset: picking SF Pro after the switch is remembered")
        } catch {
            expect(false, "preset: round trip threw \(error)")
        }
    }

    // MARK: - Handwriting text

    static func text(
        _ string: String, family: AnnoFontFamily = .handwriting, size: Double = 48, bold: Bool = true,
        italic: Bool = false, underline: Bool = false, wrapWidth: Double? = nil
    ) -> TextProps {
        var props = TextProps()
        props.text = string
        props.fontSize = size
        props.fontFamily = family
        props.isBold = bold
        props.isItalic = italic
        props.isUnderline = underline
        if let wrapWidth {
            props.autoSize = false
            props.w = wrapWidth
        }
        return props
    }

    static let descenders = "Left alignment gets messy (jpg)"

    static func checkHandwritingFirstUseOffMain() {
        // Exports lay text out on a detached task, so the font may be loaded there first.
        var family: String?
        DispatchQueue.global().sync {
            family = HandwritingFont.font(size: 30, isBold: true)?.familyName
        }
        expect(family == "Caveat", "handwriting: Caveat loads off the main thread (got \(family ?? "nil"))")
    }

    static func checkHandwritingText() {
        let bold = TextMeasure.font(text(descenders))
        let regular = TextMeasure.font(text(descenders, bold: false))
        expect(bold.familyName == "Caveat", "handwriting: bold resolves to Caveat, not \(bold.familyName ?? "nil")")
        expect(regular.familyName == "Caveat", "handwriting: regular resolves to Caveat, not \(regular.familyName ?? "nil")")
        expect(TextMeasure.font(text(descenders, family: .pro)).familyName != "Caveat",
               "handwriting: SF Pro text is still SF Pro")
        expect(AnnoFontFamily.allCases.last == .handwriting && AnnoFontFamily.handwriting.title == "Handwriting",
               "handwriting: listed as Handwriting after the SF faces")

        // Weight follows Bold.
        let boldPath = TextMeasure.glyphPath(text(descenders))
        let regularPath = TextMeasure.glyphPath(text(descenders, bold: false))
        expect(boldPath != regularPath, "handwriting: bold and regular draw different outlines")
        func ink(_ path: CGPath) -> Int {
            let bitmap = Bitmap(width: 900, height: 120, background: nil)
            bitmap.context.concatenate(bitmap.pageTransform)
            bitmap.context.addPath(path)
            bitmap.context.fillPath()
            return bitmap.inkedPixelCount
        }
        let boldInk = ink(boldPath), regularInk = ink(regularPath)
        expect(Double(boldInk) > Double(regularInk) * 1.15,
               "handwriting: bold carries more ink than regular (\(boldInk) vs \(regularInk))")

        // No italic: the outline stays upright, with no synthesised slant.
        let italic = TextMeasure.font(text(descenders, italic: true))
        expect(TextMeasure.glyphPath(text(descenders, italic: true)) == boldPath
               && TextMeasure.glyphPath(text(descenders, bold: false, italic: true)) == regularPath,
               "handwriting: italic leaves the outline upright")
        expect(italic.familyName == "Caveat" && CTFontGetMatrix(italic as CTFont) == .identity,
               "handwriting: italic is still unslanted Caveat")
        expect(!AnnoFontFamily.handwriting.supportsItalic && AnnoFontFamily.pro.supportsItalic,
               "handwriting: the Italic toggle is off only for Handwriting")

        // Caveat's tall ascenders and long descenders fit the pinned line box, so nothing clips.
        // Sideways, a handwritten stroke can run a little past its advance (as SF's "j" does on
        // the left); text isn't clipped to its box, so allow a sliver of the font size there.
        for size in [14.0, 48, 120] {
            for isBold in [true, false] {
                for underline in [false, true] {
                    for wrap in [nil, size * 6] as [Double?] {
                        let props = text(descenders, size: size, bold: isBold, underline: underline, wrapWidth: wrap)
                        let box = CGRect(origin: .zero, size: TextMeasure.measure(props))
                        let glyphs = TextMeasure.glyphPath(props).boundingBoxOfPath
                        let label = "size \(size), \(isBold ? "bold" : "regular")\(underline ? ", underlined" : "")\(wrap == nil ? "" : ", wrapped")"
                        let slack = size * 0.15
                        expect(!glyphs.isEmpty && glyphs.minY >= box.minY && glyphs.maxY <= box.maxY
                               && glyphs.minX >= box.minX - slack && glyphs.maxX <= box.maxX + slack,
                               "handwriting: glyphs \(glyphs) fit the measured box \(box) (\(label))")
                    }
                }
            }
        }

        // Wrapping into a narrow box makes it taller than one line.
        let oneLine = TextMeasure.measure(text(descenders))
        let wrapped = TextMeasure.measure(text(descenders, wrapWidth: 260))
        expect(wrapped.width == 260 && wrapped.height > TextMeasure.lineHeight(text(descenders)) * 1.5,
               "handwriting: a wrapped box (\(wrapped)) is taller than one line (\(oneLine))")

        // The text view lays out at view scale with the page size as the optical size; it must pick
        // the same face and weight, scaled, or the text jumps when editing ends.
        for isBold in [true, false] {
            let page = text(descenders, size: 32, bold: isBold)
            var view = page
            view.fontSize = 32 * 2.5
            let pageFont = TextMeasure.font(page)
            let viewFont = TextMeasure.font(view, opticalSize: page.fontSize)
            let pageVariation = CTFontCopyVariation(pageFont as CTFont) as? [NSNumber: NSNumber]
            let viewVariation = CTFontCopyVariation(viewFont as CTFont) as? [NSNumber: NSNumber]
            expect(viewFont.fontName == pageFont.fontName && viewVariation == pageVariation,
                   "handwriting: the editing text view uses the committed face (\(viewFont.fontName) vs \(pageFont.fontName))")
            let pageWidth = TextMeasure.measure(page).width
            let viewWidth = TextMeasure.measure(view).width
            expect(abs(viewWidth / 2.5 - pageWidth) <= 2,
                   "handwriting: the box scales with zoom (\(viewWidth / 2.5) vs \(pageWidth))")
        }
    }

    /// Run as a child with no font file: Handwriting falls back to SF Pro and still draws.
    static func checkHandwritingFallback() -> Never {
        let props = text(descenders)
        let font = TextMeasure.font(props)
        let fallback = TextMeasure.font(text(descenders, family: .pro))
        let path = TextMeasure.glyphPath(props)
        let ok = font.fontName == fallback.fontName && !path.boundingBoxOfPath.isEmpty
        print(ok ? "fallback ok: \(font.fontName)" : "fallback FAILED: \(font.fontName)")
        exit(ok ? 0 : 1)
    }

    static func checkHandwritingFallbackInChild() {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        environment[HandwritingFont.directoryEnvironmentKey] = "/nonexistent"
        environment["SCREENDROP_CHECK_FALLBACK"] = "1"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        do {
            try child.run()
            child.waitUntilExit()
            expect(child.terminationStatus == 0, "handwriting: without the font file, text falls back to SF Pro")
        } catch {
            expect(false, "handwriting: fallback child failed to start: \(error)")
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

        writeHighlighterSheet(to: directory)
        writeHandwritingSheet(to: directory)
    }

    /// Handwriting text, regular and bold, with each measured box outlined to show nothing clips.
    static func writeHandwritingSheet(to directory: URL) {
        let bitmap = Bitmap(width: 1300, height: 720, background: NSColor(white: 0.98, alpha: 1))
        var shapes: [AnnoShape] = []
        var y = 30.0
        let rows: [(TextProps, Double)] = [
            (text(descenders, size: 64, bold: false), 40),
            (text(descenders, size: 64), 40),
            (text("Regular, underlined: quick brown fox", size: 40, bold: false, underline: true), 40),
            (text("Bold, underlined: quick brown fox", size: 40, underline: true), 40),
            (text("Small regular 18 pt: Hyphy jumps (gq)", size: 18, bold: false), 40),
            (text("Small bold 18 pt: Hyphy jumps (gq)", size: 18), 40),
            (text("A wrapped note in bold that runs over several lines, with descenders: jpgqy",
                  size: 44, wrapWidth: 520), 40),
        ]
        for (i, (props, x)) in rows.enumerated() {
            var props = props
            props.swatch = i.isMultiple(of: 2) ? .red : .blue
            let box = TextMeasure.measure(props)
            bitmap.context.setStrokeColor(NSColor(white: 0.75, alpha: 1).cgColor)
            bitmap.context.setLineWidth(1)
            bitmap.context.stroke(CGRect(x: x, y: y, width: box.width, height: box.height)
                .applying(bitmap.pageTransform).insetBy(dx: -0.5, dy: -0.5))
            shapes.append(AnnoShape(id: AnnoShapeID("hw-\(i)"), x: x, y: y, kind: .text(props)))
            y += box.height + 24
        }
        var wrappedRegular = text("The same note in regular that runs over several lines, with descenders: jpgqy",
                                  size: 44, bold: false, wrapWidth: 520)
        wrappedRegular.swatch = .blue
        shapes.append(AnnoShape(id: AnnoShapeID("hw-wrap-regular"), x: 820, y: y - TextMeasure.measure(rows.last!.0).height - 24,
                                kind: .text(wrappedRegular)))
        export(shapes, onto: bitmap)
        bitmap.writePNG(to: directory.appendingPathComponent("handwriting.png"))
    }

    /// Highlighter strokes over some real text, the way they are used.
    static func writeHighlighterSheet(to directory: URL) {
        let bitmap = Bitmap(width: 1100, height: 520, background: NSColor(white: 0.985, alpha: 1))
        let lines = [
            "Good, that makes it simpler: no text detection needed. It's a marker",
            "passes over, and the wavy ends come from the tip shape rather than",
            "That leaves one thing your picture can't tell me. The band in it is very",
            "If your hand drifts up or down partway through a swipe in Shottr, does",
            "out as a straight band anyway?",
        ]
        let font = NSFont.systemFont(ofSize: 26)
        let graphics = NSGraphicsContext(cgContext: bitmap.context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for (i, line) in lines.enumerated() {
            let y = CGFloat(bitmap.height) - 90 - CGFloat(i) * 62
            (line as NSString).draw(
                at: CGPoint(x: 60, y: y),
                withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1)]
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        var wave: [Vec] = []
        for i in 0...120 {
            let t = Double(i) / 120
            wave.append(Vec(60 + 640 * t, 110 + 34 * sin(t * PI2 * 1.6)))
        }
        let shapes = [
            marker(id: "sheet-wave", through: wave, width: 38),
            marker(id: "sheet-straight", through: swipe(from: Vec(62, 264), to: Vec(360, 262)), width: 38),
            marker(id: "sheet-green", through: swipe(from: Vec(420, 262), to: Vec(700, 266)), width: 38, swatch: .green),
            marker(id: "sheet-pink", through: swipe(from: Vec(62, 324), to: Vec(300, 328)), width: 22, swatch: .pink),
            marker(id: "sheet-blue", through: swipe(from: Vec(340, 326), to: Vec(660, 322)), width: 54, swatch: .blue),
            marker(id: "sheet-live", through: swipe(from: Vec(62, 388), to: Vec(330, 386)), width: 38, complete: false),
            marker(id: "sheet-cross-a", through: swipe(from: Vec(780, 120), to: Vec(1040, 120)), width: 38),
            marker(id: "sheet-cross-b", through: swipe(from: Vec(910, 40), to: Vec(910, 220)), width: 38),
        ]
        export(shapes, onto: bitmap)
        bitmap.writePNG(to: directory.appendingPathComponent("highlighter.png"))
    }

    static func main() {
        if ProcessInfo.processInfo.environment["SCREENDROP_CHECK_FALLBACK"] != nil { checkHandwritingFallback() }
        // The app finds Caveat in its bundle; this binary isn't in one.
        setenv(HandwritingFont.directoryEnvironmentKey, "Screendrop/Fonts", 0)
        checkHandwritingFirstUseOffMain()

        checkHandDrawnShapes()
        checkHandDrawnArrows()
        checkHighlighterModel()
        checkHighlighterShape()
        checkHighlighterInk()
        checkHighlighterOnDarkScreenshots()
        checkEditor()
        checkPreset()
        checkHandwritingText()
        checkHandwritingFallbackInChild()

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
