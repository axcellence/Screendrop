//
//  AnnotationCanvasGrowth.swift
//  Screendrop
//

import CoreGraphics

/// Where one annotation sits in page space (the screenshot's own pixels, y down).
///
/// `geometry` is the shape as placed: its outline, points or text box. `ink` is everything it
/// paints: stroke width, arrowheads, hand-drawn overshoot and glyphs.
nonisolated struct AnnotationInkExtent: Equatable, Sendable {
    var geometry: CGRect
    var ink: CGRect

    func scaled(by scale: CGFloat) -> AnnotationInkExtent {
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        return AnnotationInkExtent(geometry: geometry.applying(transform), ink: ink.applying(transform))
    }
}

/// How far the canvas grows past its usual edges to hold annotations drawn outside it.
nonisolated struct AnnotationCanvasGrowth: Equatable, Sendable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    static let zero = AnnotationCanvasGrowth()

    var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }

    /// Space left between a shape's ink and the grown edge, as a fraction of the screenshot's
    /// shorter side.
    static let marginFraction: CGFloat = 0.04
    /// The grown canvas is never wider or taller than this, so a stray shape far away cannot ask
    /// for an enormous bitmap. Ink beyond the cap is cut off at the edge.
    static let maximumCanvasDimension: CGFloat = 10_000

    /// The growth for `canvasRect` (today's canvas, in page space) to hold `extents`.
    ///
    /// A side grows only when a shape's geometry crosses it, so shapes placed on the screenshot
    /// leave the canvas exactly as it was even where their stroke brushes the edge. The growth is
    /// the ink's overhang plus the margin, in whole pixels.
    static func make(
        canvasRect: CGRect,
        extents: [AnnotationInkExtent],
        contentSize: CGSize
    ) -> AnnotationCanvasGrowth {
        guard contentSize.width > 0, contentSize.height > 0, canvasRect.width > 0, canvasRect.height > 0 else {
            return .zero
        }
        let margin = min(contentSize.width, contentSize.height) * marginFraction
        // Float noise from moving a shape back to exactly the edge is not "sticking out".
        let tolerance: CGFloat = 0.5
        var growth = AnnotationCanvasGrowth()
        for extent in extents {
            let geometry = extent.geometry
            let ink = extent.ink.union(geometry)
            if geometry.minX < canvasRect.minX - tolerance {
                growth.left = max(growth.left, canvasRect.minX - ink.minX + margin)
            }
            if geometry.maxX > canvasRect.maxX + tolerance {
                growth.right = max(growth.right, ink.maxX - canvasRect.maxX + margin)
            }
            if geometry.minY < canvasRect.minY - tolerance {
                growth.top = max(growth.top, canvasRect.minY - ink.minY + margin)
            }
            if geometry.maxY > canvasRect.maxY + tolerance {
                growth.bottom = max(growth.bottom, ink.maxY - canvasRect.maxY + margin)
            }
        }
        guard !growth.isZero else { return .zero }

        func capped(_ leading: inout CGFloat, _ trailing: inout CGFloat, base: CGFloat) {
            let room = max(0, maximumCanvasDimension - base)
            let wanted = leading + trailing
            guard wanted > room, wanted > 0 else { return }
            leading *= room / wanted
            trailing *= room / wanted
        }
        capped(&growth.left, &growth.right, base: canvasRect.width)
        capped(&growth.top, &growth.bottom, base: canvasRect.height)

        // Whole pixels keep the screenshot on the pixel grid of the export.
        growth.top = growth.top.rounded(.up)
        growth.left = growth.left.rounded(.up)
        growth.bottom = growth.bottom.rounded(.up)
        growth.right = growth.right.rounded(.up)
        return growth
    }
}

// MARK: - Measuring shapes

