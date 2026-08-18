import XCTest
@testable import MepCore

/// 配管ネットワーク解析(M6.3: ティーズ・レデューサ・キャップの自動発生)
final class PipeNetworkTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    private func pipe(_ pts: [Vec3], od: Double = 60, size: String = "50",
                      caps: Bool = false) -> Entity {
        Entity(layer: layer,
               kind: .pipe(points: pts,
                           attrs: PipeAttributes(size: size, sizeLabel: size, outerDiameter: od,
                                                 annotate: false, doubleLine: true,
                                                 capEnds: caps)))
    }

    /// 枝管の端点が本管の芯線上に乗る → 本管側にティーズ(枝管の方向・外径を持つ)
    func testTeeOnMain() {
        let main = pipe([Vec3(0, 0, 0), Vec3(4000, 0, 0)])
        let branch = pipe([Vec3(1500, 0, 0), Vec3(1500, 2000, 0)], od: 48, size: "40")
        let j = PipeNetwork.junctions(in: [main, branch])
        XCTAssertEqual(j[main.id]?.count, 1)
        guard let tee = j[main.id]?.first, case .tee(let dir, let bod, let label, _, let mainDir, let vertical, let bk) = tee.kind else {
            return XCTFail("ティーズでない")
        }
        XCTAssertEqual(tee.position, Vec2(1500, 0))
        XCTAssertEqual(dir.x, 0, accuracy: 1e-9)
        XCTAssertEqual(dir.y, 1, accuracy: 1e-9)      // 本管→枝管(+y)
        XCTAssertEqual(bod, 48, accuracy: 1e-9)
        XCTAssertEqual(label, "40")
        XCTAssertEqual(mainDir.x, 1, accuracy: 1e-9)   // 本管方向(+x)
        XCTAssertFalse(vertical)
        XCTAssertEqual(bk, "DT")
        // 枝管側には印(teeBranch)が付く
        XCTAssertEqual(j[branch.id]?.count, 1)
        guard case .teeBranch(_, let ll, let v)? = j[branch.id]?.first?.kind else { return XCTFail() }
        XCTAssertFalse(ll); XCTAssertFalse(v)
        // 継手の実形状: T形の1多角形(20頂点)
        let shapes = PipeNetwork.junctionShapes(tee, attrs: PipeAttributes(outerDiameter: 60))
        XCTAssertEqual(shapes.count, 1)
        guard case .polygon(let poly) = shapes[0].parts[0] else { return XCTFail() }
        XCTAssertEqual(poly.count, 20)
        // 径違い(60/48): 主管・枝のA = 本管概算teeA(54)と枝概算teeA(43.2)の平均=48.6
        XCTAssertEqual(poly.map(\.x).min()!, 1500 - 48.6, accuracy: 1e-9)
        XCTAssertEqual(poly.map(\.x).max()!, 1500 + 48.6, accuracy: 1e-9)
        XCTAssertEqual(poly.map(\.y).max()!, 48.6, accuracy: 1e-9)
    }

    /// 高さが違えば平面上で重なっても接続しない(立体交差)
    func testNoTeeWhenHeightDiffers() {
        let main = pipe([Vec3(0, 0, 0), Vec3(4000, 0, 0)])
        let branch = pipe([Vec3(1500, 0, 800), Vec3(1500, 2000, 800)])
        XCTAssertTrue(PipeNetwork.junctions(in: [main, branch]).isEmpty)
    }

    /// 本管の端点に枝管が来る場合はティーズにならない(端点同士の接続=同径ならただの接続)
    func testEndToEndSameSizeIsPlainConnection() {
        let a = pipe([Vec3(0, 0, 0), Vec3(2000, 0, 0)])
        let b = pipe([Vec3(2000, 0, 0), Vec3(2000, 1500, 0)])
        XCTAssertTrue(PipeNetwork.junctions(in: [a, b]).isEmpty)
    }

    /// 端点同士で口径が違う → 大きい側にレデューサ
    func testReducerOnLargerSide() {
        let big = pipe([Vec3(0, 0, 0), Vec3(2000, 0, 0)], od: 76, size: "65")
        let small = pipe([Vec3(2000, 0, 0), Vec3(4000, 0, 0)], od: 60, size: "50")
        let j = PipeNetwork.junctions(in: [big, small])
        XCTAssertEqual(j[big.id]?.count, 1)
        XCTAssertNil(j[small.id])
        guard let r = j[big.id]?.first, case .reducer(let dir, let od, let label, _) = r.kind else {
            return XCTFail("レデューサでない")
        }
        XCTAssertEqual(r.position, Vec2(2000, 0))
        XCTAssertEqual(dir.x, 1, accuracy: 1e-9)       // 内側→端(+x)
        XCTAssertEqual(od, 60, accuracy: 1e-9)
        XCTAssertEqual(label, "50")
        let shapes = PipeNetwork.junctionShapes(r, attrs: PipeAttributes(outerDiameter: 76))
        XCTAssertEqual(shapes.count, 1)
        guard case .polygon(let poly) = shapes[0].parts[0] else { return XCTFail() }
        XCTAssertEqual(poly.count, 8)
        // 大径受口は接続点から-x側に受口深さ、小径側は+x側へ
        XCTAssertLessThan(poly.map(\.x).min()!, 2000)
        XCTAssertGreaterThan(poly.map(\.x).max()!, 2000)
    }

    /// キャップ: capEndsの配管の、接続されていない端だけ
    func testCapOnlyOnFreeEnds() {
        let a = pipe([Vec3(0, 0, 0), Vec3(2000, 0, 0)], caps: true)
        let b = pipe([Vec3(2000, 0, 0), Vec3(2000, 1500, 0)])   // aの終点に接続
        let j = PipeNetwork.junctions(in: [a, b])
        let caps = (j[a.id] ?? []).filter { if case .cap = $0.kind { return true }; return false }
        XCTAssertEqual(caps.count, 1)
        XCTAssertEqual(caps[0].position, Vec2(0, 0))
        guard case .cap(let dir) = caps[0].kind else { return XCTFail() }
        XCTAssertEqual(dir.x, -1, accuracy: 1e-9)      // 内側→端(-x)
        // capEnds=falseならキャップなし
        XCTAssertNil(PipeNetwork.junctions(in: [pipe([Vec3(0, 0, 0), Vec3(2000, 0, 0)])])[a.id])
    }

    /// 立管で終わる配管の端部方向は直近の水平区間から取る
    func testOutwardDirectionThroughRiser() {
        let pts = [Vec3(0, 0, 0), Vec3(2000, 0, 0), Vec3(2000, 0, 3000)]
        let d = PipeNetwork.outwardDirection(points: pts, atStart: false)
        XCTAssertEqual(d?.x ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(d?.y ?? 1, 0, accuracy: 1e-9)
        XCTAssertNil(PipeNetwork.outwardDirection(points: [Vec3(0, 0, 0), Vec3(0, 0, 3000)], atStart: true))
    }

    /// 継手寸法: マスタ値が入っていればそれ、空なら外径概算
    func testEffectiveFittingDims() {
        let est = PipeAttributes(outerDiameter: 60).effectiveFittingDims
        XCTAssertEqual(est.elbow90A, 54, accuracy: 1e-9)          // 60×0.9
        XCTAssertEqual(est.socketOD, 69, accuracy: 1e-9)          // 60×1.15
        let dims = PipeFittingDims(elbow90A: 50, elbow45A: 30, teeA: 50,
                                   socketDepth: 30, socketOD: 70, capLength: 38)
        XCTAssertFalse(dims.isEmpty)
        XCTAssertEqual(PipeAttributes(outerDiameter: 60, fittingDims: dims).effectiveFittingDims, dims)
        // 複線レイアウトの継手形状はマスタの受口外径・A寸法を使う
        let attrs = PipeAttributes(outerDiameter: 60, annotate: false, doubleLine: true,
                                   fittingDims: dims)
        let layout = PipeGeometry.doubleLineLayout(
            points: [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)], attrs: attrs)!
        XCTAssertEqual(layout.fittings.count, 1)
        guard case .polygon(let poly) = layout.fittings[0].parts[0] else { return XCTFail() }
        // 手前側受口端: 折れ点から-x方向にA=50(x=950)、幅は受口外径70/2=35
        XCTAssertEqual(poly[0].x, 950, accuracy: 1e-9)
        XCTAssertEqual(poly[0].y, -35, accuracy: 1e-9)   // 外側(右折→外側は-y)
    }
}
