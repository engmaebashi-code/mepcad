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

    /// 立管点に接する水平脚の方向すべて(手前・先。最大2)。両側にティックを出すのに使う
    public static func riserLeads(points: [Vec3], riserIndex: Int) -> [Vec2] {
        var k = -1
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if a.xy.distance(to: b.xy) <= PipeGeometry.planEpsilon, abs(b.z - a.z) > 0.5 {
                k += 1
                if k == riserIndex {
                    var out: [Vec2] = []
                    if i > 0 {
                        let d = points[i - 1].xy - a.xy
                        if d.length > PipeGeometry.planEpsilon { out.append(d * (1 / d.length)) }
                    }
                    if i + 2 < points.count {
                        let d = points[i + 2].xy - b.xy
                        if d.length > PipeGeometry.planEpsilon { out.append(d * (1 / d.length)) }
                    }
                    return out
                }
            }
        }
        return []
    }

    /// 「))」記号: 傾いた受口(45°立ち下がり/上がり)の縁。方向dirへ膨らむ円弧2本(半径0.6u)
    static func tiltMarks(at p: Vec2, dir: Vec2, unit u: Double) -> [PipeSymbolElement] {
        let base = atan2(dir.y, dir.x)
        let spread = Double.pi * 55 / 180
        return [-0.45, -0.05].map { (k: Double) -> PipeSymbolElement in
            .arc(p + dir * (k * u), 0.6 * u, base - spread, base + spread)
        }
    }

    /// 折れ点の記号ジオメトリ(単線)。tangent=折れ点から丸みの接点まで、radius=丸み半径、
    /// tick=折れ点からティックまで。DL: 接点=ティック=u、R=u/tan(θ/2)。
    /// LL(大曲): R=4u、ティックは接点のu先(FILDERの見え方に合わせた比率)
    public static func cornerGeometry(unit u: Double, turn: Double, longRadius: Bool,
                                      len1: Double, len2: Double) -> (tangent: Double, radius: Double, tick: Double) {
        let half = max(abs(turn) / 2, 0.02)
        let minLeg = min(len1, len2)
        if longRadius {
            var radius = 4 * u
            var tangent = radius * tan(half)
            // 通常長の脚では規定半径を維持する。接点距離が脚長の80%を超える
            // 極端な短区間だけ、脚長の40%へ縮めて隣接継手との重なりを避ける。
            if tangent > minLeg * 0.8 {
                tangent = minLeg * 0.4
                radius = tangent / tan(half)
                return (tangent, radius, min(tangent + u, minLeg * 0.5))
            }
            return (tangent, radius, tangent + u)
        }
        let tangent = min(u, minLeg * 0.5)
        return (tangent, tangent / tan(half), tangent)
    }

    /// 単線の管体の折れ線(描画用)。排水系(継手あり)は折れ点で丸みの接点まで切り詰めて
    /// 角を落とす(丸みの円弧はelementsが出す)。給水系は角のまま
    public static func singleLineRuns(points: [Vec3], attrs: PipeAttributes,
                                      junctions: [PipeJunction] = []) -> [[Vec2]] {
        var runs = PipeGeometry.planRuns(points: points).map { $0.map(\.xy) }
        // 可撓管: 折れ点を曲げ半径で丸めた芯線(継手の記号は出ない)。M7.9
        if attrs.isBent {
            return runs.map { PipeBend.centerline($0, radius: attrs.bendRadius) }
        }
        guard attrs.autoFittings, isDrainStyle(attrs) else { return runs }
        let u = unit(attrs)
        // 大曲Y(LT)の本管に取り付く枝端: 本管手前0.5uで切る(そこから45°のスイープを記号で描く)
        for j in junctions {
            guard case .teeBranch(_, let ll, let vertical) = j.kind, ll, !vertical else { continue }
            for ri in runs.indices where runs[ri].count >= 2 {
                let n = runs[ri].count
                if runs[ri][n - 1].distance(to: j.position) <= PipeNetwork.joinTolerance {
                    let d = runs[ri][n - 1] - runs[ri][n - 2]
                    let l = d.length
                    if l > u { runs[ri][n - 1] = runs[ri][n - 1] - d * (0.5 * u / l) }
                } else if runs[ri][0].distance(to: j.position) <= PipeNetwork.joinTolerance {
                    let d = runs[ri][0] - runs[ri][1]
                    let l = d.length
                    if l > u { runs[ri][0] = runs[ri][0] - d * (0.5 * u / l) }
                }
            }
        }
        var out: [[Vec2]] = []
        for pts in runs {
            guard pts.count >= 3 else { out.append(pts); continue }
            var current: [Vec2] = [pts[0]]
            for i in 1..<(pts.count - 1) {
                let d1 = pts[i] - pts[i - 1]
                let d2 = pts[i + 1] - pts[i]
                let l1 = d1.length, l2 = d2.length
                guard l1 > 1e-9, l2 > 1e-9 else { current.append(pts[i]); continue }
                let u1 = d1 * (1 / l1), u2 = d2 * (1 / l2)
                var turn = atan2(u2.y, u2.x) - atan2(u1.y, u1.x)
                while turn > .pi { turn -= 2 * .pi }
                while turn < -.pi { turn += 2 * .pi }
                let deg = abs(turn) * 180 / .pi
                guard deg > 2, deg < 175 else { current.append(pts[i]); continue }
                let g = cornerGeometry(unit: u, turn: turn, longRadius: attrs.longRadius, len1: l1, len2: l2)
                current.append(pts[i] - u1 * g.tangent)
                out.append(current)
                current = [pts[i] + u2 * g.tangent]
            }
            current.append(pts[pts.count - 1])
            out.append(current)
        }
        return out
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

        // 折れ点(平面)ごとのエルボ記号(可撓管は曲げなので出さない。M7.9)
        for run in PipeGeometry.planRuns(points: points) where !attrs.isBent {
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
                let sloped1 = PipeGeometry.isSloped(run[i - 1], run[i])
                let sloped2 = PipeGeometry.isSloped(run[i], run[i + 1])
                if deg <= 2 {
                    // 平面では直進で片脚が勾配 → 45°立ち下がり/上がり: 水平脚にティック+「))」(作図方向へ)
                    guard sloped1 != sloped2 else { continue }
                    let horiz = sloped2 ? Vec2(-u1.x, -u1.y) : u2   // 水平脚の方向(折れ点から)
                    tick(at: pts[i] + horiz * min(u, (sloped2 ? l1 : l2) * 0.5), along: horiz)
                    out += tiltMarks(at: pts[i], dir: u2, unit: u)
                    continue
                }
                guard deg < 175 else { continue }
                if sloped1 != sloped2 {
                    // ひねり(折れ点の片脚が勾配): 勾配脚側にも「))」
                    out += tiltMarks(at: pts[i], dir: u2, unit: u)
                }
                let g = cornerGeometry(unit: u, turn: turn, longRadius: drain && attrs.longRadius,
                                       len1: l1, len2: l2)
                tick(at: pts[i] - u1 * g.tick, along: u1)
                tick(at: pts[i] + u2 * g.tick, along: u2)
                if drain {
                    // 脚に接する丸み: 接点back/fwdを結ぶ円弧(半径g.radius)。管体は接点で切ってある
                    let back = pts[i] - u1 * g.tangent
                    let fwd = pts[i] + u2 * g.tangent
                    let n1 = Vec2(-u1.y, u1.x) * (turn > 0 ? 1 : -1)
                    let center = back + n1 * g.radius
                    let s = atan2(back.y - center.y, back.x - center.x)
                    let e = atan2(fwd.y - center.y, fwd.x - center.x)
                    if turn > 0 {
                        out.append(.arc(center, g.radius, s, e))
                    } else {
                        out.append(.arc(center, g.radius, e, s))
                    }
                }
            }
        }

        // 立管: 接する水平脚それぞれのuの位置にティック(円はRenderer)。
        // 立てチーズで本管に取り付く枝の立管は本管側の継手が兼ねるので出さない
        let suppressed: [Vec2] = junctions.compactMap {
            if case .teeBranch(_, _, let v) = $0.kind, v { return $0.position }
            return nil
        }
        for (ri, riser) in PipeGeometry.risers(points: points).enumerated() {
            if suppressed.contains(where: { $0.distance(to: riser.position) <= PipeNetwork.joinTolerance }) { continue }
            for toward in riserLeads(points: points, riserIndex: ri) {
                tick(at: riser.position + toward * u, along: toward)
            }
        }

        // ネットワーク由来(ティーズ・キャップ・レデューサ)
        for j in junctions {
            switch j.kind {
            case .tee(let bdir, _, _, _, let along, let vertical, let branchKind):
                // 枝の傾き(主管軸方向成分)。|cos|>0.5なら45°Y
                let c = bdir.x * along.x + bdir.y * along.y
                if vertical {
                    // 立てチーズ: 主管±uにティック、分岐点に直径uの円(閉)、枝uにティック
                    tick(at: j.position - along * u, along: along)
                    tick(at: j.position + along * u, along: along)
                    out.append(.circle(j.position, u / 2))
                    tick(at: j.position + bdir * u, along: bdir)
                } else if abs(c) <= 0.5 && drain && branchKind == "LT" {
                    // 大曲Y(LT): 主管ティック 上流-1.25u/下流+0.75u(下流=本管の作図方向)、
                    // 枝は主管上-0.5uから45°で枝軸上+0.5uへ、そのまま枝軸上uにティック
                    tick(at: j.position - along * (1.25 * u), along: along)
                    tick(at: j.position + along * (0.75 * u), along: along)
                    let start = j.position - along * (0.5 * u)
                    let knee = j.position + bdir * (0.5 * u)
                    out.append(.segment(start, knee))
                    tick(at: j.position + bdir * u, along: bdir)
                } else if abs(c) > 0.5 && drain && branchKind == "Y" {
                    // 45°Y: 主管ティック 上流側-0.75u/下流側+1.25u(枝は上流側へ傾いて付く→下流はその反対)、
                    // 枝は1.25u先に長さ0.8uのティック
                    let down = along * (c > 0 ? -1 : 1)
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
            case .teeBranch:
                break
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
