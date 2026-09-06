import XCTest
@testable import MepCore

/// 冷媒配管(ペア管)M8.0
final class RefrigerantPipeTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    /// 冷媒 φ6.35×φ12.7(被覆銅管、曲げ半径4D)
    private func refrigerant(_ pts: [Vec3], liquid: String = "6.35", gas: String = "12.7") -> Entity {
        Entity(layer: layer,
               kind: .pipe(points: pts,
                           attrs: PipeAttributes(usage: "R", usageName: "冷媒",
                                                 material: "CUR", materialLabel: "Cu",
                                                 size: liquid, sizeLabel: "φ" + liquid,
                                                 outerDiameter: Double(liquid) ?? 6.35,
                                                 annotate: true, annotateMaterial: false,
                                                 bendRadius: 4 * (Double(liquid) ?? 6.35),
                                                 pairSizeLabel: "φ" + gas,
                                                 pairOuterDiameter: Double(gas) ?? 12.7)))
    }

    private func attrs(_ e: Entity) -> PipeAttributes {
        guard case .pipe(_, let a) = e.kind else { fatalError() }
        return a
    }

    /// 傍記は液×ガスの併記
    func testAnnotationShowsPair() {
        var a = attrs(refrigerant([Vec3(0, 0, 0), Vec3(1000, 0, 0)]))
        XCTAssertTrue(a.isPair)
        XCTAssertEqual(PipeGeometry.annotationText(a, z: 0), "φ6.35×φ12.7")
        a.annotateMaterial = true
        XCTAssertEqual(PipeGeometry.annotationText(a, z: 0), "Cu φ6.35×φ12.7")
        a.pairSizeLabel = ""
        XCTAssertFalse(a.isPair)
        XCTAssertEqual(PipeGeometry.annotationText(a, z: 0), "Cu φ6.35")
    }

    /// 分岐点には分岐管の記号(三角=3辺)が出て、ティックの継手記号は出ない
    func testBranchKitSymbolAtTee() {
        let main = refrigerant([Vec3(0, 0, 0), Vec3(6000, 0, 0)], liquid: "9.52", gas: "15.88")
        let branch = refrigerant([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)])
        let js = PipeNetwork.junctions(in: [main, branch])
        let tees = js[main.id] ?? []
        XCTAssertEqual(tees.count, 1)
        guard case .pipe(let pts, let a) = main.kind else { return XCTFail() }
        let els = PipeSymbols.elements(points: pts, attrs: a, junctions: tees)
        XCTAssertEqual(els.count, 3)
        // 三角の頂点は枝の方向(+y)に u·0.866 の位置
        let u = a.effectiveSymbolSize
        let apex = Vec2(3000, u * 0.866)
        let touchesApex = els.contains {
            if case .segment(let p, let q) = $0 {
                return p.distance(to: apex) < 1e-6 || q.distance(to: apex) < 1e-6
            }
            return false
        }
        XCTAssertTrue(touchesApex)
    }

    /// 端部キャップ・口径変更の記号は冷媒配管では出さない
    func testNoCapOrReducerSymbols() {
        var a = attrs(refrigerant([Vec3(0, 0, 0), Vec3(1000, 0, 0)]))
        a.capEnds = true
        let cap = PipeJunction(pipeID: EntityID(), position: Vec2(1000, 0), z: 0,
                               kind: .cap(direction: Vec2(1, 0)))
        let red = PipeJunction(pipeID: EntityID(), position: Vec2(0, 0), z: 0,
                               kind: .reducer(direction: Vec2(-1, 0), otherOD: 6.35,
                                              otherSizeLabel: "φ6.35", otherDims: PipeFittingDims()))
        let els = PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)], attrs: a,
                                       junctions: [cap, red])
        XCTAssertTrue(els.isEmpty)
    }

    /// 折れ点は曲げ(記号なし)、分岐はチーズとして数えられる
    func testCornersBendAndBranchCounts() {
        let main = refrigerant([Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 3000, 0)])
        guard case .pipe(let pts, let a) = main.kind else { return XCTFail() }
        XCTAssertTrue(PipeSymbols.elements(points: pts, attrs: a, junctions: []).isEmpty)
        XCTAssertGreaterThan(PipeSymbols.singleLineRuns(points: pts, attrs: a)[0].count, 3)
    }
}
