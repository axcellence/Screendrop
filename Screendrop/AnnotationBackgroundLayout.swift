//
//  AnnotationBackgroundLayout.swift
//  Screendrop
//

import CoreGraphics

nonisolated struct AnnotationBackgroundLayout {
    let canvasSize: CGSize
    let cardRect: CGRect
    let imageRect: CGRect
    let padding: CGFloat
    /// How far the canvas grew past its usual edges to hold annotations drawn outside it.
    var growth: AnnotationCanvasGrowth = .zero

    var isGrown: Bool { !growth.isZero }

    /// The canvas for `settings`, grown on any side an annotation in `annotationExtents` crosses.
    /// With nothing crossing an edge this is exactly the canvas without annotations.
    static func make(
        contentSize: CGSize,
        settings: AnnotationBackgroundSettings,
        annotationExtents: [AnnotationInkExtent]
    ) -> AnnotationBackgroundLayout {
        let base = make(contentSize: contentSize, settings: settings)
        guard !annotationExtents.isEmpty, base.canvasSize.width > 0, base.canvasSize.height > 0 else {
            return base
        }
        // Page space is the screenshot's pixels, laid 1:1 into the canvas at `imageRect`.
        let canvasInPage = CGRect(
            x: -base.imageRect.minX,
            y: -base.imageRect.minY,
            width: base.canvasSize.width,
            height: base.canvasSize.height
        )
        let growth = AnnotationCanvasGrowth.make(
            canvasRect: canvasInPage,
            extents: annotationExtents,
            contentSize: contentSize
        )
        guard !growth.isZero else { return base }

        var canvasSize = CGSize(
            width: base.canvasSize.width + growth.left + growth.right,
            height: base.canvasSize.height + growth.top + growth.bottom
        )
        var offset = CGPoint(x: growth.left, y: growth.top)
        // A fixed ratio is kept by adding room evenly around the grown canvas.
        if settings.usesCanvasLayout, let ratio = settings.aspectRatio.value {
            let expanded = expandedSize(canvasSize, aspectRatio: ratio)
            offset.x += (expanded.width - canvasSize.width) / 2
            offset.y += (expanded.height - canvasSize.height) / 2
            canvasSize = expanded
        }
        return AnnotationBackgroundLayout(
            canvasSize: canvasSize,
            cardRect: base.cardRect.offsetBy(dx: offset.x, dy: offset.y),
            imageRect: base.imageRect.offsetBy(dx: offset.x, dy: offset.y),
            padding: base.padding,
            growth: growth
        )
    }

    static func make(contentSize: CGSize, settings: AnnotationBackgroundSettings) -> AnnotationBackgroundLayout {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return AnnotationBackgroundLayout(
                canvasSize: .zero,
                cardRect: .zero,
                imageRect: .zero,
                padding: 0
            )
        }

        guard settings.requiresCanvasLayout else {
            let contentRect = CGRect(origin: .zero, size: contentSize)
            return AnnotationBackgroundLayout(
                canvasSize: contentSize,
                cardRect: contentRect,
                imageRect: contentRect,
                padding: 0
            )
        }

        let alignment = settings.effectiveCanvasAlignment
        let shortestEdge = min(contentSize.width, contentSize.height)
        let borderThickness = settings.border.pixelThickness(for: contentSize)
        let cardSize = CGSize(
            width: contentSize.width + borderThickness * 2,
            height: contentSize.height + borderThickness * 2
        )
        let normalizedPadding: CGFloat
        if settings.isEnabled {
            normalizedPadding = settings.padding
        } else if settings.usesCanvasLayout {
            normalizedPadding = max(settings.padding, 0.18)
        } else {
            // A border-only export should grow by exactly the outer ring, not
            // inherit the transparent breathing room used by camera effects.
            normalizedPadding = 0
        }
        let padding = max(0, shortestEdge * normalizedPadding)

        // Per-edge padding: stuck edges get zero padding
        let paddingTop: CGFloat = alignment.sticksToTop ? 0 : padding
        let paddingBottom: CGFloat = alignment.sticksToBottom ? 0 : padding
        let paddingLeading: CGFloat = alignment.sticksToLeading ? 0 : padding
        let paddingTrailing: CGFloat = alignment.sticksToTrailing ? 0 : padding

        let minimumSize = CGSize(
            width: cardSize.width + paddingLeading + paddingTrailing,
            height: cardSize.height + paddingTop + paddingBottom
        )
        let canvasSize = expandedSize(
            minimumSize,
            aspectRatio: settings.usesCanvasLayout ? settings.aspectRatio.value : nil
        )

        // Available rect accounts for per-edge padding
        let availableRect = CGRect(
            x: paddingLeading,
            y: paddingTop,
            width: canvasSize.width - paddingLeading - paddingTrailing,
            height: canvasSize.height - paddingTop - paddingBottom
        )
        let origin = CGPoint(
            x: availableRect.minX + max(0, availableRect.width - cardSize.width) * alignment.xFactor,
            y: availableRect.minY + max(0, availableRect.height - cardSize.height) * alignment.yFactor
        )
        let cardRect = CGRect(origin: origin, size: cardSize)
        let imageRect = cardRect.insetBy(dx: borderThickness, dy: borderThickness)

        return AnnotationBackgroundLayout(
            canvasSize: canvasSize,
            cardRect: cardRect,
            imageRect: imageRect,
            padding: padding
        )
    }

    func scaled(to frame: CGRect) -> AnnotationBackgroundDisplayLayout {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return AnnotationBackgroundDisplayLayout(
                canvasFrame: frame,
                cardFrame: .zero,
                imageFrame: .zero,
                scale: 1
            )
        }

        let scale = frame.width / canvasSize.width
        let cardFrame = CGRect(
            x: frame.minX + cardRect.minX * scale,
            y: frame.minY + cardRect.minY * scale,
            width: cardRect.width * scale,
            height: cardRect.height * scale
        )
        let imageFrame = CGRect(
            x: frame.minX + imageRect.minX * scale,
            y: frame.minY + imageRect.minY * scale,
            width: imageRect.width * scale,
            height: imageRect.height * scale
        )
        return AnnotationBackgroundDisplayLayout(
            canvasFrame: frame,
            cardFrame: cardFrame,
            imageFrame: imageFrame,
            scale: scale
        )
    }

    private static func expandedSize(_ size: CGSize, aspectRatio: CGFloat?) -> CGSize {
        guard let aspectRatio, aspectRatio > 0, size.width > 0, size.height > 0 else {
            return size
        }

        let currentRatio = size.width / size.height
        if currentRatio < aspectRatio {
            return CGSize(width: size.height * aspectRatio, height: size.height)
        }

        return CGSize(width: size.width, height: size.width / aspectRatio)
    }
}

struct AnnotationBackgroundDisplayLayout {
    let canvasFrame: CGRect
    let cardFrame: CGRect
    let imageFrame: CGRect
    let scale: CGFloat
}
