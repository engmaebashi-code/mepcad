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

    /// エルボの芯半径(内R = W/2)
    public static func elbowRadius(width w: Double) -> Double { w }

    /// ホッパー分岐の広がり(片側)
    public static func hopperFlare(branchWidth w: Double) -> Double { min(w / 2, 150) }

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
        }
        func endJoint(at p: Vec3, axis d: Vec2) -> EndJoint {
            var j = EndJoint()
            for jn in junctions where jn.position.distance(to: p.xy) <= tol && abs(jn.z - p.z) <= tol {
                switch jn.kind {
                case .teeBranch(let host, _, let vertical):
                    guard !vertical, jn.hostOD > 0 else { continue }
                    let sinb = max(abs(d.x * host.y - d.y * host.x), 0.3)
                    j.trim = max(j.trim, jn.hostOD / 2 / sinb)
                    j.open = true
                    if spec.hopperBranch { j.flare = hopperFlare(branchWidth: w) }
                case .reducer(_, let otherOD, _, _):
                    guard otherOD < w - 0.01 else { continue }
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

            // 曲がり: 角・丸・フレキは芯半径=幅、キャンバスは曲げない
            let radius = spec.shape == .canvas ? 0 : elbowRadius(width: w)
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
            if startJoint.flare > 0 {
                let nL = Vec2(-d0.y, d0.x)
                flare(&left, atStart: true, outward: nL, axis: d0, h: startJoint.flare)
                flare(&right, atStart: true, outward: Vec2(-nL.x, -nL.y), axis: d0, h: startJoint.flare)
            }
            if endJointInfo.flare > 0 {
                // 終点では進行方向が逆なので左壁の外側は −perp(d1)
                let nL = Vec2(-d1.y, d1.x)
                flare(&left, atStart: false, outward: Vec2(-nL.x, -nL.y), axis: d1, h: endJointInfo.flare)
                flare(&right, atStart: false, outward: nL, axis: d1, h: endJointInfo.flare)
            }

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
                var openHalf = bod / 2
                if branchKind == "H" { openHalf += hopperFlare(branchWidth: bod) }
                let a = pw - along * openHalf, b = pw + along * openHalf
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
