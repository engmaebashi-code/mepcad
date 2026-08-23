import Foundation

// MARK: - 移動時の接続追随(伸縮移動)M7.3
//
// 本管を移動したとき、そこに取り付いている枝管が置き去りになって接続が切れると
// 継手も消えてしまう。FILDERの伸縮移動と同じく、動かさない側の配管の端を
// 「その管の軸方向へ」伸び縮みさせて接続を保つ。
//
// - 枝管の端が本管の芯線上に乗っている場合(いちばん多い形):
//   移動後の本管の芯線と、枝管の管軸線との交点へ端を移す。
//   端は自分の軸線上を滑るだけなので、枝管の角度(=継手の角度)は変わらない。
// - 端どうしが突き合わさっている場合: 接続点そのものが動くので、端をその点へ合わせる。
//
// 移動する側は既存の平行移動のまま。ここで求めるのは「動かさない側の新しい姿」だけ。

public enum PipeConnections {

    /// 接続とみなす許容(mm)
    public static var tolerance: Double { PipeNetwork.joinTolerance }

    /// 伸縮後に残す最小の脚長(mm)
    public static let minLeg: Double = 1

    /// 移動する配管に接続している「移動しない配管」の更新後の姿を返す。
    /// 変化したエンティティだけを返す(idは維持)
    public static func followers(movingIDs: Set<EntityID>, delta: Vec2,
                                 in entities: [Entity]) -> [Entity] {
        guard delta.length > 1e-9, !movingIDs.isEmpty else { return [] }
        struct Moving {
            let points: [Vec3]
        }
        var moving: [Moving] = []
        var others: [Entity] = []
        for e in entities {
            guard case .pipe(let pts, _) = e.kind, pts.count >= 2 else { continue }
            if movingIDs.contains(e.id) {
                moving.append(Moving(points: pts))
            } else {
                others.append(e)
            }
        }
        guard !moving.isEmpty, !others.isEmpty else { return [] }
        let tol = tolerance

        var result: [Entity] = []
        for entity in others {
            guard case .pipe(let pts, let attrs) = entity.kind else { continue }
            var points = pts
            var changed = false
            for atStart in [true, false] {
                let idx = atStart ? 0 : points.count - 1
                let end = points[idx]
                // 端の管軸(内側→端の向き)と、軸線の基準点(平面上で最初に離れた頂点)
                guard let axis = PipeNetwork.outwardDirection(points: points, atStart: atStart),
                      let anchor = axisAnchor(points: points, atStart: atStart) else { continue }

                var target: Vec2?
                search: for m in moving {
                    // (a) 端点どうしの突き合わせ — 接続点そのものが動く
                    for mi in [0, m.points.count - 1] {
                        let mp = m.points[mi]
                        if mp.xy.distance(to: end.xy) <= tol, abs(mp.z - end.z) <= tol {
                            target = mp.xy + delta
                            break search
                        }
                    }
                    // (b) 相手の芯線上に乗っている(枝管→本管)— 移動後の芯線と自分の軸線の交点へ
                    for s in 0..<(m.points.count - 1) {
                        let a = m.points[s], b = m.points[s + 1]
                        guard a.xy.distance(to: b.xy) > PipeGeometry.planEpsilon else { continue }
                        let foot = HitGeometry.closestPointOnSegment(end.xy, a.xy, b.xy)
                        guard foot.distance(to: end.xy) <= tol, abs(end.z - a.z) <= tol else { continue }
                        if let x = intersection(origin: anchor, direction: axis,
                                                segmentA: a.xy + delta, segmentB: b.xy + delta) {
                            target = x
                        } else {
                            target = end.xy + delta   // 軸が本管と平行 — 平行移動で追随
                        }
                        break search
                    }
                }
                guard let t = target else { continue }
                // 動く必要がない(接続点が同じ位置のまま)なら触らない
                guard t.distance(to: end.xy) > 1e-6 else { continue }
                // 脚が潰れない・暴走しない範囲でのみ追随する
                let leg = (t - anchor).x * axis.x + (t - anchor).y * axis.y
                guard leg >= minLeg,
                      t.distance(to: end.xy) <= delta.length * 20 + 1000 else { continue }
                points = moveEnd(points: points, index: idx, to: t)
                changed = true
            }
            if changed {
                var updated = entity
                updated.kind = .pipe(points: points, attrs: attrs)
                result.append(updated)
            }
        }
        return result
    }

    /// 端の管軸線の基準点: 端から見て平面上で最初に離れた頂点(立管はまたぐ)
    static func axisAnchor(points: [Vec3], atStart: Bool) -> Vec2? {
        let pts = atStart ? Array(points) : Array(points.reversed())
        for i in 1..<pts.count where pts[0].xy.distance(to: pts[i].xy) > PipeGeometry.planEpsilon {
            return pts[i].xy
        }
        return nil
    }

    /// 端(立管なら平面上同じ位置の連続頂点をまとめて)を指定点へ移す。高さは維持
    static func moveEnd(points: [Vec3], index: Int, to target: Vec2) -> [Vec3] {
        var out = points
        let anchor = points[index].xy
        if index == 0 {
            var i = 0
            while i < points.count, points[i].xy.distance(to: anchor) <= PipeGeometry.planEpsilon {
                out[i] = Vec3(target, z: points[i].z)
                i += 1
            }
        } else {
            var i = index
            while i >= 0, points[i].xy.distance(to: anchor) <= PipeGeometry.planEpsilon {
                out[i] = Vec3(target, z: points[i].z)
                i -= 1
            }
        }
        return out
    }

    /// 半直線(origin, direction)と線分ABを含む直線の交点。平行ならnil
    static func intersection(origin: Vec2, direction: Vec2,
                             segmentA: Vec2, segmentB: Vec2) -> Vec2? {
        let s = segmentB - segmentA
        let den = direction.x * s.y - direction.y * s.x
        guard abs(den) > 1e-9 else { return nil }
        let q = segmentA - origin
        let t = (q.x * s.y - q.y * s.x) / den
        return origin + direction * t
    }
}
