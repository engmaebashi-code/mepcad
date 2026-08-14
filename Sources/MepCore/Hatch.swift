import Foundation

// MARK: - 塗り・ハッチング(M5.2)
//
// FILDERのハッチングを参考に、境界ポリゴン+パターンを1つのエンティティとして持つ。
// 線に分解せず塊のまま(移動・削除・属性変更が1操作、DXF/JWWの塗りの受け皿にもなる)。
// パターン線は描画時に境界でクリップして生成する(HatchGeometry)。
// v1パターン: 塗り・水平・垂直・2線・3線・クロス1・ブロック1(レンガ)。
// クロス2・ブロック2は次回。間隔は実寸mmで保持(印刷寸入力はUI側で縮尺を掛けて変換)。

public struct HatchPattern: Equatable, Codable, Sendable {

    public enum Kind: String, CaseIterable, Codable, Sendable {
        case solid      // 塗りつぶし
        case horizontal // 水平線
        case vertical   // 垂直線
        case twoLine    // 2線(A=組ピッチ、B=組内間隔)
        case threeLine  // 3線
        case cross      // クロス1(A=横間隔、B=縦間隔)
        case brick      // ブロック1(レンガ: A=段高、B=レンガ幅)

        public var label: String {
            switch self {
            case .solid: return "塗り"
            case .horizontal: return "水平"
            case .vertical: return "垂直"
            case .twoLine: return "2線"
            case .threeLine: return "3線"
            case .cross: return "クロス"
            case .brick: return "レンガ"
            }
        }

        /// B間隔を使うパターンか(UIの入力欄の有効/無効)
        public var usesSpacingB: Bool {
            switch self {
            case .twoLine, .threeLine, .cross, .brick: return true
            case .solid, .horizontal, .vertical: return false
            }
        }
    }

    public var kind: Kind
    /// 主間隔(実寸mm)
    public var spacingA: Double
    /// 副間隔(実寸mm。2線/3線=組内間隔、クロス=縦間隔、レンガ=幅)
    public var spacingB: Double
    /// 基準角度(rad。水平パターンの線方向)
    public var angle: Double

    public init(kind: Kind, spacingA: Double = 100, spacingB: Double = 50, angle: Double = 0) {
        self.kind = kind
        self.spacingA = max(spacingA, 0.01)
        self.spacingB = max(spacingB, 0.01)
        self.angle = angle
    }
}

// MARK: - パターン線の生成(境界クリップ)

public enum HatchGeometry {

    /// 生成する線分数の上限(誤設定でメモリを食い潰さないための安全弁)
    public static let strokeLimit = 20000

