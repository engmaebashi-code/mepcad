import Foundation

// MARK: - 引出線文字・バルーン M5.5
//
// 傍記(引出線+文字)と機器番号バルーン(円形枠+引出線)。FILDER参考。
// エンティティは指示点(矢印先端)・文字位置(折れ点)・文字内容・属性を持ち、
// 引出線・矢印・バルーン楕円・文字配置は毎回導出する(LeaderGeometry)。
// バルーンの枠は文字数に合わせて自動サイズ(仕様確認済み)。

/// 引出線の見た目属性。長さは実寸mm(文字と同じく記入時に紙面mm×縮尺で換算して保存)
public struct LeaderAttributes: Equatable, Codable, Sendable {
    /// true=バルーン(円形枠に文字。機器番号用)、false=引出線文字(傍記)
    public var balloon: Bool
    /// バルーンの枠を二重にする
    public var doubleFrame: Bool
    /// 指示点に矢印を付ける
    public var arrow: Bool
    /// 文字高さ(実寸mm)
    public var textHeight: Double
    /// バルーンの縦横比(%)。80なら楕円(縦=横×0.8)
    public var aspectPercent: Double
    /// バルーンの横サイズ(実寸mm・直径)。nil=文字に合わせて自動(M5.5.1)
    public var balloonWidth: Double?

    public init(balloon: Bool = false,
                doubleFrame: Bool = false,
                arrow: Bool = true,
                textHeight: Double = 175,
                aspectPercent: Double = 80,
                balloonWidth: Double? = nil) {
        self.balloon = balloon
        self.doubleFrame = doubleFrame
        self.arrow = arrow
        self.textHeight = textHeight
        self.aspectPercent = aspectPercent
        self.balloonWidth = balloonWidth
    }

    // 派生寸法(文字高さ比例)
    /// 矢印の長さ
    public var arrowLength: Double { textHeight * 0.9 }
    /// 二重枠のオフセット(FILDERの0.8mm相当: 文字2.5mm時)
    public var frameOffset: Double { textHeight * 0.32 }
}

/// 引出線1本ぶんの導出ジオメトリ(描画・ヒットテスト・テストで共用)
public struct LeaderLayout: Sendable {
    /// 引出線の線分(指示点→折れ点、文字下の水平線 等)
    public var segments: [(Vec2, Vec2)]
    /// 矢印の羽根(矢印ありのとき2本)
    public var arrowStrokes: [(Vec2, Vec2)]
    /// バルーンの楕円(中心, 横半径, 縦半径)。二重枠なら2個
    public var ellipses: [(center: Vec2, rx: Double, ry: Double)]
    /// バルーン内の行区切り線(水平弦。複数行のとき。M5.5.2)
    public var dividers: [(Vec2, Vec2)]
    /// 文字(行ごと。基準点=左下・水平。既存の文字描画と同じ流儀)
    public var texts: [(position: Vec2, content: String)]
    public var textHeight: Double
}

public enum LeaderGeometry {

    /// 文字の概算幅(実寸mm)。半角(英数)0.62・全角0.95の文字別見積り
    /// (機器番号のような半角列で幅が過大にならないように。M5.5.1)
    public static func textWidth(_ content: String, height: Double) -> Double {
        var w = 0.0
        for ch in content {
            w += ch.isASCII ? height * 0.62 : height * 0.95
        }
        return max(height * 0.6, w)
    }

    /// バルーンの行分割: 「,」「，」区切りで二段・三段に分かれる(FILDER方式。M5.5.2)。
    /// 区切りが無ければ1行。空要素は捨てる
    public static func splitLines(_ content: String) -> [String] {
        let parts = content
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [content] : parts
    }

    /// 行送りピッチ(実寸mm)
    public static func rowPitch(_ textHeight: Double) -> Double { textHeight * 1.5 }

    /// 複数行の文字ブロック高さ(1行なら文字高さそのまま=従来と同じサイズ感)
    static func blockHeight(lineCount: Int, textHeight: Double) -> Double {
        lineCount <= 1 ? textHeight : Double(lineCount) * rowPitch(textHeight)
    }

    /// バルーン楕円の半径。
    /// 横サイズ指定あり: 指定直径をそのまま使う(FILDER方式。図面内で大きさが揃う)
    /// 自動: 縦横比aspect(=ry/rx)を保ったまま文字ブロック(最長行幅×行数ぶんの高さ)を包む最小楕円
    public static func balloonRadii(content: String, attrs: LeaderAttributes)
        -> (rx: Double, ry: Double) {
        let aspect = max(attrs.aspectPercent, 10) / 100
        if let width = attrs.balloonWidth, width > 0 {
            let rx = width / 2
            return (rx, rx * aspect)
        }
        let h = attrs.textHeight
        let lines = splitLines(content)
        let w = lines.map { textWidth($0, height: h) }.max() ?? h
        let blockH = blockHeight(lineCount: lines.count, textHeight: h)
        // 内接条件: (w/2)²/rx² + (H/2)²/(rx·aspect)² = 1 → rx² = (w/2)² + (H/(2·aspect))²
        let half = ((w / 2) * (w / 2) + (blockH / (2 * aspect)) * (blockH / (2 * aspect))).squareRoot()
        let rx = max(half * 1.1, h * 1.1)   // 余裕10%・最小サイズ確保
        return (rx, rx * aspect)
    }

