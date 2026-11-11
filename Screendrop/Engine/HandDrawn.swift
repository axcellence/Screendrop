import CoreGraphics
import Foundation

/// The hand-drawn style for rectangles, ellipses, lines and arrows.
///
/// Each shape is traced the way a hand would draw it - a slightly unsteady path that bows, drifts
/// and overshoots where it closes - and that path is inked by the same freehand pipeline the pen
/// tool uses, so a drawn rectangle and a freehand stroke are visibly the same pen: one brush stroke
/// with thick and thin parts, rather than a constant-width outline.
///
/// Everything is seeded by the shape's id, so a shape keeps its own wobble when it is moved,
/// reopened or exported, and no two shapes share one.
enum HandDrawn {
    /// A rectangle or ellipse outline as brush ink, in the shape's local space. `nil` when the
    /// shape is too small to trace, where the clean outline reads better.
    static func geoInk(_ props: GeoProps, seed: String) -> CGPath? {
        let w = props.w
        let h = props.h
        let sw = props.strokeWidth
        guard w >= sw, h >= sw, w >= 4, h >= 4 else { return nil }

        let random = makeRng(seed)
        switch props.geo {
        case .rectangle:
            let points = rectanglePoints(w: w, h: h, strokeWidth: sw, cornerRadius: props.cornerRadius, random)
            return ink(points, strokeWidth: sw, streamline: 0.25, taperEnd: sw * 4)
        case .ellipse:
            let (points, perimeter) = ellipsePoints(w: w, h: h, strokeWidth: sw, random)
            return ink(points, strokeWidth: sw, streamline: 0, taperEnd: perimeter * 0.11)
        }
    }

    /// An arrow's body as brush ink: heavier at the tail, with a slight bow, and pinned to the
    /// arrow's real ends so the head and any bound shape still line up.
    static func arrowBodyInk(_ info: ArrowInfo, strokeWidth sw: Double, hasHead: Bool, seed: String) -> CGPath? {
        let random = makeRng(seed)
        let centerline: (Double) -> (point: Vec, normal: Vec)
        let length: Double

        switch info.body {
        case let .straight(start, end):
            length = Vec.dist(start, end)
            guard length > 0.5 else { return nil }
            let direction = Vec.sub(end, start).uni
            let normal = Vec(-direction.y, direction.x)
            centerline = { t in (Vec.lrp(start, end, t), normal) }

        case let .arc(arc):
            let start = info.start.point
            let end = info.end.point
            guard arc.radius.isFinite, arc.radius > 0 else { return nil }
            let a0 = atan2(start.y - arc.center.y, start.x - arc.center.x)
            let a1 = atan2(end.y - arc.center.y, end.x - arc.center.x)
            // The sweep flag says which way round the circle the body runs from start to end.
            var delta = a1 - a0
            if arc.sweepFlag != 0 {
                while delta <= 0 { delta += PI2 }
            } else {
                while delta >= 0 { delta -= PI2 }
            }
            length = abs(delta) * arc.radius
            guard length > 0.5 else { return nil }
            centerline = { t in
                let angle = a0 + delta * t
                let radial = Vec(cos(angle), sin(angle))
                return (Vec(arc.center.x + radial.x * arc.radius, arc.center.y + radial.y * arc.radius), radial)
            }
        }

        // A long bow plus a smaller S-bend, both zero at the ends.
        let bow = random() * Swift.min(sw * 1.6, length * 0.022)
        let sway = random() * Swift.min(sw * 0.4, length * 0.006)
        let phase = random() * PI

        let count = Swift.max(8, Int(length / Swift.max(4, sw * 0.9)))
        var points: [Vec] = []
        points.reserveCapacity(count + 1)
        for i in 0...count {
            let t = Double(i) / Double(count)
            let (point, normal) = centerline(t)
            let offset = bow * sin(PI * t) + sway * sin(PI2 * t)
            // Pressed in at the tail, lifting towards the head.
            let pressure = 0.68 - 0.22 * t + 0.05 * sin(PI2 * 1.7 * t + phase)
            points.append(Vec(point.x + normal.x * offset, point.y + normal.y * offset, pressure))
        }
        // A bare line lifts off at its far end; an arrow's body runs under its head instead.
        return ink(points, strokeWidth: sw, streamline: 0, taperEnd: hasHead ? nil : Swift.min(length * 0.12, sw * 3))
    }

