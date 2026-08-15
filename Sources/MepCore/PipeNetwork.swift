import Foundation

// MARK: - 配管ネットワーク解析(分岐・接続・端部)M6.3
//
// 図面内の配管同士の位置関係から継手を「その都度」導出する(図面にはデータを持たない):
// - ティーズ: ある配管の端点が別の配管の芯線上(端点以外)に乗っている → 乗られた側(本管)に発生
// - レデューサ: 端点同士が突き合っていて呼び径が違う → 大きい方の側に発生
// - キャップ: capEndsの配管で、どこにも接続していない端部
// 高さ(z)も一致している必要がある(平面上で重なるだけの立体交差は接続しない)

/// 配管に付く継手(ネットワーク由来)
public struct PipeJunction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 分岐(本管側)。branchDirection=枝管の方向(単位ベクトル・平面)、branchOD=枝管外径
        case tee(branchDirection: Vec2, branchOD: Double, branchSizeLabel: String)
        /// 口径変更(大きい方の側)。direction=接続相手へ向かう方向、otherOD=相手の外径
        case reducer(direction: Vec2, otherOD: Double, otherSizeLabel: String)
        /// 端部キャップ。direction=管の内側から端へ向かう方向
        case cap(direction: Vec2)
    }
    public let pipeID: EntityID
    public let position: Vec2
    public let z: Double
    public let kind: Kind
}

public enum PipeNetwork {

    /// 接続とみなす許容(mm。平面・高さ)
    public static let joinTolerance = 1.0

    /// 図面内の配管一式から継手(ティーズ・レデューサ・キャップ)を導出する。
    /// 戻り値は配管idごと
    public static func junctions(in entities: [Entity]) -> [EntityID: [PipeJunction]] {
        struct P {
            let id: EntityID
            let points: [Vec3]
            let attrs: PipeAttributes
        }
        let pipes: [P] = entities.compactMap { e in
            guard case .pipe(let pts, let attrs) = e.kind, pts.count >= 2 else { return nil }
            return P(id: e.id, points: pts, attrs: attrs)
        }
        guard !pipes.isEmpty else { return [:] }
        var result: [EntityID: [PipeJunction]] = [:]
        let tol = joinTolerance

        // 端点(始点・終点)ごとに接続先を探す
        for p in pipes {
            var ends: [(point: Vec3, dirIn: Vec2)] = []
            // 始点: 内側→端へ向かう方向 = points[1]→points[0](平面)。立管ならその先の水平区間を使う
            if let d0 = outwardDirection(points: p.points, atStart: true) {
                ends.append((p.points[0], d0))
            }
            if let d1 = outwardDirection(points: p.points, atStart: false) {
                ends.append((p.points[p.points.count - 1], d1))
            }
            for end in ends {
                var connected = false
                for other in pipes where other.id != p.id {
                    // 端点同士の突き合わせ → 口径が違えばレデューサ(大きい側に付ける)
                    for oe in [other.points[0], other.points[other.points.count - 1]] {
                        if end.point.xy.distance(to: oe.xy) <= tol, abs(end.point.z - oe.z) <= tol {
                            connected = true
                            if p.attrs.outerDiameter > other.attrs.outerDiameter + 0.01 {
                                result[p.id, default: []].append(
                                    PipeJunction(pipeID: p.id, position: end.point.xy, z: end.point.z,
                                                 kind: .reducer(direction: end.dirIn,
                                                                otherOD: other.attrs.outerDiameter,
                                                                otherSizeLabel: other.attrs.sizeLabel)))
                            }
                        }
                    }
                    if connected { break }
                    // 端点が相手の芯線上(端点以外)に乗っている → 相手(本管)にティーズ
                    let segs = other.points.count - 1
                    for i in 0..<segs {
                        let a = other.points[i]
                        let b = other.points[i + 1]
                        guard a.xy.distance(to: b.xy) > PipeGeometry.planEpsilon else { continue }
                        let foot = HitGeometry.closestPointOnSegment(end.point.xy, a.xy, b.xy)
                        guard foot.distance(to: end.point.xy) <= tol else { continue }
                        // 端点(=接続点として別途処理)は除く
                        if foot.distance(to: a.xy) <= tol || foot.distance(to: b.xy) <= tol { continue }
                        // 高さ: 水平区間はa.z、立管でない前提でaのzと比較
                        guard abs(end.point.z - a.z) <= tol else { continue }
                        connected = true
                        // 枝管の方向 = 本管から見て端点の内側方向の逆(=本管→枝管)
                        let branchDir = Vec2(-end.dirIn.x, -end.dirIn.y)
                        // 同じ点に両側から枝管が来る場合(=クロス)は1つのティーズにまとめる
                        if (result[other.id] ?? []).contains(where: {
                            if case .tee = $0.kind, $0.position.distance(to: foot) <= tol { return true }
                            return false
                        }) { break }
                        result[other.id, default: []].append(
                            PipeJunction(pipeID: other.id, position: foot, z: a.z,
                                         kind: .tee(branchDirection: branchDir,
                                                    branchOD: p.attrs.outerDiameter,
                                                    branchSizeLabel: p.attrs.sizeLabel)))
                        break
                    }
                    if connected { break }
                }
                if !connected, p.attrs.capEnds {
                    result[p.id, default: []].append(
                        PipeJunction(pipeID: p.id, position: end.point.xy, z: end.point.z,
                                     kind: .cap(direction: end.dirIn)))
                }
            }
        }
        return result
    }

