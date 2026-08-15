import Foundation

// MARK: - 配管(衛生・空調)M6.0 / M6.1
//
// 折れ線ルート+口径傍記。用途(給水・排水…)の色・線種はエンティティのStyleに
// 記入時に焼き込み、表示に必要な情報(用途名・管種略号・呼び径・外径)は属性として
// 保持する — マスタ(MepData)が無くても図面単体で描ける・集計できる設計。
// M6.1: 高さ(level)・複線表現(外径2本+芯線)・折れ点の継手(エルボ)自動発生。

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
    /// 外径(実寸mm。複線表現・将来の干渉チェック用)
    public var outerDiameter: Double
    /// 口径傍記を表示するか
    public var annotate: Bool
    /// 傍記の文字高さ(実寸mm)
    public var textHeight: Double
    /// 高さ(mm。基準面からの芯高さ。FL+2500なら2500)。M6.1
    public var level: Double
    /// 傍記に高さを併記するか(例: 50 FL+2500)
    public var showLevel: Bool
    /// 複線表現(外径2本+芯線)。falseなら単線
    public var doubleLine: Bool
    /// 折れ点に継手(エルボ)を自動発生させるか(複線時のみ描画)
    public var autoFittings: Bool

    public init(usage: String = "CW", usageName: String = "給水",
                material: String = "HIVP", materialLabel: String = "HIVP",
                size: String = "20", sizeLabel: String = "20",
                outerDiameter: Double = 26,
                annotate: Bool = true, textHeight: Double = 125,
                level: Double = 0, showLevel: Bool = false,
                doubleLine: Bool = false, autoFittings: Bool = true) {
        self.usage = usage
        self.usageName = usageName
        self.material = material
        self.materialLabel = materialLabel
        self.size = size
        self.sizeLabel = sizeLabel
        self.outerDiameter = outerDiameter
        self.annotate = annotate
        self.textHeight = textHeight
        self.level = level
        self.showLevel = showLevel
        self.doubleLine = doubleLine
        self.autoFittings = autoFittings
    }

    // 後方互換: M6.0で保存した属性(新フィールド無し)も読める
    private enum CodingKeys: String, CodingKey {
        case usage, usageName, material, materialLabel, size, sizeLabel
        case outerDiameter, annotate, textHeight
        case level, showLevel, doubleLine, autoFittings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usage = try c.decode(String.self, forKey: .usage)
        usageName = try c.decode(String.self, forKey: .usageName)
        material = try c.decode(String.self, forKey: .material)
        materialLabel = try c.decode(String.self, forKey: .materialLabel)
        size = try c.decode(String.self, forKey: .size)
        sizeLabel = try c.decode(String.self, forKey: .sizeLabel)
        outerDiameter = try c.decode(Double.self, forKey: .outerDiameter)
        annotate = try c.decode(Bool.self, forKey: .annotate)
        textHeight = try c.decode(Double.self, forKey: .textHeight)
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 0
        showLevel = try c.decodeIfPresent(Bool.self, forKey: .showLevel) ?? false
        doubleLine = try c.decodeIfPresent(Bool.self, forKey: .doubleLine) ?? false
        autoFittings = try c.decodeIfPresent(Bool.self, forKey: .autoFittings) ?? true
    }

    /// 高さの表記("FL+2500" / "FL±0" / "FL-300")
    public var levelLabel: String {
        if abs(level) < 0.5 { return "FL±0" }
        return level > 0 ? String(format: "FL+%.0f", level) : String(format: "FL%.0f", level)
    }
}

/// 折れ点に発生する継手
public struct PipeFitting: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case elbow90 = "エルボ90°"
        case elbow45 = "エルボ45°"
        case elbowOther = "エルボ(その他)"
    }
    public let kind: Kind
    /// 折れ点
    public let position: Vec2
    /// 折れ角(rad。0=直進)
    public let turnAngle: Double
}

/// 複線表現の導出ジオメトリ
public struct PipeDoubleLineLayout: Sendable {
    /// 外形線(左側・右側)。マイター処理済みの折れ線
    public var leftOutline: [Vec2]
    public var rightOutline: [Vec2]
    /// 芯線(=ルートそのもの。一点鎖線で描く)
    public var centerline: [Vec2]
    /// 継手(エルボ)の外形四角形(各4点)
    public var fittingBoxes: [[Vec2]]
    /// 端部の閉じ線(両端)
    public var endCaps: [(Vec2, Vec2)]
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

    /// 傍記の内容("50" / "50 FL+2500")
    public static func annotationText(_ attrs: PipeAttributes) -> String {
        attrs.showLevel ? "\(attrs.sizeLabel) \(attrs.levelLabel)" : attrs.sizeLabel
    }

    /// 口径傍記の配置(最長セグメントの中点・線の左側・読み下し方向)。
    /// 複線時は外形線の外側へ逃がす。戻り値: (基準点=左下, 内容, 角度)。annotate=falseや退化時はnil
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
        let content = annotationText(attrs)
        let h = attrs.textHeight
        let w = textWidth(content, height: h)
        let ut = Vec2(cos(angle), sin(angle))
        let nt = Vec2(-ut.y, ut.x)
        let mid = Vec2((a.x + b.x) / 2, (a.y + b.y) / 2)
        // 線の上側(左法線方向)に少し離して中央寄せ。複線なら外径の半分ぶん外へ
        let clearance = h * 0.3 + (attrs.doubleLine ? attrs.outerDiameter / 2 : 0)
        let pos = mid - ut * (w / 2) + nt * clearance
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

