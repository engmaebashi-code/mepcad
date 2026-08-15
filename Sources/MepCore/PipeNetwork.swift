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
        /// 分岐(本管側)。branchDirection=枝管の方向(単位ベクトル・平面)、branchOD=枝管外径、
        /// branchDims=枝管側の継手寸法(径違いティーズの寸法補間用)
        /// mainDirection=本管の区間方向(単位・平面)
        case tee(branchDirection: Vec2, branchOD: Double, branchSizeLabel: String,
                 branchDims: PipeFittingDims, mainDirection: Vec2)
        /// 口径変更(大きい方の側)。direction=接続相手へ向かう方向、otherOD=相手の外径、
        /// otherDims=相手側の継手寸法(小径側受口)
        case reducer(direction: Vec2, otherOD: Double, otherSizeLabel: String,
                     otherDims: PipeFittingDims)
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
                                                                otherSizeLabel: other.attrs.sizeLabel,
                                                                otherDims: other.attrs.effectiveFittingDims)))
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
                        let mainVec = b.xy - a.xy
                        let mainDir = mainVec * (1 / mainVec.length)
                        // 同じ点に両側から枝管が来る場合(=クロス)は1つのティーズにまとめる
                        if (result[other.id] ?? []).contains(where: {
                            if case .tee = $0.kind, $0.position.distance(to: foot) <= tol { return true }
                            return false
                        }) { break }
                        result[other.id, default: []].append(
                            PipeJunction(pipeID: other.id, position: foot, z: a.z,
                                         kind: .tee(branchDirection: branchDir,
                                                    branchOD: p.attrs.outerDiameter,
                                                    branchSizeLabel: p.attrs.sizeLabel,
                                                    branchDims: p.attrs.effectiveFittingDims,
                                                    mainDirection: mainDir)))
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

    // MARK: - 継手の平面ジオメトリ(複線用)M6.5

    /// 継手(ティーズ・レデューサ・キャップ)の実形状。attrsは本管(継手が付く側)。
    /// - ティーズ: 主管受口2つ+枝受口+本体(T形の1多角形)。径違いは主管側A・枝側Aとも
    ///   同径ティーズの本管サイズ値と枝サイズ値の平均(メーカー寸法表と±3mm程度で一致)
    /// - レデューサ: 大径受口→テーパ→小径受口(接続点から小径側へ)
    /// - キャップ: 受口深さぶん被せる
    public static func junctionShapes(_ j: PipeJunction, attrs: PipeAttributes) -> [PipeFittingShape] {
        let dims = attrs.effectiveFittingDims
        let r = attrs.outerDiameter / 2
        let s = max(dims.socketOD / 2, r * 1.05)
        let d = dims.socketDepth
        switch j.kind {
        case .tee(let bdir, let bod, _, let bdims, let mainDir):
            // 本管方向。枝が斜め(45°Y)でも本体は本管に沿わせ、枝受口は枝方向へ
            let along = mainDir
            let side = along.x * bdir.y - along.y * bdir.x   // 枝がどちら側か(左折正)
            let rb = bod / 2
            let sb = max(bdims.socketOD / 2, rb * 1.05)
            let db = bdims.socketDepth > 0 ? bdims.socketDepth : d
            let sameSize = abs(bod - attrs.outerDiameter) < 0.01
            let aRun = sameSize ? dims.teeA : (dims.teeA + (bdims.teeA > 0 ? bdims.teeA : dims.teeA)) / 2
            let aBr = aRun
            let a2r = max(max(aRun - d, 0), rb + 1)
            let a2b = max(aBr - db, r + 1)
            // 本管座標系(x=along, y=枝側の法線)。枝は枝方向bdirに沿って伸ばす
            let ny = Vec2(-along.y, along.x) * (side >= 0 ? 1 : -1)
            func w(_ x: Double, _ y: Double) -> Vec2 { j.position + along * x + ny * y }
            let bn = Vec2(-bdir.y, bdir.x)      // 枝の法線
            func bw(_ t: Double, _ o: Double) -> Vec2 { j.position + bdir * t + bn * o }
            // 枝の付け根: 枝の外形線(オフセットo=±rb)が本管外形線(y=r)と交わる枝方向距離
            let sinb = max(bdir.x * ny.x + bdir.y * ny.y, 0.2)
            let bnY = bn.x * ny.x + bn.y * ny.y
            func tRoot(_ o: Double) -> Double { max((r - bnY * o) / sinb, 0) }
            let cosb = abs(bdir.x * along.x + bdir.y * along.y)
            if cosb > 0.3 {
                // 斜め分岐(45°Yなど): 本体(本管部)と枝を別部品で(枝を後から重ねる)。
                // 枝の中心〜端は同径ティーズの1.6倍(DV Y: 194/113)で概算
                var aBrY = aBr * 1.6
                let a2bY = max(aBrY - db, r + 1, tRoot(-rb) + 1, tRoot(rb) + 1)
                aBrY = max(aBrY, a2bY + db * 0.5)
                let body: [Vec2] = [w(-aRun, -s), w(-a2r, -s), w(-a2r, -r), w(a2r, -r), w(a2r, -s), w(aRun, -s),
                                    w(aRun, s), w(a2r, s), w(a2r, r), w(-a2r, r), w(-a2r, s), w(-aRun, s)]
                let branch: [Vec2] = [bw(tRoot(-rb), -rb), bw(a2bY, -rb), bw(a2bY, -sb), bw(aBrY, -sb),
                                      bw(aBrY, sb), bw(a2bY, sb), bw(a2bY, rb), bw(tRoot(rb), rb)]
                return [PipeFittingShape(parts: [.polygon(body), .polygon(branch)])]
            }
            let poly: [Vec2] = [
                w(-aRun, -s), w(-a2r, -s), w(-a2r, -r), w(a2r, -r), w(a2r, -s), w(aRun, -s),
                w(aRun, s), w(a2r, s), w(a2r, r),
                bw(tRoot(-rb), -rb), bw(a2b, -rb), bw(a2b, -sb), bw(aBr, -sb),
                bw(aBr, sb), bw(a2b, sb), bw(a2b, rb), bw(tRoot(rb), rb),
                w(-a2r, r), w(-a2r, s), w(-aRun, s)]
            return [PipeFittingShape(parts: [.polygon(poly)])]
        case .reducer(let dir, let otherOD, _, let odims):
            let n = Vec2(-dir.y, dir.x)
            let r2 = otherOD / 2
            let s2 = max(odims.socketOD / 2, r2 * 1.05)
            let d2 = odims.socketDepth > 0 ? odims.socketDepth : d * 0.8
            let taper = min(max(d * 0.55, 15), 45)
            func w(_ x: Double, _ y: Double) -> Vec2 { j.position + dir * x + n * y }
            let poly: [Vec2] = [
                w(-d, s), w(0, s), w(taper, s2), w(taper + d2, s2),
                w(taper + d2, -s2), w(taper, -s2), w(0, -s), w(-d, -s)]
            return [PipeFittingShape(parts: [.polygon(poly)])]
        case .cap(let dir):
            let len = max(dims.capLength, d + 5)
            let n = Vec2(-dir.y, dir.x)
            let a = j.position - dir * d
            let b = j.position - dir * d + dir * len
            return [PipeFittingShape(parts: [.polygon([a + n * s, b + n * s, b - n * s, a - n * s])])]
        }
    }
}
