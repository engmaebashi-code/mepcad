import Foundation

// MARK: - 配管(衛生・空調)M6.0 / M6.1 / M6.2
//
// 3D芯線(Vec3の折れ線)+口径傍記。図面は平面図(x,y)への投影で描き、zが高さ。
// 用途(給水・排水…)の色・線種はエンティティのStyleに記入時に焼き込み、
// 表示に必要な情報(用途名・管種略号・呼び径・外径)は属性として保持する
// — マスタ(MepData)が無くても図面単体で描ける・集計できる設計。
// M6.1: 複線表現(外径2本+芯線)・折れ点の継手(エルボ)自動発生。
// M6.2: 頂点にz(高さ)。隣接頂点が平面上同一点でzが違えば「立管」=立上り/立下り記号を
//       自動発生し、延長は3Dで拾う。基準面(1FL/2FL/GL)は属性datumに保持。

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
    /// 高さの基準面ラベル("1FL"/"2FL"/"GL"…)。傍記「50 2FL+2500」に使う。M6.2
    public var datum: String
    /// 傍記に高さを併記するか(例: 50 1FL+2500)
    public var showLevel: Bool
    /// 複線表現(外径2本+芯線)。falseなら単線
    public var doubleLine: Bool
    /// 折れ点に継手(エルボ)を自動発生させるか(複線時のみ描画)
    public var autoFittings: Bool
    /// 継手の規格シリーズ("DV"=排水用塩ビ / "TS"・"HI"=給水用塩ビ / "HT" / "SGP"=ねじ込み)。M6.3
    public var fittingSeries: String
    /// 継手の寸法(規格シリーズ×呼び径でマスタから引いた値を保持。0なら外径から概算)
    public var fittingDims: PipeFittingDims
    /// 接続されていない端部にキャップを付ける(FILDERの端部品相当)
    public var capEnds: Bool
    /// 単線シンボルの基準寸法(実寸mm=紙面mm×縮尺。0なら文字高さから既定)。M6.5
    /// 管サイズに依らず紙面上で一定(FILDER: 排水2.5mm・給水は一回り小さく)
    public var symbolSize: Double
    /// 90°曲り部品を大曲エルボ(LL)にする(排水系。FILDERの「90°曲り部品」)。M6.6
    public var longRadius: Bool
    /// 傍記に管種略号を含める("HI 20" のように)。M6.6
    public var annotateMaterial: Bool
    /// この配管を枝管として本管に取り付けたときの分岐部品: "DT"(90°Y)/"LT"(90°大曲Y)/"Y"(45°Y)。M6.8
    /// Yは枝が45°で取り付くときに使う(直角ならDTに落ちる)
    public var branchKind: String

    public init(usage: String = "CW", usageName: String = "給水",
                material: String = "HIVP", materialLabel: String = "HIVP",
                size: String = "20", sizeLabel: String = "20",
                outerDiameter: Double = 26,
                annotate: Bool = true, textHeight: Double = 125,
                datum: String = "1FL", showLevel: Bool = false,
                doubleLine: Bool = false, autoFittings: Bool = true,
                fittingSeries: String = "", fittingDims: PipeFittingDims = PipeFittingDims(),
                capEnds: Bool = false, symbolSize: Double = 0,
                longRadius: Bool = false, annotateMaterial: Bool = true,
                branchKind: String = "DT") {
        self.usage = usage
        self.usageName = usageName
        self.material = material
        self.materialLabel = materialLabel
        self.size = size
        self.sizeLabel = sizeLabel
        self.outerDiameter = outerDiameter
        self.annotate = annotate
        self.textHeight = textHeight
        self.datum = datum
        self.showLevel = showLevel
        self.doubleLine = doubleLine
        self.autoFittings = autoFittings
        self.fittingSeries = fittingSeries
        self.fittingDims = fittingDims
        self.capEnds = capEnds
        self.symbolSize = symbolSize
        self.longRadius = longRadius
        self.annotateMaterial = annotateMaterial
        self.branchKind = branchKind
    }

    /// 単線シンボルの実効基準寸法(実寸mm)。未設定なら文字高さ(排水)・その0.8倍(給水)
    public var effectiveSymbolSize: Double {
        if symbolSize > 0 { return symbolSize }
        let drain = fittingSeries == "DV" || fittingSeries == "HTDV"
            || (fittingSeries.isEmpty && ["S", "W", "RW", "VT"].contains(usage))
        return max(textHeight * (drain ? 1.0 : 0.8), 1)
    }

    /// 継手の実効寸法(マスタ値があればそれ、無ければ外径からの概算)
    public var effectiveFittingDims: PipeFittingDims {
        fittingDims.isEmpty ? PipeFittingDims.estimated(outerDiameter: outerDiameter) : fittingDims
    }

    /// 高さの表記("1FL+2500" / "1FL±0" / "GL-250")
    public func levelLabel(_ z: Double) -> String {
        if abs(z) < 0.5 { return "\(datum)±0" }
        return z > 0 ? String(format: "%@+%.0f", datum, z) : String(format: "%@%.0f", datum, z)
    }
}