    /// 点がポリゴン内か(偶奇規則)
    public static func polygonContains(_ p: Vec2, _ polygon: [Vec2]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let t = (p.y - a.y) / (b.y - a.y)
                if p.x < a.x + t * (b.x - a.x) {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// パターン線分(実寸座標)。境界ポリゴンでクリップ済み。solidは空を返す(塗りは描画側でfill)
    public static func strokes(boundary: [Vec2], pattern: HatchPattern) -> [(a: Vec2, b: Vec2)] {
        guard boundary.count >= 3, pattern.kind != .solid else { return [] }

        // 基準角度で回した座標系に変換(以後は水平線の生成だけ考えればよい)
        let angle = pattern.angle
        let c = cos(-angle)
        let s = sin(-angle)
        let rotated = boundary.map { Vec2($0.x * c - $0.y * s, $0.x * s + $0.y * c) }
        var box = BBox.empty
        for p in rotated { box.union(point: p) }
        guard !box.isEmpty else { return [] }

        var localStrokes: [(Vec2, Vec2)] = []

        // 水平線 y=const を境界でクリップして追加
        func addScanline(y: Double) {
            var xs: [Double] = []
            var j = rotated.count - 1
            for i in 0..<rotated.count {
                let a = rotated[i]
                let b = rotated[j]
                if (a.y > y) != (b.y > y) {
                    let t = (y - a.y) / (b.y - a.y)
                    xs.append(a.x + t * (b.x - a.x))
                }
                j = i
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                if xs[k + 1] - xs[k] > 1e-9 {
                    localStrokes.append((Vec2(xs[k], y), Vec2(xs[k + 1], y)))
                }
                k += 2
            }
        }

        /// 垂直の短い線分 [y0,y1]×(x=const) を境界でクリップして追加(レンガの目地用)
        func addVerticalSegment(x: Double, y0: Double, y1: Double) {
            var ys: [Double] = []
            var j = rotated.count - 1
            for i in 0..<rotated.count {
                let a = rotated[i]
                let b = rotated[j]
                if (a.x > x) != (b.x > x) {
                    let t = (x - a.x) / (b.x - a.x)
                    ys.append(a.y + t * (b.y - a.y))
                }
                j = i
            }
            ys.sort()
            var k = 0
            while k + 1 < ys.count {
                let lo = max(ys[k], y0)
                let hi = min(ys[k + 1], y1)
                if hi - lo > 1e-9 {
                    localStrokes.append((Vec2(x, lo), Vec2(x, hi)))
                }
                k += 2
            }
        }

        let spacingA = max(pattern.spacingA, 0.01)
        let spacingB = max(pattern.spacingB, 0.01)

        /// 縦線は「90°回した水平線」として別フレームで作る方が単純なので、
        /// クロスは同じ関数を角度を変えて2回呼んだ結果を合成する
        switch pattern.kind {
        case .solid:
            return []

        case .horizontal, .vertical:
            // verticalはangle+90°で再帰(回転フレームの都合で単純化)
            if pattern.kind == .vertical {
                var rotatedPattern = pattern
                rotatedPattern.kind = .horizontal
                rotatedPattern.angle = angle + .pi / 2
                return strokes(boundary: boundary, pattern: rotatedPattern)
            }
            var y = (box.minY / spacingA).rounded(.down) * spacingA
            while y <= box.maxY {
                addScanline(y: y)
                if localStrokes.count > strokeLimit { break }
                y += spacingA
            }

        case .twoLine, .threeLine:
            let linesPerGroup = pattern.kind == .twoLine ? 2 : 3
            let period = spacingA
            var base = (box.minY / period).rounded(.down) * period
            while base <= box.maxY {
                for i in 0..<linesPerGroup {
                    addScanline(y: base + Double(i) * spacingB)
                }
                if localStrokes.count > strokeLimit { break }
                base += period
            }

        case .cross:
            var horizontal = pattern
            horizontal.kind = .horizontal
            var vertical = pattern
            vertical.kind = .horizontal
            vertical.angle = angle + .pi / 2
            vertical.spacingA = spacingB
            return strokes(boundary: boundary, pattern: horizontal)
                + strokes(boundary: boundary, pattern: vertical)

        case .brick:
            // 段の横線(間隔A)+段ごとに半分ずらした縦目地(間隔B)
            var y = (box.minY / spacingA).rounded(.down) * spacingA
            var row = Int((box.minY / spacingA).rounded(.down))
            while y <= box.maxY {
                addScanline(y: y)
                let stagger = (row % 2 == 0) ? 0 : spacingB / 2
                var x = (box.minX / spacingB).rounded(.down) * spacingB + stagger
                while x <= box.maxX {
                    addVerticalSegment(x: x, y0: y, y1: y + spacingA)
                    if localStrokes.count > strokeLimit { break }
                    x += spacingB
                }
                if localStrokes.count > strokeLimit { break }
                y += spacingA
                row += 1
            }
        }

        // 元の角度へ戻す
        let cb = cos(angle)
        let sb = sin(angle)
        return localStrokes.map { stroke in
            (Vec2(stroke.0.x * cb - stroke.0.y * sb, stroke.0.x * sb + stroke.0.y * cb),
             Vec2(stroke.1.x * cb - stroke.1.y * sb, stroke.1.x * sb + stroke.1.y * cb))
        }
    }
}
