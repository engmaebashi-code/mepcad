import Foundation

// MARK: - 単線表現の継手シンボル(FILDER準拠)M6.4 → M6.5で紙面mm基準に全面改訂
//
// 単線でも継手の位置に記号を出す(施工図の慣例)。記号は管サイズに依らず
// 紙面上で一定の大きさ(基準寸法u=attrs.effectiveSymbolSize。FILDER: 排水2.5mm・給水2.0mm)。
// - 排水系(DV/HTDV): 折れ点から各脚uの位置に直交ティック(受口)、90°/45°は脚に接する
//   丸み(90°: R=u、45°: R=u/tan22.5°)。ティーズはティック3本、45°YはY形
// - 給水系(TS/HI/HT/SGP): 同じ組立てで角は丸めない。レデューサは中抜き三角▷
// - 立上り: 管端手前uにティック+直径uの円(閉)。立下り: 管側60°が開いたC形
// - キャップ: ○の中に×
// 立上り/立下りの円はRenderer側(riserSymbolRadius=u/2)で描くので、ここではティックと
// C形の「開き方向」(riserLead)だけを提供する

/// 単線シンボルの図形要素(平面)
public enum PipeSymbolElement: Equatable, Sendable {
    case segment(Vec2, Vec2)
    /// 円弧(中心, 半径, 開始角, 終了角 rad CCW)
    case arc(Vec2, Double, Double, Double)
    case circle(Vec2, Double)
}

public enum PipeSymbols {

    /// 排水系(受口ティック+丸み表現)かどうか
    public static func isDrainStyle(_ attrs: PipeAttributes) -> Bool {
        attrs.fittingSeries == "DV" || attrs.fittingSeries == "HTDV"
            || (attrs.fittingSeries.isEmpty && ["S", "W", "RW", "VT"].contains(attrs.usage))
    }

    /// 基準寸法u(実寸mm)
    public static func unit(_ attrs: PipeAttributes) -> Double { attrs.effectiveSymbolSize }

    /// ティックの半長さ(=u/2)
    public static func tickHalf(_ attrs: PipeAttributes) -> Double { unit(attrs) / 2 }

    /// 立管の記号に付くティック位置と、立下りC形の開き方向。
    /// 戻り値: (立管点, 管の方向(単位・立管点→水平脚)) — 水平脚が無ければnil。
    /// riserIndexはrisers(points:)の順
    public static func riserLead(points: [Vec3], riserIndex: Int) -> (position: Vec2, toward: Vec2)? {
        var k = -1
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if a.xy.distance(to: b.xy) <= PipeGeometry.planEpsilon, abs(b.z - a.z) > 0.5 {
                k += 1
                if k == riserIndex {
                    // 手前の水平脚(優先)、無ければ先の水平脚
                    if i > 0 {
                        let d = points[i - 1].xy - a.xy
                        if d.length > PipeGeometry.planEpsilon { return (a.xy, d * (1 / d.length)) }
                    }
                    if i + 2 < points.count {
                        let d = points[i + 2].xy - b.xy
                        if d.length > PipeGeometry.planEpsilon { return (a.xy, d * (1 / d.length)) }
                    }
                    return nil
                }
            }
        }
        return nil
    }

    /// 単線シンボル一式(折れ点エルボ+ネットワーク由来の継手+立管のティック)。autoFittings=falseなら空
    public static func elements(points: [Vec3], attrs: PipeAttributes,
                                junctions: [PipeJunction]) -> [PipeSymbolElement] {
        guard attrs.autoFittings, points.count >= 2 else { return [] }
        var out: [PipeSymbolElement] = []
        let u = unit(attrs)
        let t = u / 2
        let drain = isDrainStyle(attrs)

        func tick(at p: Vec2, along dir: Vec2, half: Double = t) {
            let n = Vec2(-dir.y, dir.x)
            out.append(.segment(p + n * half, p - n * half))
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
                let u1 = d1 * (1 / l1)          // 進行方向(手前→折れ点)
                let u2 = d2 * (1 / l2)          // 進行方向(折れ点→先)
                let a1 = atan2(u1.y, u1.x)
                let a2 = atan2(u2.y, u2.x)
                var turn = a2 - a1
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                let deg = abs(turn) * 180 / .pi
                guard deg > 2, deg < 175 else { continue }
                let reach = min(u, l1 * 0.5, l2 * 0.5)
                let back = pts[i] - u1 * reach
                let fwd = pts[i] + u2 * reach
                tick(at: back, along: u1)
                tick(at: fwd, along: u2)
                if drain {
                    // 脚に接する丸み: back/fwdを結ぶ円弧。R = reach / tan(turn/2)
                    let half = abs(turn) / 2
                    guard half > 0.02 else { continue }
                    let rad = reach / tan(half)
                    // 中心: backから脚1に直交して内側(折れる側)へrad
                    let n1 = Vec2(-u1.y, u1.x) * (turn > 0 ? 1 : -1)
                    let center = back + n1 * rad
                    let s = atan2(back.y - center.y, back.x - center.x)
                    let e = atan2(fwd.y - center.y, fwd.x - center.x)
                    if turn > 0 {
                        out.append(.arc(center, rad, s, e))
                    } else {
                        out.append(.arc(center, rad, e, s))
                    }
                }
            }
        }

        // 立管: 手前uの位置にティック(円はRenderer)
        var ri = 0
        for _ in PipeGeometry.risers(points: points) {
            if let lead = riserLead(points: points, riserIndex: ri) {
                tick(at: lead.position + lead.toward * u, along: lead.toward)
            }
            ri += 1
        }

        // ネットワーク由来(ティーズ・キャップ・レデューサ)
        for j in junctions {
            switch j.kind {
            case .tee(let bdir, _, _, _, let along):
                // 枝の傾き(主管軸方向成分)。|cos|>0.5なら45°Y
                let c = bdir.x * along.x + bdir.y * along.y
                if abs(c) > 0.5 && drain {
                    // 45°Y: 主管ティック 上流側-0.75u/下流側+1.25u(下流=枝が傾く側)、
                    // 枝は1.25u先に長さ0.8uのティック
                    let down = along * (c > 0 ? 1 : -1)
                    tick(at: j.position - down * (0.75 * u), along: along)
                    tick(at: j.position + down * (1.25 * u), along: along)
                    tick(at: j.position + bdir * (1.25 * u), along: bdir, half: 0.4 * u)
                } else {
                    // T: 主管±u、枝u
                    tick(at: j.position - along * u, along: along)
                    tick(at: j.position + along * u, along: along)
                    tick(at: j.position + bdir * u, along: bdir)
                }
            case .cap(let dir):
                // ○の中に×(端部)
                let rr = t * 0.8
                let cc = j.position + dir * (rr * 0.2)
                out.append(.circle(cc, rr))
                let d = rr * 0.6
                out.append(.segment(Vec2(cc.x - d, cc.y - d), Vec2(cc.x + d, cc.y + d)))
                out.append(.segment(Vec2(cc.x - d, cc.y + d), Vec2(cc.x + d, cc.y - d)))
            case .reducer(let dir, _, _, _):
                // ▷: 大径側にティック(長さu)、その両端から小径側u先の頂点へ
                let n = Vec2(-dir.y, dir.x)
                let base = j.position - dir * (u * 0.5)
                let tip = base + dir * u
                out.append(.segment(base + n * t, base - n * t))
                out.append(.segment(base + n * t, tip))
                out.append(.segment(base - n * t, tip))
            }
        }
        return out
    }
}
