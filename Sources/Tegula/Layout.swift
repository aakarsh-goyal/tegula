import Foundation
import CoreGraphics

/// Pure layout maths. Everything here works in "AX" coordinates (origin top-left, y down),
/// so the rects it produces can be handed straight to the Accessibility API.
enum LayoutKind: String, CaseIterable, Codable {
    case grid, columns, rows, side
}

enum Axis { case horizontal, vertical }   // horizontal = children sit side by side

indirect enum Node {
    case leaf(Int)
    case split(Axis, [Double], [Node])
}

enum LayoutEngine {
    static func capacity(ultrawide: Bool) -> Int { ultrawide ? 5 : 4 }

    /// Builds the split tree for `n` tiles. Tile 0 is the "main" tile.
    static func tree(kind: LayoutKind, count: Int, ratio r: Double, ultrawide: Bool, vertical: Bool) -> Node {
        let n = max(1, count)
        if n == 1 { return .leaf(0) }
        let rest = 1 - r
        func L(_ i: Int) -> Node { .leaf(i) }
        func eq(_ axis: Axis, _ ids: [Int]) -> Node {
            ids.count == 1 ? L(ids[0]) : .split(axis, Array(repeating: 1, count: ids.count), ids.map(L))
        }
        func pair(_ axis: Axis, _ a: Int, _ b: Int) -> Node { .split(axis, [r, rest], [L(a), L(b)]) }

        switch kind {
        case .columns:
            if n == 2 { return pair(.horizontal, 0, 1) }
            return eq(.horizontal, Array(0..<n))
        case .rows:
            if n == 2 { return pair(.vertical, 0, 1) }
            return eq(.vertical, Array(0..<n))
        case .side:
            let others = Array(1..<n)
            if vertical { return .split(.vertical, [r, rest], [L(0), eq(.horizontal, others)]) }
            if ultrawide && n >= 3 {
                // two large windows + a narrow column for the rest
                let total = 0.70 + (r - 0.5) * 0.48
                let mainShare = 0.5 + (r - 0.5) * 0.5
                return .split(.horizontal, [total * mainShare, total * (1 - mainShare), 1 - total],
                              [L(0), L(1), eq(.vertical, Array(2..<n))])
            }
            return .split(.horizontal, [r, rest], [L(0), eq(.vertical, others)])
        case .grid:
            if vertical {
                switch n {
                case 2: return pair(.vertical, 0, 1)
                case 3: return .split(.vertical, [r, rest], [L(0), eq(.horizontal, [1, 2])])
                case 4: return .split(.vertical, [1, 1], [pair(.horizontal, 0, 1), pair(.horizontal, 2, 3)])
                default:
                    return .split(.vertical, [r, rest],
                                  [L(0), .split(.vertical, [1, 1], [eq(.horizontal, [1, 2]), eq(.horizontal, [3, 4])])])
                }
            }
            switch n {
            case 2: return pair(.horizontal, 0, 1)
            case 3: return .split(.horizontal, [r, rest], [L(0), eq(.vertical, [1, 2])])
            case 4: return .split(.vertical, [1, 1], [pair(.horizontal, 0, 1), pair(.horizontal, 2, 3)])
            default:
                return .split(.horizontal, [r, rest],
                              [L(0), .split(.vertical, [1, 1], [eq(.horizontal, [1, 2]), eq(.horizontal, [3, 4])])])
            }
        }
    }

    /// Smallest extent the subtree needs along `axis`.
    static func minExtent(_ node: Node, _ axis: Axis, gap: Double, mins: [CGSize]) -> Double {
        switch node {
        case .leaf(let i):
            let m = i < mins.count ? mins[i] : .zero
            return Double(axis == .horizontal ? m.width : m.height)
        case .split(let a, _, let kids):
            let ext = kids.map { minExtent($0, axis, gap: gap, mins: mins) }
            if a == axis { return ext.reduce(0, +) + gap * Double(kids.count - 1) }
            return ext.max() ?? 0
        }
    }

    static func solve(_ node: Node, in rect: CGRect, gap: Double, mins: [CGSize], count: Int) -> [CGRect] {
        var out = [CGRect](repeating: .zero, count: count)
        place(node, rect, gap, mins, &out)
        return out
    }

