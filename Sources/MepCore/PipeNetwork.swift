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
        /// mainDirection=本管の区間方向(単位・平面。作図方向=流れ方向として下流側の判定に使う)、
        /// verticalBranch=枝管が立管で本管に取り付く(立てチーズ: 枝の受口は上/下向き→平面では円)
        /// branchKind=枝管側で指定した分岐部品("DT"/"LT"/"Y")
        case tee(branchDirection: Vec2, branchOD: Double, branchSizeLabel: String,
                 branchDims: PipeFittingDims, mainDirection: Vec2, verticalBranch: Bool,
                 branchKind: String)
        /// 枝管側の印(枝管の端が本管に取り付いている)。hostDirection=本管方向、
        /// hostLongRadius=本管が大曲(LT)指定、vertical=立てチーズ(枝の端が立管)。
        /// 単線の枝端の切り詰め・立管記号の抑制に使う(形状・集計には出ない)
        case teeBranch(hostDirection: Vec2, hostLongRadius: Bool, vertical: Bool)
        // hostLongRadius は互換のため残す(現在は枝管側のbranchKind=="LT"で判定)
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
            var ends: [(point: Vec3, dirIn: Vec2, vertical: Bool)] = []
            // 始点: 内側→端へ向かう方向 = points[1]→points[0](平面)。立管ならその先の水平区間を使う。
            // vertical=端の区間が立管(平面同一点)
            if let d0 = outwardDirection(points: p.points, atStart: true) {
                let v = p.points[1].xy.distance(to: p.points[0].xy) <= PipeGeometry.planEpsilon
                ends.append((p.points[0], d0, v))
            }
            if let d1 = outwardDirection(points: p.points, atStart: false) {
                let n = p.points.count
                let v = p.points[n - 2].xy.distance(to: p.points[n - 1].xy) <= PipeGeometry.planEpsilon
                ends.append((p.points[n - 1], d1, v))
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
                        // 枝管側にも印(単線の枝端の切り詰め・立管記号の抑制用)
                        result[p.id, default: []].append(
                            PipeJunction(pipeID: p.id, position: foot, z: a.z,
                                         kind: .teeBranch(hostDirection: mainDir,
                                                          hostLongRadius: p.attrs.branchKind == "LT",
                                                          vertical: end.vertical)))
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
                                                    mainDirection: mainDir,
                                                    verticalBranch: end.vertical,
                                                    branchKind: p.attrs.branchKind)))
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
        case .tee(let bdir, let bod, _, let bdims, let mainDir, let vertical, let branchKind):
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
            // 径違いは枝の受口底をテーパの傾きぶん外へずらす(M7。同径なら0で従来どおり)
            let branchShift = PipeGeometry.socketShift(od: attrs.outerDiameter, otherOD: bod,
                                                       socketOD: dims.socketOD,
                                                       otherSocketOD: bdims.socketOD,
                                                       taper: max(aBr - db, 1))
            let a2b = max(aBr - db + min(max(branchShift, -db * 0.5), db * 0.5), r + 1)
            // 枝の受口底は付け根(外形線の交点)より先になければ輪郭が折り返す(斜め分岐の保険)
            // 本管座標系(x=along, y=枝側の法線)。枝は枝方向bdirに沿って伸ばす
            let ny = Vec2(-along.y, along.x) * (side >= 0 ? 1 : -1)
            func w(_ x: Double, _ y: Double) -> Vec2 { j.position + along * x + ny * y }
            let bn = Vec2(-bdir.y, bdir.x)      // 枝の法線
            func bw(_ t: Double, _ o: Double) -> Vec2 { j.position + bdir * t + bn * o }
            // 本管部だけの多角形(受口2つ+本体。x範囲 -aUp〜+aDown)
            func hostPart(aUp: Double, aDown: Double) -> [Vec2] {
                let a2u = max(aUp - d, 0), a2d = max(aDown - d, 0)   // 受口は常に深さdの実寸
                return [w(-aUp, -s), w(-a2u, -s), w(-a2u, -r), w(a2d, -r), w(a2d, -s), w(aDown, -s),
                        w(aDown, s), w(a2d, s), w(a2d, r), w(-a2u, r), w(-a2u, s), w(-aUp, s)]
            }
            // 受口底の線(本管の両受口)
            func hostBottoms(aUp: Double, aDown: Double) -> [PipeFittingShape.Part] {
                let a2u = max(aUp - d, 0), a2d = max(aDown - d, 0)
                return [.polyline([w(-a2u, -s), w(-a2u, s)]), .polyline([w(a2d, -s), w(a2d, s)])]
            }
            let cosb = bdir.x * along.x + bdir.y * along.y
            // 立てチーズ: 枝の受口は上/下向き → 本管部+枝受口外径の円+管の縁(奥側の半円)
            if vertical {
                let far = Vec2(-bdir.x, -bdir.y)
                let inner = PipeGeometry.ellipseArc(center: j.position, along: far, a: rb, across: bn, b: rb,
                                                    from: 0, to: .pi, segments: 12)
                return [PipeFittingShape(parts: [.polygon(hostPart(aUp: aRun, aDown: aRun))]
                                         + hostBottoms(aUp: aRun, aDown: aRun)
                                         + [.circle(center: j.position, radius: sb), .polyline(inner)])]
            }
            // 枝の付け根: 枝の外形線(オフセットo=±rb)が本管外形線(y=r)と交わる枝方向距離
            let sinb = max(bdir.x * ny.x + bdir.y * ny.y, 0.2)
            let bnY = bn.x * ny.x + bn.y * ny.y
            func tRoot(_ o: Double) -> Double { max((r - bnY * o) / sinb, 0) }
            // 斜め分岐(枝が本管に直角でない)はY形の輪郭で描く。実物でも斜めに取り付く部品はY。
            // 直角用の輪郭は斜めだと枝の付け根(tRoot)が受口底を追い越して自己交差する。M7.1
            if abs(cosb) > 0.3 {
                // 45°Y: 主管は枝が傾く側(下流)が短い。DV Y(2157)の比: 上流L1≈0.95L3、
                // 下流L2≈0.42L3、枝L3(=y45A、無ければDT×1.72)。本体(本管部)+枝を別部品で(枝を後から重ねる)。
                // DT/LT指定でも斜めに取り付いたときはこの輪郭を使い、長さだけ手持ちのA寸法にする
                let isY = branchKind == "Y"
                let l3 = !isY ? aRun
                    : (dims.y45A > 0 ? (sameSize ? dims.y45A : (dims.y45A + (bdims.y45A > 0 ? bdims.y45A : dims.y45A)) / 2)
                                     : aRun * 1.72)
                let l1 = isY ? l3 * 0.95 : l3, l2 = isY ? l3 * 0.42 : l3
                // 枝は上流側へ傾いて取り付く(枝方向bdirは接合点→枝管=上流向き)。
                // 上流(長い側L1)は枝が傾く側、下流(短い側L2)はその反対
                let aUp = cosb > 0 ? l2 : l1      // -along側の長さ
                let aDown = cosb > 0 ? l1 : l2    // +along側の長さ
                let a2bY = max(l3 - db, tRoot(-rb) + 1, tRoot(rb) + 1)
                let aBrY = max(l3, a2bY + db * 0.5)
                let branch: [Vec2] = [bw(tRoot(-rb), -rb), bw(a2bY, -rb), bw(a2bY, -sb), bw(aBrY, -sb),
                                      bw(aBrY, sb), bw(a2bY, sb), bw(a2bY, rb), bw(tRoot(rb), rb)]
                return [PipeFittingShape(parts: [.polygon(hostPart(aUp: aUp, aDown: aDown))]
                                         + hostBottoms(aUp: aUp, aDown: aDown)
                                         + [.polygon(branch), .polyline([bw(a2bY, -sb), bw(a2bY, sb)])])]
            }
            if branchKind == "LT", dims.effectiveElbow90LLA > 0 {
                // 大曲Y(LT。FILDERの表現準拠): 上流受口(A_LL×0.53)+本体+下流受口(A_LL)+枝受口(A_LL)を
                // 1つの輪郭に。枝→下流(=本管の作図方向)へ大曲のスイープ。
                // 内側の弧: 中心(a2−k, a2−k)・半径(a2−k)−r、外側の弧: 枝の外壁に接し(高さa2−k)半径0.736·a2+r
                // (k=0.12·a2。DV100実測: a2=128, k=15, 内R59, 外R148)
                let llMain = dims.effectiveElbow90LLA
                let llBranch = bdims.effectiveElbow90LLA > 0 ? bdims.effectiveElbow90LLA : llMain
                let aDown = sameSize ? llMain : 0.29 * llMain + 0.71 * llBranch
                let aUp = 0.53 * (sameSize ? llMain : 0.65 * llMain + 0.35 * llBranch)
                let allB = aDown
                let a2 = max(aDown - d, 0)
                let a2u = max(aUp - d, 0)
                let a2b = max(allB - db, 0)
                let k = a2 * 0.12
                let rin = max(a2 - k - max(r, rb), 1)
                let cix = rb + rin, ciy = r + rin
                let ro = 0.736 * a2 + rb
                let cox = 0.736 * a2, coy = a2 - k
                let dyo = coy - r
                let dxo = max(ro * ro - dyo * dyo, 0).squareRoot()
                let xo = cox - dxo
                func warc(_ cx: Double, _ cy: Double, _ radius: Double, _ ang: Double) -> Vec2 {
                    w(cx + cos(ang) * radius, cy + sin(ang) * radius)
                }
                var poly: [Vec2] = []
                poly += [w(-aUp, -s), w(-a2u, -s), w(-a2u, -r), w(a2, -r), w(a2, -s), w(aDown, -s),
                         w(aDown, s), w(a2, s), w(a2, r)]
                // 上側外形線を(a2−k, r)まで戻り、内側の弧で枝の右壁(x=r, y=a2−k)へ
                poly.append(w(cix, r))
                for kk in 1..<8 {
                    let ang = -Double.pi / 2 - (Double.pi / 2) * Double(kk) / 8   // -90°→-180°
                    poly.append(warc(cix, ciy, rin, ang))
                }
                poly += [w(rb, ciy), w(rb, a2b), w(sb, a2b), w(sb, allB),
                         w(-sb, allB), w(-sb, a2b), w(-rb, a2b), w(-rb, coy)]
                // 外側の弧: 枝の左壁(-r, a2−k)から下がって上側外形線(y=r)へ
                var angEnd = atan2(r - coy, xo - cox)
                if angEnd < 0 { angEnd += 2 * .pi }
                let angStart = Double.pi
                for kk in 1...8 {
                    let ang = angStart + (angEnd - angStart) * Double(kk) / 8
                    poly.append(warc(cox, coy, ro, ang))
                }
                poly += [w(-a2u, r), w(-a2u, s), w(-aUp, s)]
                let bottoms: [PipeFittingShape.Part] = [
                    .polyline([w(-a2u, -s), w(-a2u, s)]), .polyline([w(a2, -s), w(a2, s)]),
                    .polyline([w(-sb, a2b), w(sb, a2b)])]
                return [PipeFittingShape(parts: [.polygon(poly)] + bottoms)]
            }
            let poly: [Vec2] = [
                w(-aRun, -s), w(-a2r, -s), w(-a2r, -r), w(a2r, -r), w(a2r, -s), w(aRun, -s),
                w(aRun, s), w(a2r, s), w(a2r, r),
                bw(tRoot(-rb), -rb), bw(a2b, -rb), bw(a2b, -sb), bw(aBr, -sb),
                bw(aBr, sb), bw(a2b, sb), bw(a2b, rb), bw(tRoot(rb), rb),
                w(-a2r, r), w(-a2r, s), w(-aRun, s)]
            return [PipeFittingShape(parts: [.polygon(poly), .polyline([w(-a2r, -s), w(-a2r, s)]),
                                             .polyline([w(a2r, -s), w(a2r, s)]),
                                             .polyline([bw(a2b, -sb), bw(a2b, sb)])])]
        case .reducer(let dir, let otherOD, _, let odims):
            let n = Vec2(-dir.y, dir.x)
            let r2 = otherOD / 2
            let s2 = max(odims.socketOD / 2, r2 * 1.05)
            let d2 = odims.socketDepth > 0 ? odims.socketDepth : d * 0.8
            let taper = min(max(d * 0.6, 20), 40)     // DV IN: 40〜65A:20, 75:25, 100:30, 125:35, 150:40
            // 受口底はテーパの傾きぶん小径側へずれる(M7。大径側の受口が a1 だけ深くなる)
            let shift = PipeGeometry.socketShift(od: attrs.outerDiameter, otherOD: otherOD,
                                                 socketOD: dims.socketOD,
                                                 otherSocketOD: odims.socketOD, taper: taper)
            let a1 = min(max(shift, -d * 0.5), d2 * 0.5)
            func w(_ x: Double, _ y: Double) -> Vec2 { j.position + dir * x + n * y }
            let poly: [Vec2] = [
                w(-d, s), w(a1, s), w(taper + a1, s2), w(taper + d2, s2),
                w(taper + d2, -s2), w(taper + a1, -s2), w(a1, -s), w(-d, -s)]
            return [PipeFittingShape(parts: [.polygon(poly), .polyline([w(a1, -s), w(a1, s)]),
                                             .polyline([w(taper + a1, -s2), w(taper + a1, s2)])])]
        case .teeBranch:
            return []
        case .cap(let dir):
            let len = max(dims.capLength, d + 5)
            let n = Vec2(-dir.y, dir.x)
            let a = j.position - dir * d
            let b = j.position - dir * d + dir * len
            return [PipeFittingShape(parts: [.polygon([a + n * s, b + n * s, b - n * s, a - n * s]),
                                             .polyline([j.position + n * s, j.position - n * s])])]
        }
    }
}
