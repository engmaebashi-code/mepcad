import Foundation

// MARK: - ダクトの平面ジオメトリ M9.0
//
// ダクトは配管エンティティ(3D芯線)に DuctSpec を付けたもの。複線幅=平面幅(角W・丸D)。
// 配管と違って継手部品を置かず、壁の線そのものを加工して部品を表す:
// - エルボ: 芯半径=平面幅(内R=W/2・外R=1.5W)の弧。両端に継目の線
// - 分岐(枝側): 端を本ダクトの壁で止める。ホッパーなら45°で広げる
// - 分岐(本側): 枝の幅ぶん壁を開ける
// - 変形(突き合わせで幅が違う): 太い側の端を片側30°で細い幅へ絞る
// - フレキ: 壁を波線に(曲がりは芯半径=D)
// - キャンバス: 壁の間にジグザグ
// 芯線は描かない(ダクト図の慣例)

public enum DuctGeometry {

    /// エルボの芯半径(空気調和・給排水設備 施工標準 第4版):
    /// 角ダクト W≤250: 内R=W(芯1.5W)、W≥300: 内R=W/2(芯W)。
    /// 丸ダクト φ250以下(プレスベンド): R=1.0D、φ275以上(セクションベンド): R=1.5D
    public static func elbowRadius(width w: Double) -> Double { w <= 250 ? 1.5 * w : w }
    public static func elbowRadius(spec: DuctSpec, width w: Double) -> Double {
        if spec.isRound { return w <= 250 ? w : 1.5 * w }
        return elbowRadius(width: w)
    }

    /// ホッパー分岐の広がり(片側)
    public static func hopperFlare(branchWidth w: Double) -> Double { min(w / 2, 150) }
    /// 片テーパ付き直付け分岐の取出し: W3 = W2 + 150、θ=45°(施工標準)。上流側だけ広げる
    public static let taperFlare: Double = 150
    /// チャンバー分岐の箱: ダクトの外側へ出る余裕(片側)
    public static let chamberMargin: Double = 100

    /// 本ダクト側の開口の広がり(枝側の印から): 片側ずつ(上流側, 下流側)
    static func openingExtra(branchKind: String, branchWidth: Double) -> (upstream: Double, downstream: Double) {
        switch branchKind {
        case "H": let h = hopperFlare(branchWidth: branchWidth); return (h, h)
        case "P": return (taperFlare, 0)
        case "C": return (chamberMargin, chamberMargin)
        default: return (0, 0)
        }
    }

    /// 変形(レジューサ)の長さ: 片側30°の絞り
    public static func transitionLength(from w1: Double, to w2: Double) -> Double {
        max(abs(w1 - w2) / 2 / tan(Double.pi / 6), 50)
    }

    /// フレキの波: 振幅と周期(直径比例)
    public static func flexWave(diameter d: Double) -> (amplitude: Double, period: Double) {
        (max(d * 0.08, 8), max(d * 0.5, 40))
    }

    /// キャンバスのジグザグのピッチ
    public static func canvasPitch(width w: Double) -> Double { max(w / 3, 50) }

    // MARK: レイアウト