    private static func place(_ node: Node, _ rect: CGRect, _ gap: Double, _ mins: [CGSize], _ out: inout [CGRect]) {
        switch node {
        case .leaf(let i):
            if i < out.count { out[i] = rect }
        case .split(let axis, let weights, let kids):
            let n = kids.count
            let total = Double(axis == .horizontal ? rect.width : rect.height) - gap * Double(n - 1)
            let kidMins = kids.map { minExtent($0, axis, gap: gap, mins: mins) }
            let sizes = distribute(total, weights, kidMins)
            var pos = Double(axis == .horizontal ? rect.minX : rect.minY)
            for (i, kid) in kids.enumerated() {
                let r = axis == .horizontal
                    ? CGRect(x: pos, y: Double(rect.minY), width: sizes[i], height: Double(rect.height))
                    : CGRect(x: Double(rect.minX), y: pos, width: Double(rect.width), height: sizes[i])
                place(kid, r, gap, mins, &out)
                pos += sizes[i] + gap
            }
        }
    }

    /// Splits `total` by weight, honouring per-child minimums.
    static func distribute(_ total: Double, _ weights: [Double], _ mins: [Double]) -> [Double] {
        let n = weights.count
        var sizes = [Double](repeating: 0, count: n)
        var fixed = [Bool](repeating: false, count: n)
        var remaining = max(0, total)
        for _ in 0...n {
            let freeW = (0..<n).filter { !fixed[$0] }.map { weights[$0] }.reduce(0, +)
            if freeW <= 0 { break }
            for i in 0..<n where !fixed[i] { sizes[i] = remaining * weights[i] / freeW }
            var changed = false
            for i in 0..<n where !fixed[i] && sizes[i] < mins[i] {
                sizes[i] = mins[i]; fixed[i] = true; changed = true
                remaining -= mins[i]
            }
            if !changed { break }
            remaining = max(0, remaining)
        }
        return sizes
    }
}

enum LayoutSelfTest {
    /// `Tegula --selftest-layout`: checks every layout for count/bounds/overlap.
    static func run() -> Bool {
        var failures = 0, checks = 0
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let shapes: [(String, CGRect, Bool, Bool)] = [
            ("landscape", CGRect(x: 0, y: 0, width: 1600, height: 1000), false, false),
            ("ultrawide", CGRect(x: 0, y: 0, width: 3440, height: 1440), true, false),
            ("vertical", CGRect(x: 0, y: 0, width: 1000, height: 1600), false, true),
        ]
        for kind in LayoutKind.allCases {
            for (name, rect, ultra, vert) in shapes {
                for ratio in [0.5, 0.6, 2.0 / 3.0] {
                    for n in 1...LayoutEngine.capacity(ultrawide: ultra) {
                        checks += 1
                        let tree = LayoutEngine.tree(kind: kind, count: n, ratio: ratio, ultrawide: ultra, vertical: vert)
                        let rs = LayoutEngine.solve(tree, in: rect, gap: 8, mins: [], count: n)
                        var bad = rs.count != n
                        for (i, a) in rs.enumerated() {
                            if a.width < 50 || a.height < 50 || !rect.insetBy(dx: -0.01, dy: -0.01).contains(a) { bad = true }
                            for b in rs[(i + 1)...] where a.intersection(b).width > 0.5 && a.intersection(b).height > 0.5 { bad = true }
                        }
                        if bad { failures += 1; print("FAIL \(kind) \(name) n=\(n) r=\(ratio): \(rs)") }
                    }
                }
            }
        }
        // min-size behaviour: a 900pt-wide minimum in tile 1 of a 2-column layout must be honoured.
        checks += 1
        let t = LayoutEngine.tree(kind: .columns, count: 2, ratio: 0.5, ultrawide: false, vertical: false)
        let rs = LayoutEngine.solve(t, in: bounds, gap: 8, mins: [.zero, CGSize(width: 900, height: 0)], count: 2)
        if rs[1].width < 899.9 || abs(rs[0].width + rs[1].width + 8 - 1600) > 0.01 { failures += 1; print("FAIL min-size: \(rs)") }
        print(failures == 0 ? "layout selftest OK (\(checks) checks)" : "layout selftest: \(failures) FAILED of \(checks)")
        return failures == 0
    }
}