    /// 引出線の全ジオメトリを導出する。
    /// - tip: 指示点(矢印先端)
    /// - elbow: 文字位置(引出線文字=文字の書き出し側の端 / バルーン=枠の中心)
    public static func layout(tip: Vec2, elbow: Vec2, content: String,
                              attrs: LeaderAttributes) -> LeaderLayout {
        var segments: [(Vec2, Vec2)] = []
        var arrows: [(Vec2, Vec2)] = []
        var ellipses: [(center: Vec2, rx: Double, ry: Double)] = []
        var dividers: [(Vec2, Vec2)] = []
        var texts: [(position: Vec2, content: String)] = []
        let h = attrs.textHeight
        /// 矢印の向きの基準点(引出線の折れ点側)
        var arrowRef = elbow

        if attrs.balloon {
            let (rx, ry) = balloonRadii(content: content, attrs: attrs)
            ellipses.append((elbow, rx, ry))
            if attrs.doubleFrame {
                ellipses.append((elbow, rx + attrs.frameOffset, ry + attrs.frameOffset))
            }
            // 引出線は楕円の外周まで(枠の中へは入れない)
            let dx = tip.x - elbow.x
            let dy = tip.y - elbow.y
            let outerRx = ellipses.last!.rx
            let outerRy = ellipses.last!.ry
            let q = (dx / outerRx) * (dx / outerRx) + (dy / outerRy) * (dy / outerRy)
            if q > 1 {
                // 指示点が枠の外にあるときだけ線を引く
                let t = 1 / q.squareRoot()
                let edge = Vec2(elbow.x + dx * t, elbow.y + dy * t)
                segments.append((tip, edge))
                arrowRef = edge
            }
            // 文字: 「,」区切りで二段・三段(行の間に区切り線=楕円の水平弦)
            let lines = splitLines(content)
            if lines.count == 1 {
                let w = textWidth(lines[0], height: h)
                texts.append((Vec2(elbow.x - w / 2, elbow.y - h / 2), lines[0]))
            } else {
                let pitch = Self.rowPitch(h)
                let blockH = Self.blockHeight(lineCount: lines.count, textHeight: h)
                for (i, line) in lines.enumerated() {
                    // 上からi行目のバンド(bandTop〜bandTop-pitch)。文字はバンド内で上下中央
                    let bandTop = elbow.y + blockH / 2 - Double(i) * pitch
                    let w = textWidth(line, height: h)
                    texts.append((Vec2(elbow.x - w / 2, bandTop - pitch + (pitch - h) / 2), line))
                    if i > 0 {
                        // 上の行との区切り線(内側の楕円の弦)
                        let dyc = bandTop - elbow.y
                        let ratio = dyc / ry
                        if abs(ratio) < 1 {
                            let half = rx * (1 - ratio * ratio).squareRoot()
                            dividers.append((Vec2(elbow.x - half, bandTop),
                                             Vec2(elbow.x + half, bandTop)))
                        }
                    }
                }
            }
        } else {
            // 引出線文字: 指示点→折れ点+文字下の水平線。文字は指示点と反対側へ書く
            let w = textWidth(content, height: h)
            let dir: Double = elbow.x >= tip.x ? 1 : -1
            let tailEnd = Vec2(elbow.x + dir * w, elbow.y)
            segments.append((tip, elbow))
            if w > 1e-9 {
                segments.append((elbow, tailEnd))
            }
            texts.append((Vec2(min(elbow.x, tailEnd.x), elbow.y + h * 0.15), content))
        }

        if attrs.arrow {
            let d = Vec2(arrowRef.x - tip.x, arrowRef.y - tip.y)
            let len = d.length
            if len > 1e-9 {
                let e = d * (1 / len)
                let wing = attrs.arrowLength
                let ca = cos(Double.pi / 12)   // 15°
                let sa = sin(Double.pi / 12)
                arrows = [
                    (tip, Vec2(tip.x + (e.x * ca - e.y * sa) * wing,
                               tip.y + (e.x * sa + e.y * ca) * wing)),
                    (tip, Vec2(tip.x + (e.x * ca + e.y * sa) * wing,
                               tip.y + (-e.x * sa + e.y * ca) * wing)),
                ]
            }
        }

        return LeaderLayout(segments: segments, arrowStrokes: arrows, ellipses: ellipses,
                            dividers: dividers, texts: texts, textHeight: h)
    }

    /// エンティティから直接レイアウトを得るヘルパ
    public static func layout(of entity: Entity) -> LeaderLayout? {
        guard case .leader(let tip, let elbow, let content, let attrs) = entity.kind else {
            return nil
        }
        return layout(tip: tip, elbow: elbow, content: content, attrs: attrs)
    }

    /// 楕円を折れ線近似した点列(ヒットテスト・矩形交差判定用)
    public static func ellipsePoints(center: Vec2, rx: Double, ry: Double,
                                     count: Int = 24) -> [Vec2] {
        (0..<count).map { i in
            let t = 2 * .pi * Double(i) / Double(count)
            return Vec2(center.x + rx * cos(t), center.y + ry * sin(t))
        }
    }
}