extension AnnotationCanvasGrowth {
    /// The page-space extent of every shape that can grow the canvas.
    ///
    /// Blur, pixelate and the spotlight only mean something over the screenshot, so they never
    /// grow it. The document is built from the shapes alone, the same way the exporter builds it,
    /// so the editor and the export measure identical ink.
    nonisolated static func extents(of shapes: [AnnoShape]) -> [AnnotationInkExtent] {
        let candidates = shapes.filter { !$0.isRedaction && !$0.isHighlight }
        guard !candidates.isEmpty else { return [] }
        let document = AnnoDocument()
        document.restore(AnnoDocument.Snapshot(shapes: candidates, bindings: []))
        return candidates.compactMap { shape in
            guard let box = document.pageBounds(shape.id) else { return nil }
            let geometry = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
            let transform = shape.pageTransform.cgAffineTransform
            var ink = CGRect.null
            for element in document.renderElements(shape.id) {
                let local: CGRect
                switch element.content {
                case let .path(path), let .glyphs(path):
                    let bounds = path.boundingBoxOfPath
                    guard !bounds.isNull else { continue }
                    local = element.stroke == nil
                        ? bounds
                        : bounds.insetBy(dx: -element.strokeWidth / 2, dy: -element.strokeWidth / 2)
                case let .numbered(props):
                    local = CGRect(x: 0, y: 0, width: props.diameter, height: props.diameter)
                case .redaction, .spotlight:
                    continue
                }
                ink = ink.union(local.applying(transform))
            }
            return AnnotationInkExtent(geometry: geometry, ink: ink.isNull ? geometry : ink)
        }
    }
}

// MARK: - Edge colour

/// The colour that makes a screenshot look as if it simply carries on past its edge.
nonisolated enum AnnotationEdgeColor {
    /// Used when the edge is busy or see-through.
    static let fallback = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// How far (0...255, per channel) an edge pixel may stray from the edge's average and still
    /// count as the same colour.
    static let channelTolerance = 10
    /// The share of edge pixels that must agree for the edge to count as one colour.
    static let agreement = 0.95

    /// The outermost ring of pixels, if it is close to one opaque colour; white otherwise.
    ///
    /// The colour is returned in the image's own colour space when that can back an 8-bit
    /// context, so filling the export with it reproduces the edge's pixel values exactly.
    static func match(_ image: CGImage) -> CGColor {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return fallback }
        let space = workingSpace(for: image)

        // Four one-pixel strips, so a large screenshot never decodes into a second full bitmap.
        let strips = [
            CGRect(x: 0, y: 0, width: width, height: 1),
            CGRect(x: 0, y: height - 1, width: width, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: height),
            CGRect(x: width - 1, y: 0, width: 1, height: height),
        ]
        var pixels: [(r: Int, g: Int, b: Int, a: Int)] = []
        pixels.reserveCapacity(2 * (width + height))
        for strip in strips {
            guard let crop = image.cropping(to: strip),
                  let values = rgba(of: crop, space: space) else { return fallback }
            pixels.append(contentsOf: values)
        }
        guard !pixels.isEmpty else { return fallback }

        // A window capture's shadow (or any cut-out) leaves the edge transparent; there is no
        // colour to continue.
        let opaque = pixels.filter { $0.a >= 250 }
        guard Double(opaque.count) >= Double(pixels.count) * agreement else { return fallback }

        let count = Double(opaque.count)
        let mean = (
            r: Double(opaque.reduce(0) { $0 + $1.r }) / count,
            g: Double(opaque.reduce(0) { $0 + $1.g }) / count,
            b: Double(opaque.reduce(0) { $0 + $1.b }) / count
        )
        let tolerance = Double(channelTolerance)
        let agreeing = opaque.filter {
            abs(Double($0.r) - mean.r) <= tolerance
                && abs(Double($0.g) - mean.g) <= tolerance
                && abs(Double($0.b) - mean.b) <= tolerance
        }
        guard Double(agreeing.count) >= Double(pixels.count) * agreement else { return fallback }

        // The commonest value, not the average, so a flat edge comes back as exactly its own
        // pixels and the join is invisible.
        var tally: [Int: Int] = [:]
        for p in agreeing { tally[(p.r << 16) | (p.g << 8) | p.b, default: 0] += 1 }
        guard let mode = tally.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else {
            return fallback
        }
        let components: [CGFloat] = [
            CGFloat((mode >> 16) & 0xFF) / 255,
            CGFloat((mode >> 8) & 0xFF) / 255,
            CGFloat(mode & 0xFF) / 255,
            1,
        ]
        return CGColor(colorSpace: space, components: components) ?? fallback
    }

    private static func workingSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb,
           CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
           ) != nil {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Straight (un-premultiplied) 8-bit RGBA of every pixel in a thin strip.
    private static func rgba(of image: CGImage, space: CGColorSpace) -> [(r: Int, g: Int, b: Int, a: Int)]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var values: [(r: Int, g: Int, b: Int, a: Int)] = []
        values.reserveCapacity(width * height)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            func straight(_ v: UInt8) -> Int {
                a == 0 ? 0 : min(255, (Int(v) * 255 + a / 2) / a)
            }
            values.append((straight(bytes[i]), straight(bytes[i + 1]), straight(bytes[i + 2]), a))
        }
        return values
    }
}
