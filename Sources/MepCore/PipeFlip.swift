import Foundation

// MARK: - 継手反転 M7.8
//
// 継手の向きは図面データではなく配管の位置関係から決まる:
// - 本管の作図方向 = 流れ方向(下流)。LTのスイープ・単線記号の上下流はこれで決まる
// - 45°の枝(Y)は「枝管がどちらへ傾いて取り付いているか」で決まる
//   (実物のYは枝が上流側へ傾く。下流側へ傾けて描くと流れと逆向きのYになる)
//
// なので「継手を反転」は選んだ配管の役割に応じて:
// - 45°で取り付く枝管 → 枝管を本管に直交する線で鏡映して傾きを逆にする。
//   反対の端(器具側)を動かさずに済むならそちらを軸にする(継手が本管上を滑る)。
//   本管の区間から外れてしまうなら接続点を軸にする(器具側の端が動く)
// - 直角で取り付く枝管(DT/LT) → 枝側の印 branchReversed を切り替える(下流側が逆になる)
// - 本管(分岐を受けている側) → 作図方向を逆にする(そこに付く全部のLTの向きが変わる)
// - どこにも接続していない配管 → 作図方向を逆にする

public enum PipeFlip {

    public enum Outcome: Equatable, Sendable {
        /// 45°の枝管を鏡映した(aboutFarEnd=反対の端を軸にした→接続点が本管上を滑った)
        case mirroredBranch(aboutFarEnd: Bool)
        /// 直角の枝管: 下流側の印を切り替えた(nowReversed=切替後の値)
        case toggledBranch(nowReversed: Bool)
        /// 作図方向(流れ方向)を逆にした(branches=そこに付いている分岐の数)
        case reversedFlow(branches: Int)
    }

    /// 選んだ配管の継手の向きを反転した姿と、何をしたかを返す。配管でなければnil
    public static func flip(_ entity: Entity, in entities: [Entity]) -> (entity: Entity, outcome: Outcome)? {
        guard case .pipe(let points, var attrs) = entity.kind, points.count >= 2 else { return nil }
        let junctions = PipeNetwork.junctions(in: entities)[entity.id] ?? []
        let asBranch = junctions.compactMap { j -> (PipeJunction, Vec2, Bool)? in
            guard case .teeBranch(let host, _, let vertical) = j.kind else { return nil }
            return (j, host, vertical)
        }
        var updated = entity

        if let first = asBranch.first {
            let (j, host, vertical) = first
            // 端がどちらか(始点/終点)
            let atStart = points[0].xy.distance(to: j.position) <= PipeNetwork.joinTolerance
                && abs(points[0].z - j.z) <= PipeNetwork.joinTolerance
            let axis = PipeNetwork.outwardDirection(points: points, atStart: atStart) ?? host
            let cosb = abs(axis.x * host.x + axis.y * host.y)
            if !vertical, cosb > 0.3, asBranch.count == 1 {
                // 45°の枝: 本管に直交する線で鏡映
                let h = host * (1 / max(host.length, 1e-9))
                let farIndex = atStart ? points.count - 1 : 0
                let far = points[farIndex].xy
                func mirrored(about pivot: Vec2) -> [Vec3] {
                    points.map { p in
                        let v = p.xy - pivot
                        let along = v.x * h.x + v.y * h.y
                        return Vec3(pivot + v - h * (2 * along), z: p.z)
                    }
                }
                let byFar = mirrored(about: far)
                let newEnd = byFar[atStart ? 0 : points.count - 1].xy
                if let seg = hostSegment(through: j, excluding: entity.id, in: entities),
                   isInside(newEnd, seg.a, seg.b) {
                    updated.kind = .pipe(points: byFar, attrs: attrs)
                    return (updated, .mirroredBranch(aboutFarEnd: true))
                }
                updated.kind = .pipe(points: mirrored(about: j.position), attrs: attrs)
                return (updated, .mirroredBranch(aboutFarEnd: false))
            }
            // 直角の枝(DT/LT・立てチーズ・両端が枝): 下流側の印を切り替える
            attrs.branchReversed.toggle()
            updated.kind = .pipe(points: points, attrs: attrs)
            return (updated, .toggledBranch(nowReversed: attrs.branchReversed))
        }

        // 本管(または単独の配管): 作図方向を逆にする
        let tees = junctions.filter { if case .tee = $0.kind { return true }; return false }.count
        updated.kind = .pipe(points: Array(points.reversed()), attrs: attrs)
        return (updated, .reversedFlow(branches: tees))
    }

    /// 接続点jを芯線上(端点以外)に持つ本管の区間
    static func hostSegment(through j: PipeJunction, excluding id: EntityID,
                            in entities: [Entity]) -> (a: Vec2, b: Vec2)? {
        let tol = PipeNetwork.joinTolerance
        for e in entities where e.id != id {
            guard case .pipe(let pts, _) = e.kind, pts.count >= 2 else { continue }
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                guard a.xy.distance(to: b.xy) > PipeGeometry.planEpsilon,
                      abs(a.z - j.z) <= tol else { continue }
                let foot = HitGeometry.closestPointOnSegment(j.position, a.xy, b.xy)
                guard foot.distance(to: j.position) <= tol,
                      foot.distance(to: a.xy) > tol, foot.distance(to: b.xy) > tol else { continue }
                return (a.xy, b.xy)
            }
        }
        return nil
    }

    /// 点が区間abの内側(端点から許容ぶん離れた範囲)にあるか
    static func isInside(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Bool {
        let tol = PipeNetwork.joinTolerance
        let foot = HitGeometry.closestPointOnSegment(p, a, b)
        return foot.distance(to: p) <= tol && foot.distance(to: a) > tol && foot.distance(to: b) > tol
    }
}
