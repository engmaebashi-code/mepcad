import XCTest
@testable import MepCore

/// 継手の実形状の不具合回帰(M7.1)
/// - LTの弧が本管の向きで飛んでいく(世界座標軸で弧を作っていた)
/// - 斜めに取り付いた枝で直角用の輪郭が自己交差する
/// - 径違いLTの枝が本管の太さで描かれる
final class FittingShapeTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    /// DV100(A_LL=178, 受口深さ50, 受口外径124, 管外径114)
    private func dv100() -> PipeFittingDims {
        PipeFittingDims(elbow90A: 112, elbow45A: 67, teeA: 113, socketDepth: 50,
                        socketOD: 124, capLength: 58, elbow90LLA: 178, y45A: 193)
    }
    /// DV75(A_LL=140, 受口深さ40, 受口外径97, 管外径89)
    private func dv75() -> PipeFittingDims {
        PipeFittingDims(elbow90A: 88, elbow45A: 53, teeA: 89, socketDepth: 40,
                        socketOD: 97, capLength: 46, elbow90LLA: 140, y45A: 152)
    }

    private func pipe(_ pts: [Vec3], od: Double, dims: PipeFittingDims,
                      branchKind: String = "DT") -> Entity {
        Entity(layer: layer,
               kind: .pipe(points: pts,
                           attrs: PipeAttributes(size: "\(Int(od))", sizeLabel: "\(Int(od))",
                                                 outerDiameter: od, annotate: false,
                                                 doubleLine: true, fittingSeries: "DV",
                                                 fittingDims: dims, branchKind: branchKind)))
    }

    /// 本管に枝が取り付いた図面から、本管側のティーズ継手と本管属性を取り出す
    private func teeShape(mainPoints: [Vec3], mainOD: Double, mainDims: PipeFittingDims,
                          branchPoints: [Vec3], branchOD: Double, branchDims: PipeFittingDims,
                          branchKind: String) -> (PipeFittingShape, PipeAttributes)? {
        let main = pipe(mainPoints, od: mainOD, dims: mainDims)
        let branch = pipe(branchPoints, od: branchOD, dims: branchDims, branchKind: branchKind)
        let js = PipeNetwork.junctions(in: [main, branch])
        guard let tee = js[main.id]?.first(where: { if case .tee = $0.kind { return true }; return false }),
              case .pipe(_, let attrs) = main.kind else { return nil }
        let shapes = PipeNetwork.junctionShapes(tee, attrs: attrs)
        guard let first = shapes.first else { return nil }
        return (first, attrs)
    }

    /// 継手の全頂点を本管座標系(along=本管方向, ny=枝側)に射影した範囲
    private func localBounds(_ shape: PipeFittingShape, origin: Vec2,
                             along: Vec2, ny: Vec2) -> (minX: Double, maxX: Double,
                                                        minY: Double, maxY: Double) {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for p in shape.points {
            let d = p - origin
            let x = d.x * along.x + d.y * along.y
            let y = d.x * ny.x + d.y * ny.y
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        return (minX, maxX, minY, maxY)
    }

    /// LTは本管が縦でも横でも同じ形になる(弧を世界座標軸で作っていると縦のとき飛んでいく)
    func testLTShapeIsOrientationIndependent() {
        // 横向きの本管(+x)に+yへ枝
        guard let (h, _) = teeShape(mainPoints: [Vec3(-3000, 0, 0), Vec3(3000, 0, 0)],
                                    mainOD: 114, mainDims: dv100(),
                                    branchPoints: [Vec3(0, 0, 0), Vec3(0, 2000, 0)],
                                    branchOD: 114, branchDims: dv100(), branchKind: "LT")
        else { return XCTFail("ティーズが出ない") }
        // 縦向きの本管(+y)に+xへ枝
        guard let (v, _) = teeShape(mainPoints: [Vec3(0, -3000, 0), Vec3(0, 3000, 0)],
                                    mainOD: 114, mainDims: dv100(),
                                    branchPoints: [Vec3(0, 0, 0), Vec3(2000, 0, 0)],
                                    branchOD: 114, branchDims: dv100(), branchKind: "LT")
        else { return XCTFail("ティーズが出ない") }

        let hb = localBounds(h, origin: Vec2(0, 0), along: Vec2(1, 0), ny: Vec2(0, 1))
        let vb = localBounds(v, origin: Vec2(0, 0), along: Vec2(0, 1), ny: Vec2(1, 0))
        XCTAssertEqual(hb.minX, vb.minX, accuracy: 0.01)
        XCTAssertEqual(hb.maxX, vb.maxX, accuracy: 0.01)
        XCTAssertEqual(hb.minY, vb.minY, accuracy: 0.01)
        XCTAssertEqual(hb.maxY, vb.maxY, accuracy: 0.01)

        // 本管座標系での範囲: 上流0.53A_LL〜下流A_LL、枝はA_LLまで・逆側は受口半径まで
        let dims = dv100()
        let s = dims.socketOD / 2
        XCTAssertEqual(vb.maxX, dims.elbow90LLA, accuracy: 1.0)          // 下流端 178
        XCTAssertEqual(vb.minX, -dims.elbow90LLA * 0.53, accuracy: 1.0)  // 上流端 −94
        XCTAssertEqual(vb.maxY, dims.elbow90LLA, accuracy: 1.0)          // 枝端 178
        XCTAssertEqual(vb.minY, -s, accuracy: 1.0)                       // 枝の反対側は受口の半径
    }

    /// 径違いLT(100×75)の枝は枝の太さで描かれ、長さも径違いの実寸に寄る
    func testReducingLTUsesBranchSize() {
        guard let (shape, _) = teeShape(mainPoints: [Vec3(0, -3000, 0), Vec3(0, 3000, 0)],
                                        mainOD: 114, mainDims: dv100(),
                                        branchPoints: [Vec3(0, 0, 0), Vec3(2000, 0, 0)],
                                        branchOD: 89, branchDims: dv75(), branchKind: "LT")
        else { return XCTFail("ティーズが出ない") }
        let b = localBounds(shape, origin: Vec2(0, 0), along: Vec2(0, 1), ny: Vec2(1, 0))
        // 枝の長さ: 0.29×178 + 0.71×140 = 151 (DV LTR実測 150)
        XCTAssertEqual(b.maxY, 151, accuracy: 2.0)
        XCTAssertEqual(b.maxX, 151, accuracy: 2.0)   // 下流も同じ長さ
        // 枝先の幅は枝(75)の受口外径97 — 本管(100)の124ではない
        let sb = 97.0 / 2
        var tipWidth = 0.0
        for p in shape.points where abs(p.x - b.maxY) < 1.0 {   // ny=+x なので枝先はx≈maxY
            tipWidth = max(tipWidth, abs(p.y))
        }
        XCTAssertEqual(tipWidth, sb, accuracy: 1.0)
    }

    /// 斜めに取り付いた枝はY形の輪郭で描く(直角用の輪郭は付け根が受口底を追い越して自己交差する)
    func testObliqueBranchUsesYOutline() {
        // 枝を45°方向へ
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)], od: 114, dims: dv100())
        let branch = pipe([Vec3(0, 0, 0), Vec3(2000, 2000, 0)], od: 89, dims: dv75(),
                          branchKind: "DT")
        let js = PipeNetwork.junctions(in: [main, branch])
        guard let tee = js[main.id]?.first(where: { if case .tee = $0.kind { return true }; return false }),
              case .pipe(_, let attrs) = main.kind else { return XCTFail("ティーズが出ない") }
        let shapes = PipeNetwork.junctionShapes(tee, attrs: attrs)
        guard let shape = shapes.first else { return XCTFail() }
        // Y形は「本管部」と「枝」の2つの多角形。直角用は1つの多角形
        let polygons = shape.parts.filter { if case .polygon = $0 { return true }; return false }
        XCTAssertEqual(polygons.count, 2, "斜め分岐はY形(本管部+枝)で描くこと")
        // 枝の付け根が受口底を追い越していない(追い越すと輪郭が折り返す)
        guard case .polygon(let branchPoly) = polygons[1] else { return XCTFail() }
        let bdir = Vec2(cos(Double.pi / 4), sin(Double.pi / 4))
        let along = branchPoly.map { $0.x * bdir.x + $0.y * bdir.y }
        // 枝の輪郭は付け根→受口→先端→受口→付け根の順で、枝方向に単調に進んで戻る
        XCTAssertEqual(along.count, 8)
        XCTAssertLessThanOrEqual(along[0], along[1] + 1e-6)
        XCTAssertLessThanOrEqual(along[1], along[3] + 1e-6)
        XCTAssertLessThanOrEqual(along[7], along[6] + 1e-6)
    }

    /// 直角の枝は従来どおり1つの多角形(同径のDT)
    func testPerpendicularBranchKeepsSingleOutline() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)], od: 114, dims: dv100())
        let branch = pipe([Vec3(0, 0, 0), Vec3(0, 2000, 0)], od: 114, dims: dv100())
        let js = PipeNetwork.junctions(in: [main, branch])
        guard let tee = js[main.id]?.first(where: { if case .tee = $0.kind { return true }; return false }),
              case .pipe(_, let attrs) = main.kind else { return XCTFail() }
        guard let shape = PipeNetwork.junctionShapes(tee, attrs: attrs).first else { return XCTFail() }
        let polygons = shape.parts.filter { if case .polygon = $0 { return true }; return false }
        XCTAssertEqual(polygons.count, 1)
    }

    /// 45°の枝: 枝の受口は実寸の深さがあり、本管の受口底は枝の付け根より外側にある
    /// (受口底が付け根より内側だと受口と枝が重なって継手として成立しない)M7.2
    func testObliqueBranchSocketDepthAndUpstreamClearance() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)], od: 114, dims: dv100())
        // 枝は上流(−x)側へ傾けて取り付ける
        let branch = pipe([Vec3(0, 0, 0), Vec3(-2000, 2000, 0)], od: 89, dims: dv75(),
                          branchKind: "DT")
        let js = PipeNetwork.junctions(in: [main, branch])
        guard let tee = js[main.id]?.first(where: { if case .tee = $0.kind { return true }; return false }),
              case .pipe(_, let attrs) = main.kind,
              let shape = PipeNetwork.junctionShapes(tee, attrs: attrs).first else {
            return XCTFail("ティーズが出ない")
        }
        let polygons: [[Vec2]] = shape.parts.compactMap {
            if case .polygon(let pts) = $0 { return pts }
            return nil
        }
        XCTAssertEqual(polygons.count, 2)
        let host = polygons[0], branchPoly = polygons[1]
        let bdir = Vec2(-cos(Double.pi / 4), sin(Double.pi / 4))   // 枝の方向(上流側へ45°)
        func alongBranch(_ p: Vec2) -> Double { p.x * bdir.x + p.y * bdir.y }

        // 枝の受口の深さ = 受口底(index1)から先端(index3)まで。枝(75)の実寸40mm
        let socket = alongBranch(branchPoly[3]) - alongBranch(branchPoly[1])
        XCTAssertEqual(socket, dv75().socketDepth, accuracy: 0.5,
                       "枝の受口が浅い(実寸の受口深さが要る)")

        // 本管上流の受口底(host[1])は、枝の付け根(branchPoly[0] と [7])より外側(−x側)
        let socketBottomX = host[1].x
        let rootX = min(branchPoly[0].x, branchPoly[7].x)
        XCTAssertLessThan(socketBottomX, rootX, "上流の受口底が枝の付け根と重なっている")

        // 上流(長い側)は下流より長い — 枝が傾く側が上流
        XCTAssertLessThan(host[0].x, 0)
        XCTAssertGreaterThan(abs(host[0].x), abs(host.map(\.x).max()!))
    }
}