    // MARK: - 継手(折れ点)

    /// 折れ点ごとの継手判定(直進≒0°は継手なし)
    public static func fittings(points: [Vec2]) -> [PipeFitting] {
        guard points.count >= 3 else { return [] }
        var result: [PipeFitting] = []
        for i in 1..<(points.count - 1) {
            let d1 = points[i] - points[i - 1]
            let d2 = points[i + 1] - points[i]
            guard d1.length > 1e-9, d2.length > 1e-9 else { continue }
            let a1 = atan2(d1.y, d1.x)
            let a2 = atan2(d2.y, d2.x)
            var turn = a2 - a1
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            let deg = abs(turn) * 180 / .pi
            guard deg > 2 else { continue }   // 直進扱い
            let kind: PipeFitting.Kind
            if abs(deg - 90) < 2 {
                kind = .elbow90
            } else if abs(deg - 45) < 2 {
                kind = .elbow45
            } else {
                kind = .elbowOther
            }
            result.append(PipeFitting(kind: kind, position: points[i], turnAngle: turn))
        }
        return result
    }

    /// エルボ(ソケット部)の外形長さ: 芯からの張り出し(外径比例。VP継手の受口深さ相当)
    public static func fittingReach(outerDiameter: Double) -> Double {
        max(outerDiameter * 0.9, 20)
    }

    // MARK: - 複線表現

    /// 複線レイアウト。折れ点はマイター(内外の外形線を延長交差)、
    /// 折れ角が急でマイターが伸びすぎる場合(>3×半径)はベベル(面取り)に落とす
    public static func doubleLineLayout(points: [Vec2], attrs: PipeAttributes)
        -> PipeDoubleLineLayout? {
        guard points.count >= 2, attrs.outerDiameter > 1e-9 else { return nil }
        let r = attrs.outerDiameter / 2
        let n = points.count

        // セグメントごとの単位方向と左法線
        var dirs: [Vec2] = []
        var normals: [Vec2] = []
        for i in 0..<(n - 1) {
            let d = points[i + 1] - points[i]
            let len = d.length
            let u = len > 1e-9 ? d * (1 / len) : Vec2(1, 0)
            dirs.append(u)
            normals.append(Vec2(-u.y, u.x))
        }

        var left: [Vec2] = []
        var right: [Vec2] = []
        // 始点
        left.append(points[0] + normals[0] * r)
        right.append(points[0] - normals[0] * r)
        // 折れ点(マイター)
        if n >= 3 {
            for i in 1..<(n - 1) {
                let n1 = normals[i - 1]
                let n2 = normals[i]
                let bis = n1 + n2
                let bisLen = bis.length
                let cosHalf = (n1.x * n2.x + n1.y * n2.y + 1) / 2   // cos²(θ/2)
                if bisLen < 1e-9 || cosHalf < 1e-9 {
                    // 折り返し(180°): 面取りで逃がす
                    left.append(points[i] + n1 * r)
                    left.append(points[i] + n2 * r)
                    right.append(points[i] - n1 * r)
                    right.append(points[i] - n2 * r)
                    continue
                }
                let miterLen = r / cosHalf.squareRoot()   // r / cos(θ/2)
                let m = bis * (1 / bisLen)
                if miterLen > r * 3 {
                    // 急角度: ベベル
                    left.append(points[i] + n1 * r)
                    left.append(points[i] + n2 * r)
                    right.append(points[i] - n1 * r)
                    right.append(points[i] - n2 * r)
                } else {
                    left.append(points[i] + m * miterLen)
                    right.append(points[i] - m * miterLen)
                }
            }
        }
        // 終点
        left.append(points[n - 1] + normals[n - 2] * r)
        right.append(points[n - 1] - normals[n - 2] * r)

        // 継手(エルボ)の外形: 折れ点を中心に、前後の区間へreachだけ張り出した
        // 太め(外径×1.15)の帯を2枚重ねる代わりに、簡易に「折れ点を挟む短い区間の
        // 外形四角形」を前後それぞれ描く(ソケットの受口が両側に見える表現)
        var boxes: [[Vec2]] = []
        if attrs.autoFittings {
            let reach = fittingReach(outerDiameter: attrs.outerDiameter)
            let rf = r * 1.15
            for f in fittings(points: points) {
                guard let idx = points.firstIndex(where: { $0.distance(to: f.position) < 1e-9 }),
                      idx >= 1, idx < n - 1 else { continue }
                // 手前区間側
                let u1 = dirs[idx - 1]
                let n1 = normals[idx - 1]
                let seg1Len = points[idx].distance(to: points[idx - 1])
                let back = points[idx] - u1 * min(reach, seg1Len)
                boxes.append([back + n1 * rf, points[idx] + n1 * rf,
                              points[idx] - n1 * rf, back - n1 * rf])
                // 先区間側
                let u2 = dirs[idx]
                let n2 = normals[idx]
                let seg2Len = points[idx + 1].distance(to: points[idx])
                let fwd = points[idx] + u2 * min(reach, seg2Len)
                boxes.append([points[idx] + n2 * rf, fwd + n2 * rf,
                              fwd - n2 * rf, points[idx] - n2 * rf])
            }
        }

        let caps: [(Vec2, Vec2)] = [(left[0], right[0]),
                                    (left[left.count - 1], right[right.count - 1])]
        return PipeDoubleLineLayout(leftOutline: left, rightOutline: right,
                                    centerline: points, fittingBoxes: boxes, endCaps: caps)
    }
}
