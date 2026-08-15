import Foundation

// MARK: - 単線表現の継手シンボル(FILDER準拠)M6.4
//
// 単線でも継手の位置に記号を出す(施工図の慣例):
// - 排水系(DV/HTDV): 継手の受口位置(折れ点からA寸法)に芯線と直交する短いティック、
//   折れ点は角を落として丸み(受口が見える表現)、ティーズは本管側にティック
// - 給水系(TS/HI/HT/SGPねじ込み): 継手位置に×印(ソケット・エルボ・ティーズ共通)
// - キャップ: ○の中に×(端部)、レデューサ: 「>」形(大径→小径)
// 記号の大きさは紙面上で一定に見えるよう文字高さ(textHeight)を基準にする

/// 単線シンボルの図形要素(平面)
public enum PipeSymbolElement: Equatable, Sendable {
    case segment(Vec2, Vec2)
    /// 円弧(中心, 半径, 開始角, 終了角 rad CCW)
    case arc(Vec2, Double, Double, Double)
    case circle(Vec2, Double)
}

public enum PipeSymbols {

    /// 排水系(受口ティック表現)かどうか
    public static func isDrainStyle(_ attrs: PipeAttributes) -> Bool {
        attrs.fittingSeries == "DV" || attrs.fittingSeries == "HTDV"
            || (attrs.fittingSeries.isEmpty && ["S", "W", "RW", "VT"].contains(attrs.usage))
    }

    /// ティックの半長さ(記号の大きさ。紙面上で一定に見せる)
    public static func tickHalf(_ attrs: PipeAttributes) -> Double {
        max(attrs.textHeight * 0.45, attrs.outerDiameter * 0.5)
    }

    /// 単線シンボル一式(折れ点エルボ+ネットワーク由来の継手)。autoFittings=falseなら空
    public static func elements(points: [Vec3], attrs: PipeAttributes,
                                junctions: [PipeJunction]) -> [PipeSymbolElement] {
        guard attrs.autoFittings, points.count >= 2 else { return [] }
        var out: [PipeSymbolElement] = []
        let dims = attrs.effectiveFittingDims
        let t = tickHalf(attrs)
        let drain = isDrainStyle(attrs)

        func tick(at p: Vec2, along u: Vec2) {
            let n = Vec2(-u.y, u.x)
            out.append(.segment(p + n * t, p - n * t))
        }
        func cross(at p: Vec2) {
            let d = t * 0.7
            out.append(.segment(Vec2(p.x - d, p.y - d), Vec2(p.x + d, p.y + d)))
            out.append(.segment(Vec2(p.x - d, p.y + d), Vec2(p.x + d, p.y - d)))
        }

        // 折れ点(平面)ごとのエルボ記号
        for run in PipeGeometry.planRuns(points: points) {
            let pts = run.map(\.xy)
            guard pts.count >= 3 else { continue }
            for i in 1..<(pts.count - 1) {
                let d1 = pts[i] - pts[i - 1]
                let d2 = pts[i + 1] - pts[i]
                let l1 = d1.length, l2 = d2.length
                guard l1 > 1e-9, l2 > 1e-9 else { continue }
                let u1 = d1 * (1 / l1)
                let u2 = d2 * (1 / l2)
                let a1 = atan2(u1.y, u1.x)
                let a2 = atan2(u2.y, u2.x)
                var turn = a2 - a1
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                let deg = abs(turn) * 180 / .pi
                guard deg > 2 else { continue }
                if drain {
                    // 受口位置(折れ点からA寸法)にティック×2。90°は丸みコーナーも
                    let a = deg > 60 ? dims.elbow90A : dims.elbow45A
                    let back = pts[i] - u1 * min(a, l1 * 0.5)
                    let fwd = pts[i] + u2 * min(a, l2 * 0.5)
                    tick(at: back, along: u1)
                    tick(at: fwd, along: u2)
                    if abs(deg - 90) < 2 {
                        // 角の丸み: 内側に半径a/2の円弧(back→fwdを結ぶ)
                        let r = min(a, l1 * 0.5, l2 * 0.5) * 0.5
                        let c1 = pts[i] - u1 * r
                        let c2 = pts[i] + u2 * r
                        // 円弧の中心は折れ点から内側へ(r,r)
                        let center = c1 + u2 * r
                        let s = atan2(c1.y - center.y, c1.x - center.x)
                        let e = atan2(c2.y - center.y, c2.x - center.x)
                        // 左折(turn>0)なら反時計、右折なら時計
                        if turn > 0 {
                            out.append(.arc(center, r, s, e))
                        } else {
                            out.append(.arc(center, r, e, s))
                        }
                    }
                } else {
                    cross(at: pts[i])
                }
            }
        }

        // 立管の付け根(水平→鉛直): 排水はティック、給水は×(記号は立上り○の脇)
        // → 立管記号自体が別途描かれるので、ここでは何もしない

        // ネットワーク由来(ティーズ・キャップ・レデューサ)
        for j in junctions {
            switch j.kind {
            case .tee(let bdir, _, _):
                if drain {
                    // 本管側: 分岐位置の両側A寸法にティック(受口)、枝管側にもティック
                    let along = Vec2(-bdir.y, bdir.x)
                    let a = dims.teeA
                    tick(at: j.position - along * a, along: along)
                    tick(at: j.position + along * a, along: along)
                    tick(at: j.position + bdir * a, along: bdir)
                } else {
                    cross(at: j.position)
                }
            case .cap(let dir):
                // ○の中に×(端部)
                let r = t * 0.8
                let c = j.position + dir * (r * 0.2)
                out.append(.circle(c, r))
                let d = r * 0.6
                out.append(.segment(Vec2(c.x - d, c.y - d), Vec2(c.x + d, c.y + d)))
                out.append(.segment(Vec2(c.x - d, c.y + d), Vec2(c.x + d, c.y - d)))
            case .reducer(let dir, _, _):
                // 「>」形: 大径側(内側)から小径側(dir方向)へすぼまる
                let n = Vec2(-dir.y, dir.x)
                let back = j.position - dir * (t * 1.2)
                let tip = j.position + dir * (t * 0.6)
                out.append(.segment(back + n * t, tip))
                out.append(.segment(back - n * t, tip))
            }
        }
        return out
    }
}
