import Foundation

// MARK: - 移動時の接続追随(伸縮移動)M7.3 / M7.4
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
// M7.4: 判定を2段階にした。まず継手と同じ厳密な許容(1mm)で探し、見つからなければ
// 「枝の端が本管の胴に入っている(両者の外半径の和まで)」を接続とみなす。
// 作図時にきっちり芯線へスナップできていなくても掴めるようにするため
// — 追随後は端がぴったり芯線に乗るので、そこで継手も出るようになる。
//
// 移動する側は既存の平行移動のまま。ここで求めるのは「動かさない側の新しい姿」だけ。

public enum PipeConnections {

    /// 継手判定と同じ厳密な許容(mm)
    public static var tolerance: Double { PipeNetwork.joinTolerance }

    /// 伸縮後に残す最小の脚長(mm)
    public static let minLeg: Double = 1

    /// 変形する配管の「変形前 → 変形後」の芯線。移動なら全点が平行移動、
    /// 伸縮なら一部の頂点だけが動く(頂点数は変わらない)
    public struct PipeChange: Sendable {
        public let before: [Vec3]
        public let after: [Vec3]
        /// 管の外半径(接続とみなす範囲に使う)
        public let radius: Double

        public init(before: [Vec3], after: [Vec3], radius: Double) {
            self.before = before
            self.after = after
            self.radius = radius
        }
    }

    /// 移動する配管に接続している「移動しない配管」の更新後の姿を返す(平行移動版)。
    /// 変化したエンティティだけを返す(idは維持)
    public static func followers(movingIDs: Set<EntityID>, delta: Vec2,
                                 in entities: [Entity]) -> [Entity] {
        guard delta.length > 1e-9, !movingIDs.isEmpty else { return [] }
        var changes: [PipeChange] = []
        for e in entities {
            guard movingIDs.contains(e.id),
                  case .pipe(let pts, let attrs) = e.kind, pts.count >= 2 else { continue }
            changes.append(PipeChange(before: pts,
                                      after: pts.map { Vec3($0.xy + delta, z: $0.z) },
                                      radius: max(attrs.outerDiameter / 2, 0)))
        }
        return followers(changes: changes, movingIDs: movingIDs, in: entities)
    }

    /// 変形(移動・伸縮)する配管に接続している「動かさない配管」の更新後の姿を返す。M7.6
    ///
    /// 伸縮(グリップ編集)でも接続が切れないように、変形前の芯線で接続を判定し、
    /// 変形後の芯線へ端を移す。枝管の端は自分の管軸線上を滑るので角度は変わらない。
    public static func followers(changes: [PipeChange], movingIDs: Set<EntityID>,
                                 in entities: [Entity]) -> [Entity] {
        let live = changes.filter { $0.before.count >= 2 && $0.before.count == $0.after.count }
        guard !live.isEmpty else { return [] }
        let tol = tolerance
        // 変形量(頂点の最大移動距離)。これを大きく超える追随は暴走とみなして見送る
        let maxShift = live.flatMap { c in
            zip(c.before, c.after).map { $0.xy.distance(to: $1.xy) }
        }.max() ?? 0
        guard maxShift > 1e-9 else { return [] }

        var result: [Entity] = []
        for entity in entities {
            guard !movingIDs.contains(entity.id),
                  case .pipe(let pts, let attrs) = entity.kind, pts.count >= 2 else { continue }
            var points = pts
            let selfRadius = max(attrs.outerDiameter / 2, 0)
            var changed = false
            for atStart in [true, false] {
                let idx = atStart ? 0 : points.count - 1
                let end = points[idx]
                // 端の管軸(内側→端の向き)と、軸線の基準点(平面上で最初に離れた頂点)
                guard let axis = PipeNetwork.outwardDirection(points: points, atStart: atStart),
                      let anchor = axisAnchor(points: points, atStart: atStart) else { continue }

                /// 相手の端点と一致しているか(接続点そのものが動く)
                func buttJoint(within reach: Double) -> Vec2? {
                    var best: (Vec2, Double)?
                    for c in live {
                        let limit = max(reach, tol)
                        for mi in [0, c.before.count - 1] {
                            let mp = c.before[mi]
                            let d = mp.xy.distance(to: end.xy)
                            guard d <= limit, abs(mp.z - end.z) <= tol else { continue }
                            if best == nil || d < best!.1 { best = (c.after[mi].xy, d) }
                        }
                    }
                    return best?.0
                }

                /// 相手の芯線上に乗っているか(枝管→本管)。変形後の芯線と自分の軸線の交点へ
                func onCenterline(within reach: Double) -> Vec2? {
                    var best: (Vec2, Double)?
                    for c in live {
                        let limit = max(reach + c.radius, tol)
                        for s in 0..<(c.before.count - 1) {
                            let a = c.before[s], b = c.before[s + 1]
                            guard a.xy.distance(to: b.xy) > PipeGeometry.planEpsilon else { continue }
                            let foot = HitGeometry.closestPointOnSegment(end.xy, a.xy, b.xy)
                            let d = foot.distance(to: end.xy)
                            guard d <= limit, abs(end.z - a.z) <= tol else { continue }
                            let na = c.after[s].xy, nb = c.after[s + 1].xy
                            guard na.distance(to: nb) > PipeGeometry.planEpsilon else { continue }
                            // 変形後の芯線と自分の管軸線の交点(平行なら同じ位置比の点)
                            let x = intersection(origin: anchor, direction: axis,
                                                 segmentA: na, segmentB: nb)
                                ?? sameFraction(foot, a.xy, b.xy, na, nb)
                            if best == nil || d < best!.1 { best = (x, d) }
                        }
                    }
                    return best?.0
                }

                // 1段目: 継手と同じ厳密な判定(端点の一致 → 芯線上)
                // 2段目: 胴に入っていれば接続とみなす(芯線上を優先 — 枝の角度が保たれる)
                let reach = selfRadius + 1
                let target = buttJoint(within: tol) ?? onCenterline(within: tol)
                    ?? onCenterline(within: reach) ?? buttJoint(within: reach)
                guard let t = target else { continue }
                // 動く必要がない(接続点が同じ位置のまま)なら触らない
                guard t.distance(to: end.xy) > 1e-6 else { continue }
                // 脚が潰れない・暴走しない範囲でのみ追随する
                let leg = (t - anchor).x * axis.x + (t - anchor).y * axis.y
                guard leg >= minLeg,
                      t.distance(to: end.xy) <= maxShift * 20 + 1000 else { continue }
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

    /// 変形前の区間での位置比を、変形後の区間の同じ位置比へ写す(軸が芯線と平行なときの保険)
    static func sameFraction(_ foot: Vec2, _ a: Vec2, _ b: Vec2,
                             _ na: Vec2, _ nb: Vec2) -> Vec2 {
        let len = a.distance(to: b)
        guard len > PipeGeometry.planEpsilon else { return na }
        let t = ((foot - a).x * (b - a).x + (foot - a).y * (b - a).y) / (len * len)
        return na + (nb - na) * max(0, min(1, t))
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

    /// 直線(origin, direction)と線分ABを含む直線の交点。平行ならnil
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
