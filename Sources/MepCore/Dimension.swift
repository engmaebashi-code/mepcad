import Foundation

// MARK: - 寸法記入 M5.4
//
// 長さ寸法(水平・垂直・平行)。エンティティは測定点a・b、寸法線の通過点、
// 寸法線方向(角度)、見た目属性(端部・文字サイズ・補助線長さ)を持ち、
// 寸法線・補助線・端部記号・寸法値文字の幾何は毎回導出する(DimensionGeometry)。
// 寸法値は「記入時の実測値」を幾何から表示する方式(図形を後から変えても
// 寸法の測定点は動かない=Jw_cad と同じ静的寸法)。
// ※配管寸法の自動追随は配管エンティティ(Phase 2)側で対応する設計。

/// 寸法の端部記号
public enum DimTerminator: Int, Equatable, Codable, Sendable, CaseIterable {
    case dot = 0      // 黒丸(実点)
    case arrow = 1    // 矢印

    public var label: String {
        switch self {
        case .dot: return "黒丸"
        case .arrow: return "矢印"
        }
    }
}

/// 寸法の見た目属性。長さは全て実寸mm(文字と同じく、記入時に紙面mm×縮尺で換算して保存)
public struct DimAttributes: Equatable, Codable, Sendable {
    /// 端部記号(黒丸/矢印)
    public var terminator: DimTerminator
    /// 寸法値の文字高さ(実寸mm)
    public var textHeight: Double
    /// 寸法補助線の長さ(実寸mm)。nil=測定点まで引く、0以下=補助線なし
    public var extensionLength: Double?

    public init(terminator: DimTerminator = .dot,
                textHeight: Double = 125,
                extensionLength: Double? = nil) {
        self.terminator = terminator
        self.textHeight = textHeight
        self.extensionLength = extensionLength
    }

    // 派生寸法(文字高さ比例。個別設定は環境設定で拡張予定)
    /// 測定点と補助線の離れ
    public var extensionGap: Double { textHeight * 0.4 }
    /// 補助線が寸法線を越えるはみ出し
    public var overshoot: Double { textHeight * 0.4 }
    /// 黒丸の半径
    public var dotRadius: Double { textHeight * 0.22 }
    /// 矢印の長さ
    public var arrowLength: Double { textHeight * 0.9 }
}

/// 寸法1本ぶんの導出ジオメトリ(描画・ヒットテスト・テストで共用)
public struct DimLayout: Sendable {
    /// 寸法線(d1→d2)
    public var dimLine: (Vec2, Vec2)
    /// 寸法補助線(0〜2本)
    public var extLines: [(Vec2, Vec2)]
    /// 矢印の線分(端部=矢印のとき。1端あたり2本)
    public var arrowStrokes: [(Vec2, Vec2)]
    /// 黒丸の中心(端部=黒丸のとき)
    public var dotCenters: [Vec2]
    public var dotRadius: Double
    /// 寸法値の文字(基準点=左下・実寸mm。既存の文字描画と同じ流儀)
    public var textPosition: Vec2
    public var textContent: String
    public var textHeight: Double
    public var textAngle: Double
    /// 実測値(実寸mm)
    public var value: Double

    /// ヒットテスト・矩形選択に使う線分一覧(寸法線+補助線)
    public var hitSegments: [(Vec2, Vec2)] {
        [dimLine] + extLines
    }
}

public enum DimensionGeometry {

    /// 寸法値の表記: 実寸mm。ほぼ整数なら整数表示、それ以外は小数1桁
    public static func formatValue(_ v: Double) -> String {
        if abs(v - v.rounded()) < 0.05 {
            return String(format: "%.0f", v.rounded())
        }
        return String(format: "%.1f", v)
    }

    /// 寸法値文字の概算幅(実寸mm。中央寄せ・ヒットテスト用)
    public static func textWidth(_ content: String, height: Double) -> Double {
        max(height * 0.6, Double(content.count) * height * 0.6)
    }