    /// The open arrowhead as two quick flicks away from the tip, each thinning out as it lifts.
    ///
    /// `back` is a point behind the tip along the body, which gives the head its direction;
    /// `bodyLength` sets its size. A drawn head is larger than the clean one, as a hand makes it.
    static func arrowheadInk(
        tip: Vec, back: Vec, bodyLength: Double, strokeWidth sw: Double, seed: String
    ) -> CGPath? {
        guard Vec.dist(tip, back) > 0.5 else { return nil }
        let baseLength = clamp(bodyLength * 0.2, sw * 2.5, sw * 6)
        let random = makeRng(seed + "head")
        let path = CGMutablePath()

        for side in [1.0, -1.0] {
            let angle = side * (PI / 6.4 + random() * 0.06)
            let length = baseLength * (1 + random() * 0.1)
            let end = Vec.rotWith(Vec.nudge(tip, back, length), tip, angle)
            let direction = Vec.sub(end, tip).uni
            let normal = Vec(-direction.y, direction.x)
            // Each barb curls slightly outwards, away from the body.
            let curl = side * length * (0.02 + abs(random()) * 0.025)

            let count = Swift.max(6, Int(length / Swift.max(3, sw * 0.6)))
            var points: [Vec] = []
            points.reserveCapacity(count + 1)
            for i in 0...count {
                let t = Double(i) / Double(count)
                let point = Vec.lrp(tip, end, t)
                let offset = curl * sin(PI * t)
                points.append(Vec(point.x + normal.x * offset, point.y + normal.y * offset, 0.6 - 0.12 * t))
            }
            path.addPath(ink(points, strokeWidth: sw, streamline: 0, taperEnd: length * 0.22))
        }
        return path
    }

    // MARK: - Ink

    /// Ink a traced centerline with the freehand pipeline. Points carry their pressure in `z`.
    private static func ink(
        _ points: [Vec],
        strokeWidth: Double,
        streamline: Double,
        taperEnd: Double? = nil
    ) -> CGPath {
        var options = StrokeOptions(
            size: strokeWidth,
            thinning: 0.55,
            smoothing: 0.62,
            streamline: streamline,
            easing: Easings.linear,
            simulatePressure: false
        )
        options.end = StrokeOptions.End(cap: true, taper: taperEnd, easing: nil)
        options.last = true
        return SvgInk.render(points, options).path
    }

    // MARK: - Tracing

    /// A rectangle traced in one go: starting partway along a side, round each softened corner,
    /// and on past the start so the stroke overlaps itself rather than ending on a corner.
    private static func rectanglePoints(
        w: Double, h: Double, strokeWidth sw: Double, cornerRadius: Double, _ random: () -> Double
    ) -> [Vec] {
        let shortSide = Swift.min(w, h)
        // The corners sit a little off true, which is most of what makes it read as drawn.
        let jitter = Swift.min(sw * 0.4, shortSide * 0.035)
        let corners = [Vec(0, 0), Vec(w, 0), Vec(w, h), Vec(0, h)].map {
            Vec($0.x + random() * jitter, $0.y + random() * jitter)
        }
        let radius = Swift.min(shortSide / 3, Swift.max(cornerRadius, sw * 1.5))
        let spacing = Swift.max(4, sw * 0.9)

        let startSide = Int(abs(random()) * 4) % 4
        let startAt = 0.12 + abs(random()) * 0.2
        let overlap = 0.1 + abs(random()) * 0.14
        // The closing overlap rides just off the opening stroke, as a second pass would.
        let closingShift = random() * sw * 0.15

        var points: [Vec] = []

        /// One side from fraction `from` to `to` of its straight run, bowed slightly.
        func addSide(_ side: Int, from: Double, to: Double, shift: Double = 0) {
            let a = corners[side % 4]
            let b = corners[(side + 1) % 4]
            let length = Vec.dist(a, b)
            guard length > 0 else { return }
            let direction = Vec.sub(b, a).uni
            let normal = Vec(-direction.y, direction.x)
            let runStart = Vec.add(a, Vec.mul(direction, radius))
            let runEnd = Vec.sub(b, Vec.mul(direction, radius))
            let bow = random() * Swift.min(sw * 0.45, length * 0.012)
            let count = Swift.max(2, Int(length * abs(to - from) / spacing))
            for i in 0...count {
                let t = from + (to - from) * Double(i) / Double(count)
                let point = Vec.lrp(runStart, runEnd, t)
                let offset = bow * sin(PI * t) + shift
                points.append(Vec(point.x + normal.x * offset, point.y + normal.y * offset))
            }
        }

        /// The corner between `side` and the next one, as a quadratic round its true corner.
        func addCorner(after side: Int) {
            let a = corners[side % 4]
            let corner = corners[(side + 1) % 4]
            let c = corners[(side + 2) % 4]
            let from = Vec.add(corner, Vec.mul(Vec.sub(a, corner).uni, radius))
            let to = Vec.add(corner, Vec.mul(Vec.sub(c, corner).uni, radius))
            for t in [0.25, 0.5, 0.75] {
                let u = 1 - t
                points.append(Vec(
                    u * u * from.x + 2 * u * t * corner.x + t * t * to.x,
                    u * u * from.y + 2 * u * t * corner.y + t * t * to.y
                ))
            }
        }

        addSide(startSide, from: startAt, to: 1)
        addCorner(after: startSide)
        for step in 1...3 {
            addSide(startSide + step, from: 0, to: 1)
            addCorner(after: startSide + step)
        }
        addSide(startSide, from: 0, to: startAt + overlap, shift: closingShift)

        return pressured(points, random)
    }

