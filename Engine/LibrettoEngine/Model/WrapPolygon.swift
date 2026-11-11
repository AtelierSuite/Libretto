import Foundation

/// The outline text keeps to around a picture wrapped tight or through:
/// `wp:wrapPolygon`. Its points are fractions of the picture's width and
/// height, so it stays with the picture when it is resized; Word's own are in
/// 21600ths of the picture, and may lie a little outside it.
public struct WrapPolygon: Equatable, Hashable, Sendable {
    public struct Point: Equatable, Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public var points: [Point]
    /// Whether it was changed by hand in Word, rather than worked out from the picture.
    public var isEdited: Bool

    public init(points: [Point], isEdited: Bool = false) {
        self.points = points
        self.isEdited = isEdited
    }

    /// The picture's frame, which text keeps clear of when there is no polygon.
    public static let frame = WrapPolygon(points: [
        Point(x: 0, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 1, y: 0), Point(x: 0, y: 0),
    ])

    /// Word's units: the whole picture is 21600 across and down.
    public static let unitsPerPicture: Double = 21_600

    /// A band of the page, across which text keeps clear of the picture.
    public struct Band: Equatable, Sendable {
        public var minX, minY, maxX, maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }
    }

    /// What text keeps clear of around a picture set in a frame, worked out
    /// band by band down the picture from where the polygon crosses each
    /// band, so every line keeps clear only of the part of the outline beside it.
    ///
    /// Wrapped tight, text keeps clear of the whole polygon across each band;
    /// wrapped through, it may also fill the open parts inside it, between
    /// where the polygon's edges cross the band. Either way it keeps `left`
    /// and `right` from the outline.
    public func exclusions(
        x: Double, y: Double, width: Double, height: Double,
        left: Double, right: Double, through: Bool, step: Double = 2
    ) -> [Band] {
        let placed = points.map { (x: x + $0.x * width, y: y + $0.y * height) }
        guard placed.count >= 3 else { return [] }
        var edges: [(a: (x: Double, y: Double), b: (x: Double, y: Double))] = []
        for index in placed.indices {
            let next = placed[(index + 1) % placed.count]
            if placed[index] != next { edges.append((placed[index], next)) }
        }
        guard let top = placed.map(\.y).min(), let bottom = placed.map(\.y).max(), bottom > top else { return [] }

        var result: [Band] = []
        var bandTop = top
        while bandTop < bottom - 0.001 {
            let bandBottom = min(bottom, bandTop + max(step, 0.25))
            let spans = through
                ? Self.openSpans(of: edges, from: bandTop, to: bandBottom)
                : Self.extent(of: edges, from: bandTop, to: bandBottom).map { [$0] } ?? []
            for span in spans {
                let band = Band(minX: span.lowerBound - left, minY: bandTop, maxX: span.upperBound + right, maxY: bandBottom)
                // A band like the one just above it, which it touches, is the same band made taller.
                if let same = result.lastIndex(where: {
                    abs($0.maxY - bandTop) < 0.001 && abs($0.minX - band.minX) < 0.01 && abs($0.maxX - band.maxX) < 0.01
                }) {
                    result[same].maxY = bandBottom
                } else {
                    result.append(band)
                }
            }
            bandTop = bandBottom
        }
        return result
    }

    /// From the leftmost to the rightmost point of the outline between two heights.
    private static func extent(
        of edges: [(a: (x: Double, y: Double), b: (x: Double, y: Double))], from top: Double, to bottom: Double
    ) -> ClosedRange<Double>? {
        var low = Double.infinity
        var high = -Double.infinity
        for (a, b) in edges {
            let lower = min(a.y, b.y), upper = max(a.y, b.y)
            guard upper >= top, lower <= bottom else { continue }
            if a.y == b.y {
                low = min(low, a.x, b.x)
                high = max(high, a.x, b.x)
                continue
            }
            // The part of the edge between the two heights.
            for height in [max(lower, top), min(upper, bottom)] {
                let x = a.x + (b.x - a.x) * (height - a.y) / (b.y - a.y)
                low = min(low, x)
                high = max(high, x)
            }
        }
        return low <= high ? low...high : nil
    }

    /// Where the outline is filled across the band, leaving out the open parts
    /// between its edges: taken at the band's top, middle and foot, and joined.
    private static func openSpans(
        of edges: [(a: (x: Double, y: Double), b: (x: Double, y: Double))], from top: Double, to bottom: Double
    ) -> [ClosedRange<Double>] {
        let inset = min(0.01, (bottom - top) / 4)
        var spans: [ClosedRange<Double>] = []
        for height in [top + inset, (top + bottom) / 2, bottom - inset] {
            var crossings: [Double] = []
            for (a, b) in edges where (a.y <= height) != (b.y <= height) {
                crossings.append(a.x + (b.x - a.x) * (height - a.y) / (b.y - a.y))
            }
            crossings.sort()
            var index = 0
            while index + 1 < crossings.count {
                spans.append(crossings[index]...crossings[index + 1])
                index += 2
            }
        }
        spans.sort { $0.lowerBound < $1.lowerBound }
        var joined: [ClosedRange<Double>] = []
        for span in spans {
            if let last = joined.last, span.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                joined.append(span)
            }
        }
        return joined
    }
}
