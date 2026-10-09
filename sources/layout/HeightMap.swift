import Foundation

/// Vertical extent of every layout unit (design §4: long-document height estimation and the
/// reading anchor). Units that were laid out carry their real height; the others carry an estimate
/// from their length, so the document has a height and a scroller from the first frame without
/// laying out text nobody looks at. When a measured height replaces an estimate above the
/// viewport, the canvas shifts the scroll position by `delta` and the text on screen stays put.
public struct HeightMap {
    private var heights = PrefixSum<Double>()
    public private(set) var measured: [Bool] = []

    public init(estimates: [Double] = []) {
        heights = PrefixSum(estimates)
        measured = [Bool](repeating: false, count: estimates.count)
    }

    public var count: Int { heights.count }
    public var total: Double { heights.total }
    public func height(of index: Int) -> Double { heights[index] }
    public func isMeasured(_ index: Int) -> Bool { measured[index] }

    /// Top of unit `index`.
    public func y(of index: Int) -> Double { heights.prefix(index) }

    /// The unit covering `y` (clamped to the first and last unit).
    public func unit(at y: Double) -> Int { max(0, heights.index(containing: max(0, y))) }

    /// Record a laid-out height; returns the change from what was there.
    @discardableResult
    public mutating func setMeasured(_ index: Int, _ height: Double) -> Double {
        let delta = height - heights[index]
        heights.set(index, height)
        measured[index] = true
        return delta
    }

    /// Units `old` were replaced by units with these estimates (an edit).
    public mutating func replace(_ old: Range<Int>, with estimates: [Double]) {
        heights.replaceSubrange(old, with: estimates)
        measured.replaceSubrange(old, with: [Bool](repeating: false, count: estimates.count))
    }

    /// Everything is estimated again (the width or the typography changed).
    public mutating func reset(_ estimates: [Double]) {
        self = HeightMap(estimates: estimates)
    }
}

/// A position in the document that survives height changes: a unit and a distance into it.
public struct LayoutAnchor: Equatable, Sendable {
    public var unit: Int
    public var offset: Double

    public init(unit: Int, offset: Double) {
        self.unit = unit
        self.offset = offset
    }

    public init(y: Double, in map: HeightMap) {
        unit = map.unit(at: y)
        offset = y - map.y(of: unit)
    }

    /// The y of this anchor in `map`, its offset kept inside the unit.
    public func y(in map: HeightMap) -> Double {
        guard map.count > 0 else { return 0 }
        let u = min(unit, map.count - 1)
        return map.y(of: u) + min(offset, map.height(of: u))
    }
}
