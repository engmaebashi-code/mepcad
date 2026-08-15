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

    public init(usage: String = "CW", usageName: String = "給水",
                material: String = "HIVP", materialLabel: String = "HIVP",
                size: String = "20", sizeLabel: String = "20",
                outerDiameter: Double = 26,
                annotate: Bool = true, textHeight: Double = 125,
                datum: String = "1FL", showLevel: Bool = false,
                doubleLine: Bool = false, autoFittings: Bool = true,
                fittingSeries: String = "", fittingDims: PipeFittingDims = PipeFittingDims(),
                capEnds: Bool = false) {
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

    public init(elbow90A: Double = 0, elbow45A: Double = 0, teeA: Double = 0,
                socketDepth: Double = 0, socketOD: Double = 0, capLength: Double = 0) {
        self.elbow90A = elbow90A
        self.elbow45A = elbow45A
        self.teeA = teeA
        self.socketDepth = socketDepth
        self.socketOD = socketOD
        self.capLength = capLength
    }

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

/// 複線表現の導出ジオメトリ(平面図)
public struct PipeDoubleLineLayout: Sendable {
    /// 水平区間(ラン)ごとの外形線(左側・右側)。マイター処理済み
    public var runs: [(left: [Vec2], right: [Vec2], center: [Vec2])]
    /// 継手(エルボ)の外形四角形(各4点)
    public var fittingBoxes: [[Vec2]]
    /// 端部の閉じ線(ランの両端)
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
        attrs.showLevel ? "\(attrs.sizeLabel) \(attrs.levelLabel(z))" : attrs.sizeLabel
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

    /// 立上り/立下り記号の半径(実寸mm)。管の外径と文字高さの大きい方
    public static func riserSymbolRadius(_ attrs: PipeAttributes) -> Double {
        max(attrs.outerDiameter / 2, attrs.textHeight * 0.45)
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

    /// 複線レイアウト(平面図)。ランごとに外形線を作り、折れ点はマイター、
    /// 折れ角が急でマイターが伸びすぎる場合(>3×半径)はベベル(面取り)に落とす。
    /// 立管の付け根には水平側にだけ継手ボックスを置く
    public static func doubleLineLayout(points: [Vec3], attrs: PipeAttributes)
        -> PipeDoubleLineLayout? {
        guard points.count >= 2, attrs.outerDiameter > 1e-9 else { return nil }
        let r = attrs.outerDiameter / 2
        let dims = attrs.effectiveFittingDims
        let rf = max(dims.socketOD / 2, r * 1.05)
        let reach = dims.elbow90A
        var runsOut: [(left: [Vec2], right: [Vec2], center: [Vec2])] = []
        var boxes: [[Vec2]] = []
        var caps: [(Vec2, Vec2)] = []
        let runs = planRuns(points: points)
        guard !runs.isEmpty else { return nil }

        for run in runs {
            let pts = run.map(\.xy)
            let n = pts.count
            var dirs: [Vec2] = []
            var normals: [Vec2] = []
            for i in 0..<(n - 1) {
                let d = pts[i + 1] - pts[i]
                let len = d.length
                let u = len > 1e-9 ? d * (1 / len) : Vec2(1, 0)
                dirs.append(u)
                normals.append(Vec2(-u.y, u.x))
            }
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
                    // 平面折れ点のエルボ(前後2枚)
                    if attrs.autoFittings {
                        let d1 = pts[i] - pts[i - 1]
                        let d2 = pts[i + 1] - pts[i]
                        let a1 = atan2(d1.y, d1.x)
                        let a2 = atan2(d2.y, d2.x)
                        var turn = a2 - a1
                        while turn > .pi { turn -= 2 * .pi }
                        while turn < -.pi { turn += 2 * .pi }
                        if abs(turn) * 180 / .pi > 2 {
                            let u1 = dirs[i - 1], nn1 = normals[i - 1]
                            let back = pts[i] - u1 * min(reach, d1.length)
                            boxes.append([back + nn1 * rf, pts[i] + nn1 * rf,
                                          pts[i] - nn1 * rf, back - nn1 * rf])
                            let u2 = dirs[i], nn2 = normals[i]
                            let fwd = pts[i] + u2 * min(reach, d2.length)
                            boxes.append([pts[i] + nn2 * rf, fwd + nn2 * rf,
                                          fwd - nn2 * rf, pts[i] - nn2 * rf])
                        }
                    }
                }
            }
            left.append(pts[n - 1] + normals[n - 2] * r)
            right.append(pts[n - 1] - normals[n - 2] * r)
            caps.append((left[0], right[0]))
            caps.append((left[left.count - 1], right[right.count - 1]))
            runsOut.append((left, right, pts))

            // 立管の付け根(ランの端が立管に接する)には水平側の受口を1枚
            if attrs.autoFittings, n >= 2 {
                let firstIdx = points.firstIndex(where: { $0 == run[0] }) ?? 0
                let lastIdx = points.firstIndex(where: { $0 == run[n - 1] }) ?? (points.count - 1)
                // ラン始点の直前が立管なら(平面同一点かつ高さ違い)
                if firstIdx > 0, points[firstIdx - 1].xy.distance(to: pts[0]) <= planEpsilon,
                   abs(points[firstIdx - 1].z - run[0].z) > 0.5 {
                    let u = dirs[0], nn = normals[0]
                    let fwd = pts[0] + u * min(reach, pts[1].distance(to: pts[0]))
                    boxes.append([pts[0] + nn * rf, fwd + nn * rf, fwd - nn * rf, pts[0] - nn * rf])
                }
                // ラン終点の直後が立管なら(平面同一点かつ高さ違い)
                if lastIdx < points.count - 1,
                   points[lastIdx + 1].xy.distance(to: pts[n - 1]) <= planEpsilon,
                   abs(points[lastIdx + 1].z - run[n - 1].z) > 0.5 {
                    let u = dirs[n - 2], nn = normals[n - 2]
                    let back = pts[n - 1] - u * min(reach, pts[n - 1].distance(to: pts[n - 2]))
                    boxes.append([back + nn * rf, pts[n - 1] + nn * rf,
                                  pts[n - 1] - nn * rf, back - nn * rf])
                }
            }
        }
        return PipeDoubleLineLayout(runs: runsOut, fittingBoxes: boxes, endCaps: caps)
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