    /// An ellipse traced the way most hands circle something: anticlockwise from the upper left,
    /// once round and on past the start, with the tail pulling inside the first pass and lifting
    /// off rather than meeting it.
    private static func ellipsePoints(
        w: Double, h: Double, strokeWidth sw: Double, _ random: () -> Double
    ) -> (points: [Vec], perimeter: Double) {
        let cx = w / 2
        let cy = h / 2
        let shortRadius = Swift.min(cx, cy)
        let jitter = Swift.min(sw * 0.3, shortRadius * 0.03)
        let rx = cx + random() * jitter
        let ry = cy + random() * jitter
        // Ramanujan's approximation.
        let perimeter = PI * (3 * (rx + ry) - ((3 * rx + ry) * (rx + 3 * ry)).squareRoot())

        // Page space is y-down, so a falling angle runs anticlockwise on screen. Start somewhere
        // between the left and the top.
        let start = PI * (1.05 + abs(random()) * 0.35)
        let turns = 1.12 + abs(random()) * 0.14
        // How far inside the first pass the tail ends up, as a fraction of the radius: enough to
        // leave a sliver of daylight between the two, without eating a small ellipse.
        let pull = clamp((sw * 2.1) / Swift.max(shortRadius, 1), 0.03, 0.2)
        let pullFrom = 0.86
        let wobblePhase = random() * PI
        let pressurePhase = random() * PI

        let count = Swift.max(28, Int(perimeter * turns / Swift.max(4, sw * 0.8)))
        var points: [Vec] = []
        points.reserveCapacity(count + 1)
        for i in 0...count {
            let t = Double(i) / Double(count)
            let turned = turns * t
            let angle = start - PI2 * turned
            let closing = Swift.max(0, (turned - pullFrom) / (turns - pullFrom))
            let scale = 1 - pull * closing * closing.squareRoot() + 0.006 * sin(PI2 * 2.3 * t + wobblePhase)
            let pressure = 0.68 - 0.2 * t + 0.05 * sin(PI2 * 1.9 * t + pressurePhase)
            points.append(Vec(cx + rx * scale * cos(angle), cy + ry * scale * sin(angle), pressure))
        }
        return (points, perimeter)
    }

    /// Give a traced path a slowly varying pressure, so the stroke swells and thins along its
    /// length the way a pen does.
    private static func pressured(_ points: [Vec], _ random: () -> Double) -> [Vec] {
        guard points.count > 1 else { return points }
        let phase1 = random() * PI
        let phase2 = random() * PI
        let last = Double(points.count - 1)
        return points.enumerated().map { index, point in
            let t = Double(index) / last
            let pressure = 0.5 + 0.15 * sin(PI2 * 1.3 * t + phase1) + 0.07 * sin(PI2 * 3.1 * t + phase2)
            return Vec(point.x, point.y, clamp(pressure, 0.25, 0.8))
        }
    }
}
