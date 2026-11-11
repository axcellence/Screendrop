import CoreGraphics
import Foundation

/// The highlighter's ink: a constant-width band along a smoothed freehand path, finished with a
/// scalloped cut at each end the way a felt tip leaves one.
///
/// Unlike the pen, the band never swells or thins with speed, and it is laid down as one shape, so
/// a stroke that doubles back over itself stays a single even tint. It is blended into what is
/// beneath it rather than painted over it (see `AnnoShapeDrawing`), which is what keeps text
/// readable under the colour.
enum MarkerInk {
    /// How strongly the colour tints the paper.
    static let opacity: CGFloat = 0.6

    /// The band's outline in the shape's local space.
    static func path(_ props: DrawProps, seed: String) -> CGPath {
        let width = Swift.max(1, props.strokeWidth)
        let points = centerline(props)

        guard points.count >= 2, length(of: points) >= 1 else {
            // A click without a drag: a single dab of the tip.
            let center = points.first ?? Vec(0, 0)
            return CGPath(
                ellipseIn: CGRect(x: center.x - width / 2, y: center.y - width / 2, width: width, height: width),
                transform: nil
            )
        }

        // Quadratics through the midpoints of consecutive points, the same smoothing the pen's
        // outline uses, then stroked as one piece: Core Graphics resolves tight turns and
        // self-crossings into a single outline, which a hand-built offset curve would not.
        let line = CGMutablePath()
        line.move(to: points[0].cgPoint)
        if points.count == 2 {
            line.addLine(to: points[1].cgPoint)
        } else {
            line.addLine(to: Vec.med(points[0], points[1]).cgPoint)
            for i in 1..<(points.count - 1) {
                line.addQuadCurve(to: Vec.med(points[i], points[i + 1]).cgPoint, control: points[i].cgPoint)
            }
            line.addLine(to: points[points.count - 1].cgPoint)
        }
        var band = line.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 1)

        let random = makeRng(seed)
        let first = points[0]
        let last = points[points.count - 1]
        // The start is cut as soon as the tip touches down; the far end only once it lifts, so the
        // leading edge stays plain while the stroke is still being dragged.
        band = band.union(
            scallopedCut(at: first, facing: direction(from: points, atStart: true), width: width, random),
            using: .winding
        )
        if props.isComplete {
            band = band.union(
                scallopedCut(at: last, facing: direction(from: points, atStart: false), width: width, random),
                using: .winding
            )
        }
        return band
    }

    /// The band as a polygon, for hit testing and the selection frame: the whole width of it, so
    /// it can be grabbed anywhere and its frame wraps what is drawn.
    static func outline(_ props: DrawProps) -> [Vec] {
        let half = Swift.max(1, props.strokeWidth) / 2
        let points = centerline(props)
        guard points.count >= 2, length(of: points) >= 1 else {
            let c = points.first ?? Vec(0, 0)
            return [Vec(c.x - half, c.y - half), Vec(c.x + half, c.y - half), Vec(c.x + half, c.y + half), Vec(c.x - half, c.y + half)]
        }

        var left: [Vec] = []
        var right: [Vec] = []
        left.reserveCapacity(points.count)
        right.reserveCapacity(points.count)
        for i in points.indices {
            let before = points[Swift.max(0, i - 1)]
            let after = points[Swift.min(points.count - 1, i + 1)]
            let along = Vec.sub(after, before)
            guard along.x != 0 || along.y != 0 else { continue }
            let direction = along.uni
            let normal = Vec(-direction.y * half, direction.x * half)
            left.append(Vec.add(points[i], normal))
            right.append(Vec.sub(points[i], normal))
        }
        return left + right.reversed()
    }

    // MARK: - Centerline

    /// The pointer's path, streamlined by the same pipeline the pen uses so the highlighter has
    /// the pen's smoothness, but with none of its width behaviour.
    private static func centerline(_ props: DrawProps) -> [Vec] {
        var options = StrokeOptions(
            // Only sets how close to its ends the pipeline drops jittery points; the band's real
            // width is applied when it is stroked.
            size: Swift.min(props.strokeWidth, 10),
            thinning: 0,
            smoothing: 0.62,
            streamline: 0.66,
            easing: Easings.linear,
            simulatePressure: false
        )
        options.last = props.isComplete
        return StrokeOutline.getStrokePoints(props.points, options).map { $0.point }
    }

    private static func length(of points: [Vec]) -> Double {
        var total = 0.0
        for i in 1..<points.count { total += Vec.dist(points[i - 1], points[i]) }
        return total
    }

    /// The outward direction at one end of the path, averaged over a short run so one jittery
    /// point does not tilt the whole cut.
    private static func direction(from points: [Vec], atStart: Bool) -> Vec {
        let end = atStart ? points[0] : points[points.count - 1]
        let reach = Swift.min(points.count - 1, 4)
        let inner = atStart ? points[reach] : points[points.count - 1 - reach]
        let away = Vec.sub(end, inner)
        if away.x == 0 && away.y == 0 { return Vec(atStart ? -1 : 1, 0) }
        return away.uni
    }

    // MARK: - Ends

    /// The sliver added beyond a square end to turn it into a marker's cut: a few shallow bumps
    /// across the width, dying away at the corners so they come out soft rather than sharp.
    private static func scallopedCut(
        at end: Vec, facing outward: Vec, width: Double, _ random: () -> Double
    ) -> CGPath {
        let across = Vec(-outward.y, outward.x)
        let depth = width * 0.07
        let waves = 2.6 + abs(random()) * 0.9
        let phase = random() * PI
        let ripplePhase = random() * PI
        // Tucked back under the band so the two join without a seam.
        let tuck = Swift.max(1, width * 0.04)

        func point(_ along: Double, _ offset: Double) -> CGPoint {
            CGPoint(
                x: end.x + outward.x * along + across.x * offset,
                y: end.y + outward.y * along + across.y * offset
            )
        }

        let steps = 28
        let path = CGMutablePath()
        path.move(to: point(-tuck, -width / 2))
        var previous = point(0, -width / 2)
        path.addLine(to: previous)
        for i in 1...steps {
            let s = Double(i) / Double(steps)
            let corner = Swift.min(1, Swift.min(s, 1 - s) / 0.14)
            let bumps = 1 + 0.62 * sin(PI2 * waves * s + phase) + 0.22 * sin(PI2 * waves * 2.1 * s + ripplePhase)
            let current = point(depth * bumps * corner.squareRoot(), -width / 2 + width * s)
            // Through the midpoints, so the bumps are rounded rather than faceted.
            path.addQuadCurve(
                to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2),
                control: previous
            )
            previous = current
        }
        path.addLine(to: point(0, width / 2))
        path.addLine(to: point(-tuck, width / 2))
        path.closeSubpath()
        return path
    }
}
