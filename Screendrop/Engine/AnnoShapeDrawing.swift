import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Draws a document's shapes into a `CGContext`.
///
/// The canvas and the exporter both come through here, differing only in the transform they pass
/// and the resolution of the screenshot they hand over - which is what makes the preview a true
/// reduction of the export rather than a second implementation that happens to agree.
///
/// Four passes, in this order:
///  1. Highlighter strokes, which tint the screenshot itself and so sit on the paper.
///  2. Redactions, which transform screenshot pixels and so must sit under everything else.
///  3. The spotlight: one dimming layer over the image with a hole punched per highlight shape.
///  4. Every other shape, in z-order.
enum AnnoShapeDrawing {
    /// Everything a draw needs to know about where the page sits and what it is drawn over.
    struct Target {
        /// Page space -> context space.
        var transform: CGAffineTransform
        /// The image's extent in page units.
        var pageSize: CGSize
        /// The pixels currently under a context-space rect, for redactions to process.
        ///
        /// A closure rather than an image because the two callers sample different things: the
        /// canvas hands back a crop of the screenshot, while the exporter snapshots the composed
        /// context so a blur picks up the background behind a transparent screenshot too.
        var sample: ((CGRect) -> CGImage?)?
        /// Clip applied to the spotlight layer, so it follows a rounded screenshot frame.
        var spotlightClip: CGPath?
        /// True for the canvas, whose `NSView` is flipped, false for the export bitmap. Core
        /// Graphics lays an image into the rect it is given the same way up either way, so the
        /// flipped case has to invert it back.
        var isFlippedContext = false
        var redactionPreviewCache: AnnoRedactionPreviewCache? = nil
        /// The screenshot itself, covering exactly the page, when the context being drawn into
        /// does not already contain it. The canvas's annotation layer is transparent and floats
        /// above the screenshot, so ink that blends with what is beneath it has to bring those
        /// pixels along; the exporter draws straight onto the composed image and passes `nil`.
        var backdrop: CGImage? = nil

        var pageRect: CGRect { CGRect(origin: .zero, size: pageSize) }
    }

    nonisolated(unsafe) private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    nonisolated static func clearCaches() { ciContext.clearCaches() }

    static func draw(
        _ document: AnnoDocument,
        in context: CGContext,
        target: Target,
        skipping skipped: Set<AnnoShapeID> = []
    ) {
        let shapes = document.shapes.filter { !skipped.contains($0.id) }

        // Before the redactions, so a blur laid over a highlight still hides what is under it.
        for shape in shapes where shape.isMarker {
            drawMarker(shape, document: document, in: context, target: target)
        }

        for shape in shapes where shape.isRedaction {
            drawRedaction(shape, document: document, in: context, target: target)
        }

        drawSpotlight(shapes.filter { $0.isHighlight }, in: context, target: target)

        for shape in shapes where !shape.isRedaction && !shape.isHighlight && !shape.isMarker {
            drawShape(shape, document: document, in: context, target: target)
        }
    }

    // MARK: - Highlighter

