import CoreGraphics
import Foundation

/// Where pictures brought into the editor land: beside what is already there, never on top of it.
nonisolated enum AnnoImagePlacement {
    /// Page-space frames for pictures of `sizes`, placed one after another beside `screenshot` and
    /// the `existing` pictures' frames.
    ///
    /// Each goes to the right of everything (top-aligned) or below it (left-aligned), whichever
    /// keeps the whole closer to square, with the canvas-growth margin as the gap. A picture keeps
    /// its own pixel size unless that would push the canvas past its size cap.
    static func frames(for sizes: [CGSize], screenshot: CGRect, existing: [CGRect]) -> [CGRect] {
        guard screenshot.width > 0, screenshot.height > 0 else { return [] }
        let gap = (min(screenshot.width, screenshot.height) * AnnotationCanvasGrowth.marginFraction).rounded(.up)
        // The grown canvas adds a margin past the outermost ink on each side.
        let cap = AnnotationCanvasGrowth.maximumCanvasDimension - 2 * gap
        var content = existing.reduce(screenshot) { $0.union($1) }
        var frames: [CGRect] = []

        for size in sizes where size.width > 0 && size.height > 0 {
            func fitted(_ origin: CGPoint, room: CGSize) -> CGRect {
                let scale = min(1, max(0.05, min(room.width / size.width, room.height / size.height)))
                return CGRect(
                    x: origin.x, y: origin.y,
                    width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded())
                )
            }
            let right = fitted(
                CGPoint(x: content.maxX + gap, y: content.minY),
                room: CGSize(width: cap - content.width - gap, height: cap)
            )
            let below = fitted(
                CGPoint(x: content.minX, y: content.maxY + gap),
                room: CGSize(width: cap, height: cap - content.height - gap)
            )
            func squareness(_ frame: CGRect) -> CGFloat {
                let whole = content.union(frame)
                return abs(log(whole.width / whole.height))
            }
            let frame = squareness(below) < squareness(right) ? below : right
            frames.append(frame)
            content = content.union(frame)
        }
        return frames
    }
}