/// 継手の寸法(実寸mm)。規格シリーズ×呼び径ごとにマスタ(fittings.csv)から引く。M6.3
public struct PipeFittingDims: Equatable, Codable, Sendable {
    /// エルボ90°の中心〜端面(A寸法)
    public var elbow90A: Double
    /// エルボ45°の中心〜端面
    public var elbow45A: Double
    /// ティーズの中心〜端面
    public var teeA: Double
    /// 受口深さ(差込み長さ)
    public var socketDepth: Double
    /// 受口外径(継手本体の太さ)
    public var socketOD: Double
    /// キャップの長さ
    public var capLength: Double
    /// 90°大曲エルボ(LL)の中心〜端面(0=マスタに無い→DLの1.6倍で概算)。M6.6
    public var elbow90LLA: Double
    /// 45°Y(排水)の中心〜枝端面(0=マスタに無い→DTの1.72倍で概算)。M6.7
    public var y45A: Double

    public init(elbow90A: Double = 0, elbow45A: Double = 0, teeA: Double = 0,
                socketDepth: Double = 0, socketOD: Double = 0, capLength: Double = 0,
                elbow90LLA: Double = 0, y45A: Double = 0) {
        self.elbow90A = elbow90A
        self.elbow45A = elbow45A
        self.teeA = teeA
        self.socketDepth = socketDepth
        self.socketOD = socketOD
        self.capLength = capLength
        self.elbow90LLA = elbow90LLA
        self.y45A = y45A
    }

    /// 大曲エルボの実効A(マスタ値、無ければDL×1.6。DV100: 178/112)
    public var effectiveElbow90LLA: Double { elbow90LLA > 0 ? elbow90LLA : elbow90A * 1.6 }

    public var isEmpty: Bool { socketOD <= 0 || elbow90A <= 0 }

    /// マスタが無いときの概算(外径比例。M6.1までの見た目と同じ)
    public static func estimated(outerDiameter od: Double) -> PipeFittingDims {
        let reach = max(od * 0.9, 20)
        return PipeFittingDims(elbow90A: reach, elbow45A: reach * 0.6, teeA: reach,
                               socketDepth: reach * 0.7, socketOD: od * 1.15,
                               capLength: reach * 0.8)
    }
}

/// 折れ点・分岐点・端部に発生する継手
public struct PipeFitting: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case elbow90 = "エルボ90°"
        case elbow45 = "エルボ45°"
        case elbowOther = "エルボ(その他)"
        case tee = "ティーズ"
        case cap = "キャップ"
        case reducer = "レデューサ"
    }
    public let kind: Kind
    /// 位置(平面)
    public let position: Vec2
    /// 折れ角(rad。0=直進)。ティーズ・キャップ・レデューサは0
    public let turnAngle: Double
}