    /// Highlighter ink tints what is beneath it without covering it. On a light screenshot it is
    /// multiplied, so paper takes the colour and text stays as dark as it was. A multiply can only
    /// darken, which would leave no mark at all on a dark screenshot, so there it is screened
    /// instead: the dark paper takes the colour and light text stays light.
    ///
    /// The exporter's context already holds the screenshot, so the blend applies directly. The
    /// canvas's layer is transparent with the screenshot in a separate view underneath, where a
    /// blend would have nothing to work on - so the screenshot's own pixels are drawn into the
    /// stroke first, and the two layers composite to the same picture the export produces.
    private static func drawMarker(
        _ shape: AnnoShape,
        document: AnnoDocument,
        in context: CGContext,
        target: Target
    ) {
        var toContext = shape.pageTransform.cgAffineTransform.concatenating(target.transform)

        for element in document.renderElements(shape.id) {
            guard case let .path(localPath) = element.content, let fill = element.fill,
                  let path = localPath.copy(using: &toContext) else { continue }
            let bounds = path.boundingBoxOfPath
            let backdrop = target.backdrop.flatMap { backdropCrop($0, under: bounds, target: target) }

            // What the stroke is going over: the screenshot on the canvas, the composed image in
            // an export.
            let beneath = backdrop?.image ?? target.sample?(bounds.integral)
            let isOnDark = beneath.flatMap(meanLuminance).map { $0 < darkBackdropLuminance } ?? false

            context.saveGState()
            if let backdrop {
                context.saveGState()
                context.addPath(path)
                context.clip()
                context.interpolationQuality = .high
                if target.isFlippedContext {
                    context.translateBy(x: 0, y: backdrop.destination.midY)
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: 0, y: -backdrop.destination.midY)
                }
                context.draw(backdrop.image, in: backdrop.destination)
                context.restoreGState()
            }
            context.setBlendMode(isOnDark ? .screen : .multiply)
            // Screening adds light, which reads stronger than the same tint multiplied in.
            context.setAlpha(shape.opacity * (isOnDark ? 0.7 : 1))
            context.addPath(path)
            context.setFillColor(fill.cgColor)
            context.fillPath(using: .winding)
            context.restoreGState()
        }
    }

    /// Below this average brightness the area under a highlight counts as a dark screenshot. Dark
    /// text on white paper sits well above it however dense the text is.
    private static let darkBackdropLuminance = 0.4

    /// The part of the screenshot that lies under a context-space rect, and exactly where the
    /// screenshot view shows it. The crop is taken on whole source pixels and placed back on those
    /// same pixels, so text under a highlight lines up with the text around it.
    private static func backdropCrop(
        _ backdrop: CGImage,
        under contextRect: CGRect,
        target: Target
    ) -> (image: CGImage, destination: CGRect)? {
        guard target.pageSize.width > 0, target.pageSize.height > 0 else { return nil }
        let pageRect = contextRect.applying(target.transform.inverted())
        // The preview image can be a downscaled copy of the page.
        let sx = CGFloat(backdrop.width) / target.pageSize.width
        let sy = CGFloat(backdrop.height) / target.pageSize.height
        let pixels = CGRect(
            x: pageRect.minX * sx, y: pageRect.minY * sy,
            width: pageRect.width * sx, height: pageRect.height * sy
        )
        .insetBy(dx: -1, dy: -1)
        .integral
        .intersection(CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height))
        guard pixels.width >= 1, pixels.height >= 1, let crop = backdrop.cropping(to: pixels) else { return nil }

        let destination = CGRect(
            x: pixels.minX / sx, y: pixels.minY / sy,
            width: pixels.width / sx, height: pixels.height / sy
        ).applying(target.transform)
        return (crop, destination)
    }

    /// Average brightness of an image, 0...1, ignoring anything transparent. `nil` when there is
    /// nothing opaque to measure.
    private static func meanLuminance(of image: CGImage) -> Double? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var light = 0.0
        var coverage = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            // Premultiplied, so summing the channels already weights each pixel by its alpha.
            light += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
            coverage += Double(pixels[i + 3])
        }
        guard coverage > 0.05 * 255 * Double(side * side) else { return nil }
        return light / coverage
    }

    // MARK: - One shape

    static func drawShape(
        _ shape: AnnoShape,
        document: AnnoDocument,
        in context: CGContext,
        target: Target
    ) {
        let elements = document.renderElements(shape.id)
        guard !elements.isEmpty else { return }

        context.saveGState()
        context.concatenate(shape.pageTransform.cgAffineTransform.concatenating(target.transform))
        if shape.opacity < 1 { context.setAlpha(shape.opacity) }

        for element in elements {
            switch element.content {
            case let .path(path), let .glyphs(path):
                if let fill = element.fill {
                    context.addPath(path)
                    context.setFillColor(fill.cgColor)
                    context.fillPath(using: element.usesEvenOddFill ? .evenOdd : .winding)
                }
                if let stroke = element.stroke {
                    context.addPath(path)
                    context.setStrokeColor(stroke.cgColor)
                    context.setLineWidth(element.strokeWidth)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    if element.dashes.isEmpty {
                        context.setLineDash(phase: 0, lengths: [])
                    } else {
                        context.setLineDash(phase: element.dashPhase, lengths: element.dashes)
                    }
                    context.strokePath()
                    context.setLineDash(phase: 0, lengths: [])
                }
            case let .numbered(props):
                drawNumbered(props, in: context)
            case .redaction, .spotlight:
                // Handled by their own passes, which need the screenshot underneath.
                break
            }
        }
        context.restoreGState()
    }

    // MARK: - Numbered callout

    private static func drawNumbered(_ props: NumberedProps, in context: CGContext) {
        let rect = CGRect(x: 0, y: 0, width: props.diameter, height: props.diameter)
        let outlineWidth = Swift.max(1, props.diameter * 0.055)

        context.setFillColor(props.swatch.nsColor.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(props.swatch.numberedCircleOutlineNSColor.cgColor)
        context.setLineWidth(outlineWidth)
        context.strokeEllipse(in: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))

        // The digits go through the same glyph-outline path text uses, so a rotated callout's
        // number rotates with it and needs no flipped graphics context.
        let text = String(props.value)
        var textProps = TextProps()
        textProps.text = text
        textProps.swatch = props.swatch
        textProps.fontSize = props.diameter * numberedFontScale(digits: text.count)
        textProps.fontFamily = .pro
        textProps.isBold = true
        textProps.align = .start

        let path = TextMeasure.glyphPath(textProps)
        let glyphBounds = path.boundingBoxOfPath
        var transform = CGAffineTransform(
            // Centre the visible outlines rather than their TextKit line box. The line box carries
            // asymmetric ascent/descent padding, which makes digits appear slightly low.
            translationX: props.diameter / 2 - glyphBounds.midX,
            y: props.diameter / 2 - glyphBounds.midY
        )
        guard let positioned = path.copy(using: &transform) else { return }
        context.addPath(positioned)
        context.setFillColor(props.swatch.numberedCircleTextNSColor.cgColor)
        context.fillPath(using: .winding)
    }

    private static func numberedFontScale(digits: Int) -> Double {
        if digits <= 2 { return 0.54 }
        if digits == 3 { return 0.44 }
        return 0.34
    }

    // MARK: - Spotlight

    private static func drawSpotlight(_ shapes: [AnnoShape], in context: CGContext, target: Target) {
        guard !shapes.isEmpty else { return }

        context.saveGState()
        if let clip = target.spotlightClip {
            context.addPath(clip)
            context.clip()
        } else {
            context.clip(to: target.pageRect.applying(target.transform))
        }

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setBlendMode(.normal)
        context.setFillColor(
            NSColor.black.withAlphaComponent(AnnotationHighlightMetrics.overlayOpacity).cgColor
        )
        context.fill(target.pageRect.applying(target.transform))

        context.saveGState()
        context.setBlendMode(.clear)
        for shape in shapes {
            guard case let .highlight(props) = shape.kind else { continue }
            var transform = shape.pageTransform.cgAffineTransform.concatenating(target.transform)
            // Built with the transform baked in, so a rotated highlight punches a rotated hole.
            context.addPath(CGPath(
                rect: CGRect(x: 0, y: 0, width: props.w, height: props.h),
                transform: &transform
            ))
            context.fillPath()
        }
        context.restoreGState()

        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Redaction

    private static func drawRedaction(
        _ shape: AnnoShape,
        document: AnnoDocument,
        in context: CGContext,
        target: Target
    ) {
        guard case let .redaction(props) = shape.kind, let sample = target.sample else { return }

        // Sample the axis-aligned bounding box in context space, process it upright, then lay it
        // back down clipped to the shape's own rotated rect. A rotated blur then blurs the pixels
        // it actually covers rather than smearing along the screen axes.
        let localRect = CGRect(x: 0, y: 0, width: props.w, height: props.h)
        let full = shape.pageTransform.cgAffineTransform.concatenating(target.transform)
        let contextBounds = localRect.applying(full).integral
        guard contextBounds.width >= 1, contextBounds.height >= 1 else { return }

        let render = {
            guard let sampled = sample(contextBounds) else { return nil as CGImage? }
            return autoreleasepool {
                switch props.kind {
                case .blur: blurred(sampled, density: props.density)
                case .pixelate: pixelated(sampled, density: props.density)
                }
            }
        }
        let processed: CGImage?
        if let cache = target.redactionPreviewCache {
            processed = cache.image(kind: props.kind.rawValue, density: props.density, bounds: contextBounds, render: render)
        } else {
            processed = render()
        }
        guard let processed else { return }

        context.saveGState()
        context.concatenate(full)
        context.clip(to: localRect)
        // Back to context space, where the sampled rect is axis-aligned.
        context.concatenate(full.inverted())
        context.interpolationQuality = props.kind == .pixelate ? .none : .high
        if target.isFlippedContext {
            context.translateBy(x: 0, y: contextBounds.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -contextBounds.midY)
        }
        context.draw(processed, in: contextBounds)
        context.restoreGState()
    }

    private static func blurred(_ image: CGImage, density: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(RedactionImageProcessor.blurRadius(for: CGFloat(density)))
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private static func pixelated(_ image: CGImage, density: Double) -> CGImage? {
        let block = RedactionImageProcessor.pixelBlockSize(for: CGFloat(density))
        let lowWidth = Swift.max(1, Int(CGFloat(image.width) / block))
        let lowHeight = Swift.max(1, Int(CGFloat(image.height) / block))
        guard let low = CGContext(
            data: nil,
            width: lowWidth,
            height: lowHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        low.interpolationQuality = .medium
        low.draw(image, in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight))
        return low.makeImage()
    }
}
