import Foundation

// MARK: - 配管(衛生・空調)M6.0
//
// 単線の折れ線+口径傍記。用途(給水・排水…)の色・線種はエンティティのStyleに
// 記入時に焼き込み、表示に必要な情報(用途名・管種略号・呼び径・外径)は属性として
// 保持する — マスタ(MepData)が無くても図面単体で描ける・集計できる設計。
// 2線表現・継手・勾配表記はv2で拡張する。

/// 配管の属性。文字サイズは実寸mm(文字と同じく記入時に紙面mm×縮尺で換算)
public struct PipeAttributes: Equatable, Codable, Sendable {
    /// 用途id("CW"等。マスタ参照キー)
    public var usage: String
    /// 用途名("給水"等。表示・集計用)
    public var usageName: String
    /// 管種id("VP"等。マスタ参照キー)
    public var material: String
    /// 管種略号("VP"・"SGP白"等。集計表示用)
    public var materialLabel: String
    /// 呼び径("50"等。マスタ参照キー)
    public var size: String
    /// 傍記表示("50"・"50A"・"50Su")
    public var sizeLabel: String
    /// 外径(実寸mm。将来の2線表現・干渉チェック用)
    public var outerDiameter: Double
    /// 口径傍記を表示するか
    public var annotate: Bool
    /// 傍記の文字高さ(実寸mm)
    public var textHeight: Double

    public init(usage: String = "CW", usageName: String = "給水",
                material: String = "HIVP", materialLabel: String = "HIVP",
                size: String = "20", sizeLabel: String = "20",
                outerDiameter: Double = 26,
                annotate: Bool = true, textHeight: Double = 125) {
        self.usage = usage
        self.usageName = usageName
        self.material = material
        self.materialLabel = materialLabel
        self.size = size
        self.sizeLabel = sizeLabel
        self.outerDiameter = outerDiameter
        self.annotate = annotate
        self.textHeight = textHeight
    }
}

public enum PipeGeometry {

    /// 配管の延長(実寸mm)
    public static func length(of points: [Vec2]) -> Double {
        guard points.count >= 2 else { return 0 }
        var len = 0.0
        for i in 0..<(points.count - 1) {
            len += points[i].distance(to: points[i + 1])
        }
        return len
    }

    /// 口径傍記の配置(最長セグメントの中点・線の左側・読み下し方向)。
    /// 戻り値: (基準点=左下, 内容, 角度)。annotate=falseや退化時はnil
    public static func annotation(points: [Vec2], attrs: PipeAttributes)
        -> (position: Vec2, content: String, angle: Double)? {
        guard attrs.annotate, points.count >= 2 else { return nil }
        // 最長セグメントを探す
        var bestIndex = 0
        var bestLen = -1.0
        for i in 0..<(points.count - 1) {
            let len = points[i].distance(to: points[i + 1])
            if len > bestLen {
                bestLen = len
                bestIndex = i
            }
        }
        guard bestLen > 1e-9 else { return nil }
        let a = points[bestIndex]
        let b = points[bestIndex + 1]
        // 読み下し方向へ正規化(寸法値と同じ流儀)
        var angle = atan2(b.y - a.y, b.x - a.x)
        if angle > .pi / 2 + 1e-9 || angle <= -.pi / 2 + 1e-9 {
            angle += angle > 0 ? -.pi : .pi
        }
        let content = attrs.sizeLabel
        let h = attrs.textHeight
        let w = textWidth(content, height: h)
        let ut = Vec2(cos(angle), sin(angle))
        let nt = Vec2(-ut.y, ut.x)
        let mid = Vec2((a.x + b.x) / 2, (a.y + b.y) / 2)
        // 線の上側(左法線方向)に少し離して中央寄せ
        let pos = mid - ut * (w / 2) + nt * (h * 0.3)
        return (pos, content, angle)
    }

    /// 傍記文字の概算幅(半角0.62・全角0.95 — 引出線と同じ見積り)
    public static func textWidth(_ content: String, height: Double) -> Double {
        var w = 0.0
        for ch in content {
            w += ch.isASCII ? height * 0.62 : height * 0.95
        }
        return max(height * 0.6, w)
    }
}