    /// 寸法の全ジオメトリを導出する。
    /// - a, b: 測定点(実寸mm)
    /// - linePoint: 寸法線が通る点
    /// - angle: 寸法線の方向(rad)。水平=0、垂直=π/2、平行=atan2(b-a)
    public static func layout(a: Vec2, b: Vec2, linePoint: Vec2,
                              angle: Double, attrs: DimAttributes) -> DimLayout {
        let u = Vec2(cos(angle), sin(angle))
        // 測定点を寸法線(linePoint + t·u)へ射影
        let ta = (a.x - linePoint.x) * u.x + (a.y - linePoint.y) * u.y
        let tb = (b.x - linePoint.x) * u.x + (b.y - linePoint.y) * u.y
        let d1 = Vec2(linePoint.x + u.x * ta, linePoint.y + u.y * ta)
        let d2 = Vec2(linePoint.x + u.x * tb, linePoint.y + u.y * tb)
        let value = abs(tb - ta)

        // 補助線(測定点→寸法線。はみ出し付き)
        var extLines: [(Vec2, Vec2)] = []
        let extLen = attrs.extensionLength
        if extLen.map({ $0 > 1e-9 }) ?? true {
            for (p, d) in [(a, d1), (b, d2)] {
                let off = d - p
                let dist = off.length
                guard dist > 1e-9 else { continue }  // 測定点が寸法線上なら補助線は不要
                let n = off * (1 / dist)
                let end = d + n * attrs.overshoot
                let start: Vec2
                if let len = extLen {
                    // 指定長さ: 寸法線から測定点側へlenだけ引く(測定点は越えない)
                    start = d - n * min(len, max(dist - attrs.extensionGap, 0))
                } else {
                    // 測定点まで(離れgapを空ける)
                    start = p + n * min(attrs.extensionGap, dist)
                }
                extLines.append((start, end))
            }
        }

        // 端部記号
        var arrows: [(Vec2, Vec2)] = []
        var dots: [Vec2] = []
        switch attrs.terminator {
        case .dot:
            dots = [d1, d2]
        case .arrow:
            let span = d2 - d1
            let len = span.length
            if len > 1e-9 {
                let e = span * (1 / len)
                let wing = attrs.arrowLength
                let ca = cos(Double.pi / 12)  // 15°
                let sa = sin(Double.pi / 12)
                func rot(_ v: Vec2, _ c: Double, _ s: Double) -> Vec2 {
                    Vec2(v.x * c - v.y * s, v.x * s + v.y * c)
                }
                // d1: 先端=d1、羽根はd2側へ / d2: 先端=d2、羽根はd1側へ
                arrows = [
                    (d1, d1 + rot(e * wing, ca, sa)),
                    (d1, d1 + rot(e * wing, ca, -sa)),
                    (d2, d2 - rot(e * wing, ca, sa)),
                    (d2, d2 - rot(e * wing, ca, -sa)),
                ]
            } else {
                dots = [d1]  // 退化(長さ0)は黒丸で示す
            }
        }

        // 寸法値文字: 寸法線の中央の上側。読み下し方向(±90°内)に正規化
        let content = formatValue(value)
        var textAngle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if textAngle < 0 { textAngle += 2 * .pi }
        if textAngle > .pi / 2 + 1e-9 && textAngle <= .pi * 3 / 2 + 1e-9 {
            textAngle -= .pi
            if textAngle < 0 { textAngle += 2 * .pi }
        }
        let ut = Vec2(cos(textAngle), sin(textAngle))
        let nt = Vec2(-ut.y, ut.x)
        let mid = Vec2((d1.x + d2.x) / 2, (d1.y + d2.y) / 2)
        let w = textWidth(content, height: attrs.textHeight)
        let textPos = mid - ut * (w / 2) + nt * (attrs.textHeight * 0.25)

        return DimLayout(dimLine: (d1, d2), extLines: extLines,
                         arrowStrokes: arrows, dotCenters: dots,
                         dotRadius: attrs.dotRadius,
                         textPosition: textPos, textContent: content,
                         textHeight: attrs.textHeight, textAngle: textAngle,
                         value: value)
    }

    /// エンティティから直接レイアウトを得るヘルパ
    public static func layout(of entity: Entity) -> DimLayout? {
        guard case .dimension(let a, let b, let lp, let angle, let attrs) = entity.kind else {
            return nil
        }
        return layout(a: a, b: b, linePoint: lp, angle: angle, attrs: attrs)
    }
}