    /// 端部で「管の内側から端へ向かう」平面方向(単位ベクトル)。端が立管なら nil ではなく
    /// 直近の水平区間の方向を使う。水平区間が無い(立管のみ)なら nil
    static func outwardDirection(points: [Vec3], atStart: Bool) -> Vec2? {
        let pts = atStart ? Array(points) : Array(points.reversed())
        // pts[0]が端。最初に平面上で離れる点を探す
        for i in 1..<pts.count {
            let d = pts[0].xy - pts[i].xy
            if d.length > PipeGeometry.planEpsilon {
                return d * (1 / d.length)
            }
        }
        return nil
    }

    // MARK: - 継手の平面ジオメトリ(複線用)

    /// 継手(ティーズ・レデューサ・キャップ)の外形四角形。attrsは本管(継手が付く側)
    public static func junctionBoxes(_ j: PipeJunction, attrs: PipeAttributes) -> [[Vec2]] {
        let dims = attrs.effectiveFittingDims
        let rf = max(dims.socketOD / 2, attrs.outerDiameter / 2 * 1.05)
        func box(from a: Vec2, dir u: Vec2, length: Double, halfWidth: Double) -> [Vec2] {
            let n = Vec2(-u.y, u.x)
            let b = a + u * length
            return [a + n * halfWidth, b + n * halfWidth, b - n * halfWidth, a - n * halfWidth]
        }
        switch j.kind {
        case .tee(let bdir, let bod, _):
            // 本管方向(枝管に直交)に両側A寸法、枝管方向に受口
            let along = Vec2(-bdir.y, bdir.x)
            let a = dims.teeA
            let branchRf = max(bod / 2 * 1.15, min(rf, bod / 2 * 1.3))
            return [box(from: j.position - along * a, dir: along, length: a * 2, halfWidth: rf),
                    box(from: j.position, dir: bdir, length: a, halfWidth: branchRf)]
        case .reducer(let dir, let otherOD, _):
            // 大きい側の受口→相手径へ絞る台形(端点から相手側へ)
            let n = Vec2(-dir.y, dir.x)
            let len = dims.socketDepth * 1.5
            let r2 = otherOD / 2 * 1.15
            let a = j.position - dir * (dims.socketDepth * 0.5)
            let b = j.position + dir * len
            return [[a + n * rf, b + n * r2, b - n * r2, a - n * rf]]
        case .cap(let dir):
            let len = dims.capLength
            return [box(from: j.position - dir * (len * 0.4), dir: dir, length: len, halfWidth: rf)]
        }
    }
}