/// 立管(立上り/立下り)。平面上は1点
public struct PipeRiser: Equatable, Sendable {
    public let position: Vec2
    /// 進行方向に見た高さ変化(mm。正=立上り、負=立下り)
    public let deltaZ: Double
    public var isUp: Bool { deltaZ > 0 }
}

/// 継手1個の平面形状(複線用)。部品は描画順(後の部品が上)。塗り+線で描く
public struct PipeFittingShape: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case polygon([Vec2])
        case circle(center: Vec2, radius: Double)
        /// 開いた折れ線(線のみ・塗らない。傾いた受口の縁=楕円弧など)
        case polyline([Vec2])
    }
    public var parts: [Part]
    public init(parts: [Part]) { self.parts = parts }
    /// 形状に含まれる点(bounds用)
    public var points: [Vec2] {
        parts.flatMap { part -> [Vec2] in
            switch part {
            case .polygon(let pts): return pts
            case .circle(let c, let r):
                return [Vec2(c.x - r, c.y - r), Vec2(c.x + r, c.y + r)]
            case .polyline(let pts): return pts
            }
        }
    }
}

/// 複線表現の導出ジオメトリ(平面図)
public struct PipeDoubleLineLayout: Sendable {
    /// 外形線(左側・右側)と芯線。継手ありなら区間ごと(継手位置で受口底まで切り詰め)、
    /// 継手なしならランごと(折れ点はマイター)
    public var runs: [(left: [Vec2], right: [Vec2], center: [Vec2])]
    /// 継手(折れ点エルボ・立管の付け根の受口)の形状
    public var fittings: [PipeFittingShape]
    /// 端部の閉じ線(自由端のみ)
    public var endCaps: [(Vec2, Vec2)]
}

public enum PipeGeometry {

    /// 平面上で同一点とみなす許容(mm)
    public static let planEpsilon = 1e-6

    /// 配管の延長(実寸mm・3D)。立管の長さも含む
    public static func length(of points: [Vec3]) -> Double {
        guard points.count >= 2 else { return 0 }
        var len = 0.0
        for i in 0..<(points.count - 1) {
            len += points[i].distance(to: points[i + 1])
        }
        return len
    }