    public static func layout(points: [Vec3], attrs: PipeAttributes,
                              junctions: [PipeJunction]) -> PipeDoubleLineLayout? {
        guard let spec = attrs.duct, points.count >= 2 else { return nil }
        let w = max(attrs.outerDiameter, 1)
        let half = w / 2
        let tol = PipeNetwork.joinTolerance
        var runsOut: [(left: [Vec2], right: [Vec2], center: [Vec2])] = []
        var parts: [PipeFittingShape.Part] = []
        var caps: [(Vec2, Vec2)] = []

        /// 端(始点/終点)に付く接続: 枝として本ダクトへ / 変形(この側が太い)
        struct EndJoint {
            var trim: Double = 0
            var flare: Double = 0          // ホッパーの広がり(片側)
            var transitionTo: Double? = nil // 変形の相手の幅
            var open = false               // 端を閉じない(分岐で本ダクトに開く)
            /// 本ダクトの壁の線(枝の壁の端をここへ揃える): 通過点と方向
            var hostWall: (point: Vec2, dir: Vec2)? = nil
            /// 片テーパ: 上流側の壁だけ広げる。hostUpstream=本ダクトの上流方向
            var taperUpstreamOnly = false
            var hostUpstream = Vec2(0, 0)
        }
        /// p=端の位置、d=端から内側へ向かう枝の軸方向
        func endJoint(at p: Vec3, axis d: Vec2) -> EndJoint {
            var j = EndJoint()
            for jn in junctions where abs(jn.z - p.z) <= tol {
                switch jn.kind {
                case .teeBranch(let host, _, let vertical):
                    // 枝の端は本ダクトの芯線上か、壁の内側(M9.1: 壁へスナップして描いた場合)
                    guard !vertical, jn.hostOD > 0,
                          jn.position.distance(to: p.xy) <= jn.hostOD / 2 + tol else { continue }
                    let hostDir = unit(host)
                    // 本ダクトの法線を枝側(軸の向き)へ向ける
                    var nSide = Vec2(-hostDir.y, hostDir.x)
                    if nSide.x * d.x + nSide.y * d.y < 0 { nSide = Vec2(-nSide.x, -nSide.y) }
                    let cosb = max(nSide.x * d.x + nSide.y * d.y, 0.3)      // 軸と法線の余弦(直角なら1)
                    let depth = (p.xy - jn.position).x * nSide.x + (p.xy - jn.position).y * nSide.y
                    // 端から本ダクトの壁までの軸方向距離(端が芯線上なら hostOD/2/cosb)。
                    // チャンバー分岐: 枝はチャンバーの箱の縁で止まる(壁より margin 外側)
                    let wallOffset = jn.hostOD / 2 + (spec.branchStyle == .chamber ? chamberMargin : 0)
                    j.trim = max(j.trim, (wallOffset - depth) / cosb)
                    j.open = true
                    j.hostWall = (jn.position + nSide * wallOffset, hostDir)
                    switch spec.branchStyle {
                    case .hopper: j.flare = hopperFlare(branchWidth: w)
                    case .taper:
                        // 上流側(本ダクトの作図方向の手前側)の壁だけ広げる。どちらの壁かは後で決める
                        j.flare = taperFlare
                        j.taperUpstreamOnly = true
                        j.hostUpstream = Vec2(-hostDir.x, -hostDir.y)
                    default: break
                    }
                case .reducer(_, let otherOD, _, _):
                    guard jn.position.distance(to: p.xy) <= tol, otherOD < w - 0.01 else { continue }
                    j.trim = max(j.trim, transitionLength(from: w, to: otherOD))
                    j.transitionTo = otherOD
                    j.open = true
                default:
                    continue
                }
            }
            return j
        }

        let runs = PipeGeometry.planRuns(points: points)
        guard !runs.isEmpty else { return nil }
        for (ri, run) in runs.enumerated() {
            var pts = run.map(\.xy)
            let n = pts.count
            guard n >= 2 else { continue }
            // 立管の付け根判定(ランの両端)
            let firstIdx = points.firstIndex(where: { $0 == run[0] }) ?? 0
            let lastIdx = points.firstIndex(where: { $0 == run[n - 1] }) ?? (points.count - 1)
            let riserAtStart = firstIdx > 0
                && points[firstIdx - 1].xy.distance(to: pts[0]) <= PipeGeometry.planEpsilon
                && abs(points[firstIdx - 1].z - run[0].z) > 0.5
            let riserAtEnd = lastIdx < points.count - 1
                && points[lastIdx + 1].xy.distance(to: pts[n - 1]) <= PipeGeometry.planEpsilon
                && abs(points[lastIdx + 1].z - run[n - 1].z) > 0.5

            // 端の接続(この折れ線の始点・終点だけが相手に付く)
            let d0 = unit(pts[1] - pts[0])
            let d1 = unit(pts[n - 2] - pts[n - 1])
            let startJoint = ri == 0 && !riserAtStart ? endJoint(at: run[0], axis: d0) : EndJoint()
            let endJointInfo = ri == runs.count - 1 && !riserAtEnd ? endJoint(at: run[n - 1], axis: d1) : EndJoint()
            let originalStart = pts[0], originalEnd = pts[n - 1]
            if startJoint.trim > 0, pts[0].distance(to: pts[1]) > startJoint.trim + 1 {
                pts[0] = pts[0] + d0 * startJoint.trim
            }
            if endJointInfo.trim > 0, pts[n - 1].distance(to: pts[n - 2]) > endJointInfo.trim + 1 {
                pts[n - 1] = pts[n - 1] + d1 * endJointInfo.trim
            }
            // 壁の線を書き直すときに「切り詰め後の芯の端」から正確に壁へ寄せる(snapToHostWall)

            // 曲がり: 角・丸・フレキは芯半径=幅、キャンバスは曲げない
            let radius = spec.shape == .canvas ? 0 : elbowRadius(spec: spec, width: w)
            let pieces = PipeBend.pieces(pts, radius: radius)
            var left = PipeBend.polyline(pieces, offset: half)
            var right = PipeBend.polyline(pieces, offset: -half)
            guard left.count >= 2, right.count >= 2 else { continue }

            // エルボの継目(弧の両端に幅いっぱいの線)。フレキは出さない
            if spec.shape == .rect || spec.shape == .round {
                for piece in pieces {
                    if case .arc(let c, let r, let start, let sweep) = piece {
                        for a in [start, start + sweep] {
                            let u = Vec2(cos(a), sin(a))
                            parts.append(.polyline([c + u * (r - half), c + u * (r + half)]))
                        }
                    }
                }
            }

            // 分岐の枝側: 壁の端を本ダクトの壁の線に正確に揃える(斜め分岐でも隙間・食い込みが出ない)
            func snapToHostWall(_ wall: inout [Vec2], atStart: Bool, axis d: Vec2, hostWall: (point: Vec2, dir: Vec2)) {
                guard wall.count >= 2 else { return }
                let idx = atStart ? 0 : wall.count - 1
                let p = wall[idx]
                // 壁の端から軸方向(内側→端は -d)へ進んで本ダクトの壁の線に当たる点
                let nH = Vec2(-hostWall.dir.y, hostWall.dir.x)
                let den = d.x * nH.x + d.y * nH.y
                guard abs(den) > 1e-9 else { return }
                let t = ((hostWall.point - p).x * nH.x + (hostWall.point - p).y * nH.y) / den
                guard abs(t) < w * 2 else { return }
                wall[idx] = p + d * t
            }
            if let hw = startJoint.hostWall {
                snapToHostWall(&left, atStart: true, axis: d0, hostWall: hw)
                snapToHostWall(&right, atStart: true, axis: d0, hostWall: hw)
            }
            if let hw = endJointInfo.hostWall {
                snapToHostWall(&left, atStart: false, axis: d1, hostWall: hw)
                snapToHostWall(&right, atStart: false, axis: d1, hostWall: hw)
            }

            // ホッパー: 端の壁を外へ45°で広げる
            func flare(_ wall: inout [Vec2], atStart: Bool, outward: Vec2, axis d: Vec2, h: Double) {
                guard h > 0, wall.count >= 2 else { return }
                if atStart {
                    let end = wall[0]
                    wall[0] = end + outward * h
                    wall.insert(end + d * h, at: 1)
                } else {
                    let end = wall[wall.count - 1]
                    wall[wall.count - 1] = end + outward * h
                    wall.insert(end + d * h, at: wall.count - 1)
                }
            }
            /// 両壁(または片テーパなら上流側の壁だけ)を広げる
            func applyFlare(_ j: EndJoint, atStart: Bool, axis d: Vec2) {
                guard j.flare > 0 else { return }
                // 左壁の外側: 始点では +perp(d)、終点では進行方向が逆なので −perp(d)
                let nL = Vec2(-d.y, d.x)
                let leftOut = atStart ? nL : Vec2(-nL.x, -nL.y)
                let rightOut = Vec2(-leftOut.x, -leftOut.y)
                var doLeft = true, doRight = true
                if j.taperUpstreamOnly {
                    // 上流側の壁 = 外向きが本ダクトの上流方向を向いている方
                    let lu = leftOut.x * j.hostUpstream.x + leftOut.y * j.hostUpstream.y
                    doLeft = lu > 0
                    doRight = !doLeft
                }
                if doLeft { flare(&left, atStart: atStart, outward: leftOut, axis: d, h: j.flare) }
                if doRight { flare(&right, atStart: atStart, outward: rightOut, axis: d, h: j.flare) }
            }
            applyFlare(startJoint, atStart: true, axis: d0)
            applyFlare(endJointInfo, atStart: false, axis: d1)

            // 変形(この側が太い): 絞りの斜線2本と、太い側の終わりの線。
            // travel=折れ線の進行方向(左壁はその左側)
            func transition(at joint: Vec2, travel: Vec2, wallStartL: Vec2, wallStartR: Vec2, to w2: Double) {
                let nL = Vec2(-travel.y, travel.x)
                parts.append(.polyline([wallStartL, joint + nL * (w2 / 2)]))
                parts.append(.polyline([wallStartR, joint - nL * (w2 / 2)]))
                parts.append(.polyline([wallStartL, wallStartR]))
            }
            if let w2 = startJoint.transitionTo {
                transition(at: originalStart, travel: d0, wallStartL: left[0], wallStartR: right[0], to: w2)
            }
            if let w2 = endJointInfo.transitionTo {
                transition(at: originalEnd, travel: Vec2(-d1.x, -d1.y), wallStartL: left[left.count - 1],
                           wallStartR: right[right.count - 1], to: w2)
            }

            // 端の閉じ線(自由端のみ)
            if !riserAtStart, !startJoint.open { caps.append((left[0], right[0])) }
            if !riserAtEnd, !endJointInfo.open { caps.append((left[left.count - 1], right[right.count - 1])) }

            // フレキ: 壁を波線に
            if spec.shape == .flex {
                let wave = flexWave(diameter: w)
                left = wavy(left, amplitude: wave.amplitude, period: wave.period)
                right = wavy(right, amplitude: wave.amplitude, period: wave.period)
            }
            // キャンバス: 壁の間のジグザグ
            if spec.shape == .canvas {
                parts.append(.polyline(zigzag(left: left, right: right, pitch: canvasPitch(width: w))))
            }

            // 本ダクト側: 枝の幅ぶん壁を開ける(その壁だけ2本に割る)
            var leftPieces = [left], rightPieces = [right]
            for jn in junctions {
                guard case .tee(let bdir, let bod, _, _, let along, let vertical, let branchKind) = jn.kind,
                      !vertical else { continue }
                let side = along.x * bdir.y - along.y * bdir.x
                let nSide = Vec2(-along.y, along.x) * (side >= 0 ? 1 : -1)
                let pw = jn.position + nSide * half
                // 枝の両壁(軸から±bod/2)が本ダクトの壁の線と交わる位置(本ダクト方向の座標)。
                // 直角なら ±bod/2、斜めならその分広がる(M9.1)
                let nb = Vec2(-bdir.y, bdir.x)
                let dn = bdir.x * nSide.x + bdir.y * nSide.y
                guard dn > 0.2 else { continue }
                var ss: [Double] = []
                for sign in [1.0, -1.0] {
                    let t = (half - sign * (bod / 2) * (nb.x * nSide.x + nb.y * nSide.y)) / dn
                    let s = t * (bdir.x * along.x + bdir.y * along.y) + sign * (bod / 2) * (nb.x * along.x + nb.y * along.y)
                    ss.append(s)
                }
                let extra = openingExtra(branchKind: branchKind, branchWidth: bod)
                let s0 = ss.min()! - extra.upstream, s1 = ss.max()! + extra.downstream
                if branchKind == "C" {
                    // チャンバー分岐: 分岐点に箱(枝の幅+余裕 × ダクト幅+余裕)。両壁とも箱の中で切る
                    let cw = half + chamberMargin
                    let a = jn.position + along * s0, b = jn.position + along * s1
                    parts.append(.polygon([a + nSide * cw, b + nSide * cw, b - nSide * cw, a - nSide * cw]))
                    let nL = Vec2(-along.y, along.x)             // 本ダクトの左壁の側
                    leftPieces = leftPieces.flatMap {
                        PipeSymbols.cutRun($0, from: a + nL * half, to: b + nL * half, near: jn.position + nL * half)
                    }
                    rightPieces = rightPieces.flatMap {
                        PipeSymbols.cutRun($0, from: a - nL * half, to: b - nL * half, near: jn.position - nL * half)
                    }
                    continue
                }
                let a = pw + along * s0, b = pw + along * s1
                if branchKind == "S" {
                    // 割込み分岐(本ダクトを絞る): 枝の下流側から先、枝側の壁が枝の幅ぶん内側へ入る。
                    // 枝の下流側の壁を本ダクトの中まで延ばして絞りの段差にする
                    let inset = nSide * (-bod)
                    if side >= 0 {
                        var pieces: [[Vec2]] = []
                        for piece in leftPieces {
                            let cut = PipeSymbols.cutRun(piece, from: a, to: b, near: pw)
                            for (k, part) in cut.enumerated() {
                                if cut.count >= 2, k == cut.count - 1, let f = part.first, f.distance(to: b) <= tol {
                                    pieces.append([b, b + inset] + part.dropFirst().map { $0 + inset })
                                } else {
                                    pieces.append(part)
                                }
                            }
                        }
                        leftPieces = pieces
                    } else {
                        var pieces: [[Vec2]] = []
                        for piece in rightPieces {
                            let cut = PipeSymbols.cutRun(piece, from: a, to: b, near: pw)
                            for (k, part) in cut.enumerated() {
                                if cut.count >= 2, k == cut.count - 1, let f = part.first, f.distance(to: b) <= tol {
                                    pieces.append([b, b + inset] + part.dropFirst().map { $0 + inset })
                                } else {
                                    pieces.append(part)
                                }
                            }
                        }
                        rightPieces = pieces
                    }
                    continue
                }
                if side >= 0 {
                    leftPieces = leftPieces.flatMap { PipeSymbols.cutRun($0, from: a, to: b, near: pw) }
                } else {
                    rightPieces = rightPieces.flatMap { PipeSymbols.cutRun($0, from: a, to: b, near: pw) }
                }
            }
            runsOut.append((leftPieces[0], rightPieces[0], []))
            for extra in leftPieces.dropFirst() { runsOut.append((extra, [], [])) }
            for extra in rightPieces.dropFirst() { runsOut.append(([], extra, [])) }
        }
        let fittings = parts.isEmpty ? [] : [PipeFittingShape(parts: parts)]
        return PipeDoubleLineLayout(runs: runsOut, fittings: fittings, endCaps: caps)
    }

