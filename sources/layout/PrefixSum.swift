import Foundation

/// Values with prefix sums kept in a Fenwick tree (design §4, block layout): reading a value, the
/// sum before an index, and the index whose span contains a running total all take O(log n), so
/// the canvas finds "which unit is at y" or "which unit holds character c" without walking the
/// document. Replacing a run of values rebuilds the tree in O(n), which is rare (an edit that
/// adds or removes units).
public struct PrefixSum<Value: AdditiveArithmetic & Comparable> {
    public private(set) var values: [Value]
    /// 1-based Fenwick tree over `values`.
    private var tree: [Value]

    public init(_ values: [Value] = []) {
        self.values = values
        tree = []
        rebuild()
    }

    public var count: Int { values.count }
    public subscript(i: Int) -> Value { values[i] }

    /// O(n): tree[i] covers the `lowbit(i)` values ending at i.
    private mutating func rebuild() {
        tree = [Value](repeating: .zero, count: values.count + 1)
        for i in 1...max(1, values.count) where i <= values.count {
            tree[i] += values[i - 1]
            let parent = i + (i & -i)
            if parent <= values.count { tree[parent] += tree[i] }
        }
    }

    public mutating func set(_ index: Int, _ value: Value) {
        let delta = value - values[index]
        guard delta != .zero else { return }
        values[index] = value
        var i = index + 1
        while i <= values.count {
            tree[i] += delta
            i += i & -i
        }
    }

    /// The sum of `values[0..<index]`.
    public func prefix(_ index: Int) -> Value {
        var sum = Value.zero
        var i = min(index, values.count)
        while i > 0 {
            sum += tree[i]
            i -= i & -i
        }
        return sum
    }

    public var total: Value { prefix(values.count) }

    /// The index whose span `[prefix(i), prefix(i + 1))` contains `target`; past the end, the last
    /// index (an empty last unit holds the end of the text). -1 when there are no values.
    public func index(containing target: Value) -> Int {
        guard !values.isEmpty else { return -1 }
        var pos = 0
        var remaining = target
        var step = 1
        while step * 2 <= values.count { step *= 2 }
        while step > 0 {
            let next = pos + step
            if next <= values.count, tree[next] <= remaining {
                pos = next
                remaining -= tree[next]
            }
            step /= 2
        }
        return min(pos, values.count - 1)
    }

    public mutating func replaceSubrange(_ range: Range<Int>, with new: [Value]) {
        if new.count == range.count {
            for (k, v) in new.enumerated() { set(range.lowerBound + k, v) }
            return
        }
        values.replaceSubrange(range, with: new)
        rebuild()
    }
}