    /// 立管の一覧(隣接頂点が平面上同一点でzが違う箇所)
    public static func risers(points: [Vec3]) -> [PipeRiser] {
        guard points.count >= 2 else { return [] }
        var result: [PipeRiser] = []
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            if a.xy.distance(to: b.xy) <= planEpsilon, abs(b.z - a.z) > 0.5 {
                result.append(PipeRiser(position: a.xy, deltaZ: b.z - a.z))
            }
        }
        return result
    }

    /// 水平区間(ラン)に分割した平面折れ線。立管の箇所で切れる。
    /// 各ランは平面上で長さを持つ頂点列(重複点は畳む)
    public static func planRuns(points: [Vec3]) -> [[Vec3]] {
        var runs: [[Vec3]] = []
        var current: [Vec3] = []
        for p in points {
            if let last = current.last, last.xy.distance(to: p.xy) <= planEpsilon {
                if abs(p.z - last.z) <= 0.5 {
                    continue   // 同じ高さの重複点は畳む(ランは切らない)
                }
                // 立管: ランを閉じて次へ
                if current.count >= 2 { runs.append(current) }
                current = [p]
                continue
            }
            current.append(p)
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// 傍記の内容("50" / "50 1FL+2500")。高さは指定区間のz
    public static func annotationText(_ attrs: PipeAttributes, z: Double) -> String {
        var s = attrs.annotateMaterial && !attrs.materialLabel.isEmpty
            ? "\(attrs.materialLabel) \(attrs.sizeLabel)" : attrs.sizeLabel
        if attrs.showLevel { s += " " + attrs.levelLabel(z) }
        return s
    }

    /// 口径傍記の配置(平面上で最長の区間の中点・線の左側・読み下し方向)。
    /// 複線時は外形線の外側へ逃がす。戻り値: (基準点=左下, 内容, 角度)。annotate=falseや退化時はnil
    public static func annotation(points: [Vec3], attrs: PipeAttributes)
        -> (position: Vec2, content: String, angle: Double)? {
        guard attrs.annotate, points.count >= 2 else { return nil }
        // 平面上で最長の区間を探す(立管は長さ0なので選ばれない)
        var bestIndex = 0
        var bestLen = -1.0
        for i in 0..<(points.count - 1) {
            let len = points[i].xy.distance(to: points[i + 1].xy)
            if len > bestLen {
                bestLen = len
                bestIndex = i
            }
        }
        guard bestLen > planEpsilon else { return nil }
        let a = points[bestIndex]
        let b = points[bestIndex + 1]
        // 読み下し方向へ正規化(寸法値と同じ流儀)
        var angle = atan2(b.y - a.y, b.x - a.x)
        if angle > .pi / 2 + 1e-9 || angle <= -.pi / 2 + 1e-9 {
            angle += angle > 0 ? -.pi : .pi
        }
        let content = annotationText(attrs, z: a.z)
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

    /// 立上り/立下り記号の半径(実寸mm)。複線(継手あり)は受口外径の半分(=継手の円)、
    /// 単線は紙面基準寸法の半分(FILDER: 直径=基準寸法)
    public static func riserSymbolRadius(_ attrs: PipeAttributes) -> Double {
        if attrs.doubleLine {
            let dims = attrs.effectiveFittingDims
            return max(dims.socketOD / 2, attrs.outerDiameter / 2 * 1.05)
        }
        return attrs.effectiveSymbolSize / 2
    }

    // MARK: - 継手(折れ点)

    /// 折れ点ごとの継手判定(3D方向の折れ角。直進≒0°は継手なし)。
    /// 立管の付け根(水平→鉛直)も90°エルボとして数える
    public static func fittings(points: [Vec3]) -> [PipeFitting] {
        guard points.count >= 3 else { return [] }
        var result: [PipeFitting] = []
        for i in 1..<(points.count - 1) {
            let d1 = points[i] - points[i - 1]
            let d2 = points[i + 1] - points[i]
            let l1 = d1.length
            let l2 = d2.length
            guard l1 > 1e-9, l2 > 1e-9 else { continue }
            let dot = (d1.x * d2.x + d1.y * d2.y + d1.z * d2.z) / (l1 * l2)
            let turn = acos(max(-1, min(1, dot)))   // 0..π
            let deg = turn * 180 / .pi
            guard deg > 2 else { continue }   // 直進扱い
            let kind: PipeFitting.Kind
            if abs(deg - 90) < 2 {
                kind = .elbow90
            } else if abs(deg - 45) < 2 {
                kind = .elbow45
            } else {
                kind = .elbowOther
            }
            // 平面上の折れの符号(左折正)。立管まわりは0
            let cross = d1.x * d2.y - d1.y * d2.x
            result.append(PipeFitting(kind: kind, position: points[i].xy,
                                      turnAngle: cross >= 0 ? turn : -turn))
        }
        return result
    }

    /// エルボ(ソケット部)の外形長さ: 芯からの張り出し(外径比例。マスタ無し時の概算)
    public static func fittingReach(outerDiameter: Double) -> Double {
        max(outerDiameter * 0.9, 20)
    }

    // MARK: - 複線表現

    /// エルボの外形寸法(実効。角度で90°/45°、90°は大曲(LL)指定ならLLのA)
    static func elbowA(_ dims: PipeFittingDims, turnDeg: Double, longRadius: Bool = false) -> Double {
        if turnDeg > 67.5 { return longRadius ? dims.effectiveElbow90LLA : dims.elbow90A }
        return dims.elbow45A
    }

    /// エルボの受口底までの距離a2(脚の長さで頭打ち。外形線の切り詰め量と共通)
    static func elbowSocketBottom(dims: PipeFittingDims, turnDeg: Double, len1: Double, len2: Double,
                                  longRadius: Bool = false) -> Double {
        let a = elbowA(dims, turnDeg: turnDeg, longRadius: longRadius)
        let a1 = min(a, len1)
        let a2Leg = min(a, len2)
        return min(max(a - dims.socketDepth, 0), max(a1 - 1, 0), max(a2Leg - 1, 0))
    }

    /// 平面エルボの実形状(受口2つ+曲がり本体)。メーカー図面どおり、本体は
    /// 「受口底の面同士の交点C」を中心とする環状扇形(外径=t+r、内径=t−r)。
    /// - u1: 折れ点→手前の頂点方向、u2: 折れ点→次の頂点方向(単位)。len1/len2: 各脚の長さ
    /// - slopedLeg: 1/2ならその脚が勾配(45°立ち下がり等の「ひねり」)。受口矩形の代わりに
    ///   傾いた受口の縁(楕円弧2本)を描く(FILDER部品DVDL1005の見え方)。0=両脚とも水平
    public static func elbowShape(corner p: Vec2, u1: Vec2, u2: Vec2, len1: Double, len2: Double,
                                  dims: PipeFittingDims, pipeRadius r: Double,
                                  longRadius: Bool = false, slopedLeg: Int = 0) -> PipeFittingShape? {
        let dot = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
        let phi = acos(dot)                       // 脚と脚のなす角(π=直進)
        let turn = Double.pi - phi                // 折れ角
        let turnDeg = turn * 180 / .pi
        guard turnDeg > 2, phi > 0.05 else { return nil }
        let a = elbowA(dims, turnDeg: turnDeg, longRadius: longRadius)
        let s = dims.socketOD / 2
        guard a > 0, s > 0 else { return nil }
        // 各脚の受口端(A)は脚の長さで頭打ち。受口底(a2)は共通(短い方に合わせる)
        let a1 = min(a, len1)
        let a2Leg = min(a, len2)
        let a2 = elbowSocketBottom(dims: dims, turnDeg: turnDeg, len1: len1, len2: len2,
                                   longRadius: longRadius)
        // 内側二等分線方向と受口底面の交点C
        let bis = u1 + u2
        let bl = bis.length
        guard bl > 1e-9 else { return nil }
        let m = bis * (1 / bl)
        let c = p + m * (a2 / cos(phi / 2))
        // 各脚の外側法線(Cから遠ざかる側)
        func outward(_ u: Vec2) -> Vec2 {
            let n = Vec2(-u.y, u.x)
            return (n.x * m.x + n.y * m.y) < 0 ? n : Vec2(-n.x, -n.y)
        }
        let n1 = outward(u1)
        let n2 = outward(u2)
        let t = a2 * tan(phi / 2)                 // C から脚の芯までの距離
        let ro = t + r
        let ri = max(t - r, 0)
        let q1 = p + u1 * a2 + n1 * r             // 外側円弧の始点(脚1の受口底×外側)
        let q2 = p + u2 * a2 + n2 * r
        // 円弧の分割(外側: q1→q2、内側: 逆)
        let ang1 = atan2(q1.y - c.y, q1.x - c.x)
        let ang2 = atan2(q2.y - c.y, q2.x - c.x)
        var sweep = ang2 - ang1
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        let segs = max(4, Int((abs(sweep) * 180 / .pi / 10).rounded(.up)))
        var poly: [Vec2] = []
        var extra: [PipeFittingShape.Part] = []
        if slopedLeg == 1 {
            // 脚1が勾配: 受口矩形なし。受口底で閉じ、傾いた受口の縁(楕円弧)を添える
            poly.append(p + u1 * a2 + n1 * r)
            extra += tiltedSocketRims(at: p + u1 * a2, dir: u1, halfWidth: s, depth: dims.socketDepth)
        } else {
            poly.append(p + u1 * a1 + n1 * s)
            poly.append(p + u1 * a2 + n1 * s)
        }
        for k in 0...segs {
            let ang = ang1 + sweep * Double(k) / Double(segs)
            poly.append(c + Vec2(cos(ang), sin(ang)) * ro)
        }
        if slopedLeg == 2 {
            poly.append(p + u2 * a2 - n2 * r)
            extra += tiltedSocketRims(at: p + u2 * a2, dir: u2, halfWidth: s, depth: dims.socketDepth)
        } else {
            poly.append(p + u2 * a2 + n2 * s)
            poly.append(p + u2 * a2Leg + n2 * s)
            poly.append(p + u2 * a2Leg - n2 * s)
            poly.append(p + u2 * a2 - n2 * s)
        }
        if ri > 1e-9 {
            for k in 0...segs {
                let ang = ang2 - sweep * Double(k) / Double(segs)
                poly.append(c + Vec2(cos(ang), sin(ang)) * ri)
            }
        } else {
            poly.append(c)
        }
        if slopedLeg == 1 {
            poly.append(p + u1 * a2 - n1 * r)
        } else {
            poly.append(p + u1 * a2 - n1 * s)
            poly.append(p + u1 * a1 - n1 * s)
        }
        return PipeFittingShape(parts: [.polygon(poly)] + extra)
    }

    /// 傾いた(45°勾配の)受口を真上から見た縁: 半楕円弧2本(受口端と受口底。奥行きは受口深さ×cos45°)。
    /// 楕円は脚方向に半径halfWidth×sin45°、直交方向にhalfWidth。dir方向へ膨らむ
    /// - dir: 勾配脚の方向(2本目の弧はこの方向へ受口深さ×cos45°ずらす)
    /// - bulge: 弧の膨らむ方向(省略時=dir。45°立ち下がりでは作図方向)
    static func tiltedSocketRims(at origin: Vec2, dir: Vec2, halfWidth s: Double, depth: Double,
                                 bulge: Vec2? = nil) -> [PipeFittingShape.Part] {
        let b = bulge ?? dir
        let n = Vec2(-b.y, b.x)
        let along = s * 0.7071
        var parts: [PipeFittingShape.Part] = []
        for offset in [0.0, depth * 0.7071] {
            let c = origin + dir * offset
            var pts: [Vec2] = []
            for k in 0...12 {
                let th = -Double.pi / 2 + Double.pi * Double(k) / 12
                pts.append(c + b * (along * cos(th)) + n * (s * sin(th)))
            }
            parts.append(.polyline(pts))
        }
        return parts
    }

    /// 傾き(勾配)の判定: 平面長さに対する高低差の比(tan20°以上で勾配脚とみなす)
    static func isSloped(_ a: Vec3, _ b: Vec3) -> Bool {
        let plan = a.xy.distance(to: b.xy)
        return plan > planEpsilon && abs(b.z - a.z) / plan > 0.36
    }

    /// 受口1個の四角形(始点aから方向uへ、a2〜aの区間、幅=受口外径)
    static func socketRect(from p: Vec2, dir u: Vec2, a2: Double, a: Double, halfWidth s: Double) -> [Vec2] {
        let n = Vec2(-u.y, u.x)
        let b0 = p + u * a2
        let b1 = p + u * a
        return [b0 + n * s, b1 + n * s, b1 - n * s, b0 - n * s]
    }

    /// 複線レイアウト(平面図)。継手ありなら区間ごとの外形線を継手の受口底まで切り詰め、
    /// 折れ点に実形状のエルボ、立管の付け根に水平側の受口を置く。
    /// 継手なしならランごとにマイター(急角度はベベル)
    public static func doubleLineLayout(points: [Vec3], attrs: PipeAttributes)
        -> PipeDoubleLineLayout? {
        guard points.count >= 2, attrs.outerDiameter > 1e-9 else { return nil }
        let r = attrs.outerDiameter / 2
        let dims = attrs.effectiveFittingDims
        let s = max(dims.socketOD / 2, r * 1.05)
        var runsOut: [(left: [Vec2], right: [Vec2], center: [Vec2])] = []
        var shapes: [PipeFittingShape] = []
        var caps: [(Vec2, Vec2)] = []
        let runs = planRuns(points: points)
        guard !runs.isEmpty else { return nil }

        for run in runs {
            let pts = run.map(\.xy)
            let n = pts.count
            var dirs: [Vec2] = []
            var normals: [Vec2] = []
            var lens: [Double] = []
            for i in 0..<(n - 1) {
                let d = pts[i + 1] - pts[i]
                let len = d.length
                let u = len > 1e-9 ? d * (1 / len) : Vec2(1, 0)
                dirs.append(u)
                normals.append(Vec2(-u.y, u.x))
                lens.append(len)
            }
            // 立管の付け根判定(ランの両端)
            let firstIdx = points.firstIndex(where: { $0 == run[0] }) ?? 0
            let lastIdx = points.firstIndex(where: { $0 == run[n - 1] }) ?? (points.count - 1)
            let riserAtStart = firstIdx > 0
                && points[firstIdx - 1].xy.distance(to: pts[0]) <= planEpsilon
                && abs(points[firstIdx - 1].z - run[0].z) > 0.5
            let riserAtEnd = lastIdx < points.count - 1
                && points[lastIdx + 1].xy.distance(to: pts[n - 1]) <= planEpsilon
                && abs(points[lastIdx + 1].z - run[n - 1].z) > 0.5

            if attrs.autoFittings {
                // 区間ごとの切り詰め量(始点側・終点側)
                var trimStart = [Double](repeating: 0, count: n - 1)
                var trimEnd = [Double](repeating: 0, count: n - 1)
                let a90 = dims.elbow90A
                let a2Riser = max(a90 - dims.socketDepth, 0)
                if n >= 3 {
                    for i in 1..<(n - 1) {
                        let u1 = Vec2(-dirs[i - 1].x, -dirs[i - 1].y)
                        let u2 = dirs[i]
                        let sloped1 = isSloped(run[i - 1], run[i])
                        let sloped2 = isSloped(run[i], run[i + 1])
                        let dot = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
                        let turnDeg = (Double.pi - acos(dot)) * 180 / .pi
                        if turnDeg <= 2 {
                            // 平面では直進。片脚だけ勾配なら「45°立ち下がり/上がり」の45°エルボ:
                            // 水平脚に受口、勾配脚側は傾いた受口の縁(楕円弧×2。膨らみは作図方向)
                            guard sloped1 != sloped2 else { continue }
                            let a = dims.elbow45A
                            guard a > 0 else { continue }
                            let a2 = max(a - dims.socketDepth, 0)
                            if sloped2 {
                                let aa = min(a, lens[i - 1]), aa2 = max(min(a2, aa - 1, lens[i - 1] * 0.5), 0)
                                shapes.append(PipeFittingShape(parts: [
                                    .polygon(socketRect(from: pts[i], dir: u1, a2: aa2, a: aa, halfWidth: s))]
                                    + tiltedSocketRims(at: pts[i], dir: u2, halfWidth: s, depth: dims.socketDepth)))
                                trimEnd[i - 1] = aa2
                            } else {
                                let aa = min(a, lens[i]), aa2 = max(min(a2, aa - 1, lens[i] * 0.5), 0)
                                shapes.append(PipeFittingShape(parts: [
                                    .polygon(socketRect(from: pts[i], dir: u2, a2: aa2, a: aa, halfWidth: s))]
                                    + tiltedSocketRims(at: pts[i], dir: u1, halfWidth: s, depth: dims.socketDepth,
                                                       bulge: u2)))
                                trimStart[i] = aa2
                            }
                            continue
                        }
                        // 折れ点のエルボ。片脚が勾配なら「ひねり」(その脚は傾いた受口の縁)
                        let slopedLeg = sloped1 && !sloped2 ? 1 : (!sloped1 && sloped2 ? 2 : 0)
                        if let shape = elbowShape(corner: pts[i], u1: u1, u2: u2,
                                                  len1: lens[i - 1], len2: lens[i],
                                                  dims: dims, pipeRadius: r,
                                                  longRadius: attrs.longRadius, slopedLeg: slopedLeg) {
                            shapes.append(shape)
                            let a2 = elbowSocketBottom(dims: dims, turnDeg: turnDeg,
                                                       len1: lens[i - 1], len2: lens[i],
                                                       longRadius: attrs.longRadius)
                            trimEnd[i - 1] = min(a2, lens[i - 1] * 0.5)
                            trimStart[i] = min(a2, lens[i] * 0.5)
                        }
                    }
                }
                if riserAtStart {
                    let a = min(a90, lens[0])
                    let a2 = min(a2Riser, max(a - 1, 0), lens[0] * 0.5)
                    shapes.append(PipeFittingShape(parts: [
                        .polygon(socketRect(from: pts[0], dir: dirs[0], a2: a2, a: a, halfWidth: s))]))
                    trimStart[0] = a2
                }
                if riserAtEnd {
                    let u = Vec2(-dirs[n - 2].x, -dirs[n - 2].y)
                    let a = min(a90, lens[n - 2])
                    let a2 = min(a2Riser, max(a - 1, 0), lens[n - 2] * 0.5)
                    shapes.append(PipeFittingShape(parts: [
                        .polygon(socketRect(from: pts[n - 1], dir: u, a2: a2, a: a, halfWidth: s))]))
                    trimEnd[n - 2] = a2
                }
                for i in 0..<(n - 1) {
                    let a = pts[i] + dirs[i] * trimStart[i]
                    let b = pts[i + 1] - dirs[i] * trimEnd[i]
                    let nn = normals[i]
                    runsOut.append(([a + nn * r, b + nn * r], [a - nn * r, b - nn * r], [pts[i], pts[i + 1]]))
                }
                if !riserAtStart { caps.append((pts[0] + normals[0] * r, pts[0] - normals[0] * r)) }
                if !riserAtEnd { caps.append((pts[n - 1] + normals[n - 2] * r, pts[n - 1] - normals[n - 2] * r)) }
                continue
            }

            // 継手なし: ランごとにマイター
            var left: [Vec2] = [pts[0] + normals[0] * r]
            var right: [Vec2] = [pts[0] - normals[0] * r]
            if n >= 3 {
                for i in 1..<(n - 1) {
                    let n1 = normals[i - 1]
                    let n2 = normals[i]
                    let bis = n1 + n2
                    let bisLen = bis.length
                    let cosHalf = (n1.x * n2.x + n1.y * n2.y + 1) / 2   // cos²(θ/2)
                    if bisLen < 1e-9 || cosHalf < 1e-9 {
                        left.append(pts[i] + n1 * r); left.append(pts[i] + n2 * r)
                        right.append(pts[i] - n1 * r); right.append(pts[i] - n2 * r)
                        continue
                    }
                    let miterLen = r / cosHalf.squareRoot()
                    let m = bis * (1 / bisLen)
                    if miterLen > r * 3 {
                        left.append(pts[i] + n1 * r); left.append(pts[i] + n2 * r)
                        right.append(pts[i] - n1 * r); right.append(pts[i] - n2 * r)
                    } else {
                        left.append(pts[i] + m * miterLen)
                        right.append(pts[i] - m * miterLen)
                    }
                }
            }
            left.append(pts[n - 1] + normals[n - 2] * r)
            right.append(pts[n - 1] - normals[n - 2] * r)
            caps.append((left[0], right[0]))
            caps.append((left[left.count - 1], right[right.count - 1]))
            runsOut.append((left, right, pts))
        }
        return PipeDoubleLineLayout(runs: runsOut, fittings: shapes, endCaps: caps)
    }

    /// 平面上の線分列(ヒットテスト・スナップ用。立管=長さ0は除く)
    public static func planSegments(points: [Vec3]) -> [(Vec2, Vec2)] {
        guard points.count >= 2 else { return [] }
        var segs: [(Vec2, Vec2)] = []
        for i in 0..<(points.count - 1) {
            let a = points[i].xy
            let b = points[i + 1].xy
            if a.distance(to: b) > planEpsilon { segs.append((a, b)) }
        }
        return segs
    }
}