    // MARK: 補助

    static func unit(_ v: Vec2) -> Vec2 {
        let l = v.length
        return l > 1e-9 ? v * (1 / l) : Vec2(1, 0)
    }

    /// 折れ線を、進行方向に直交する正弦波で揺らした折れ線にする(フレキの壁)
    static func wavy(_ pts: [Vec2], amplitude: Double, period: Double) -> [Vec2] {
        guard pts.count >= 2, period > 1e-6 else { return pts }
        var lengths: [Double] = []
        var total = 0.0
        for i in 0..<(pts.count - 1) {
            let l = pts[i].distance(to: pts[i + 1])
            lengths.append(l)
            total += l
        }
        guard total > period / 4 else { return pts }
        let step = period / 8
        var out: [Vec2] = []
        var seg = 0
        var segStart = 0.0
        var t = 0.0
        while t <= total + 1e-9 {
            while seg < lengths.count - 1, t > segStart + lengths[seg] { segStart += lengths[seg]; seg += 1 }
            let d = unit(pts[seg + 1] - pts[seg])
            let p = pts[seg] + d * (t - segStart)
            let nrm = Vec2(-d.y, d.x)
            out.append(p + nrm * (amplitude * sin(2 * Double.pi * t / period)))
            t += step
        }
        if let last = out.last, last.distance(to: pts[pts.count - 1]) > 1e-9 { out.append(pts[pts.count - 1]) }
        return out
    }

    /// 左右の壁の間を往復するジグザグ(キャンバス)
    static func zigzag(left: [Vec2], right: [Vec2], pitch: Double) -> [Vec2] {
        guard let l0 = left.first, let l1 = left.last, let r0 = right.first, let r1 = right.last else { return [] }
        let len = l0.distance(to: l1)
        guard len > 1e-6, pitch > 1e-6 else { return [] }
        let n = max(Int((len / pitch).rounded()), 1)
        var out: [Vec2] = []
        for k in 0...n {
            let t = Double(k) / Double(n)
            let onLeft = k % 2 == 0
            out.append(onLeft ? l0 + (l1 - l0) * t : r0 + (r1 - r0) * t)
        }
        return out
    }
}
