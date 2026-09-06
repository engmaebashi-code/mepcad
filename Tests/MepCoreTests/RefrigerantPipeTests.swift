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
        // 三角は本管に沿い、頂点は上流(本管の作図方向+xの手前=−x)に u·0.866、底辺は分岐点で本管に直交
        let u = a.effectiveSymbolSize
        func touches(_ pt: Vec2) -> Bool {
            els.contains {
                if case .segment(let p, let q) = $0 {
                    return p.distance(to: pt) < 1e-6 || q.distance(to: pt) < 1e-6
                }
                return false
            }
        }
        // 底辺は分岐点から上流へ1.0u、頂点はさらに0.866u上流(M8.0b)
        XCTAssertTrue(touches(Vec2(3000 - u * 1.866, 0)))
        XCTAssertTrue(touches(Vec2(3000 - u, u / 2)))
        XCTAssertTrue(touches(Vec2(3000 - u, -u / 2)))
        XCTAssertFalse(touches(Vec2(3000 + u * 0.866, 0)))
    }

    /// 本管の単線は三角の中(頂点〜底辺)で切れる(M8.0b)
    func testHostRunIsCutInsideTriangle() {
        let main = refrigerant([Vec3(0, 0, 0), Vec3(6000, 0, 0)], liquid: "9.52", gas: "15.88")
        let branch = refrigerant([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)])
        let tees = PipeNetwork.junctions(in: [main, branch])[main.id] ?? []
        guard case .pipe(let pts, let a) = main.kind else { return XCTFail() }
        let u = a.effectiveSymbolSize
        let runs = PipeSymbols.singleLineRuns(points: pts, attrs: a, junctions: tees)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].first!, Vec2(0, 0))
        XCTAssertEqual(runs[0].last!.x, 3000 - u * 1.866, accuracy: 1e-6)     // 頂点で止まる
        XCTAssertEqual(runs[1].first!.x, 3000 - u, accuracy: 1e-6)            // 底辺から再開
        XCTAssertEqual(runs[1].last!, Vec2(6000, 0))
    }

    /// 枝の単線は三角の底辺(枝側へ0.2u)から下流へ平行に出て、曲げRで枝の線に乗る(M8.0b)
    func testBranchRunLeavesFromTriangleBase() {
        let main = refrigerant([Vec3(0, 0, 0), Vec3(6000, 0, 0)], liquid: "9.52", gas: "15.88")
        let branch = refrigerant([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)])
        let js = PipeNetwork.junctions(in: [main, branch])[branch.id] ?? []
        guard case .pipe(let pts, let a) = branch.kind else { return XCTFail() }
        let u = a.effectiveSymbolSize
        let runs = PipeSymbols.singleLineRuns(points: pts, attrs: a, junctions: js)
        XCTAssertEqual(runs.count, 1)
        let run = runs[0]
        // 始点は底辺(x=3000−u)の枝側0.2u
        XCTAssertEqual(run.first!.x, 3000 - u, accuracy: 1e-6)
        XCTAssertEqual(run.first!.y, u * 0.2, accuracy: 1e-6)
        // 終点は元の端
        XCTAssertEqual(run.last!, Vec2(3000, 2000))
        // 曲げの弧が入って点が増え、途中の点は本管の芯線(y=0)に触れない
        XCTAssertGreaterThan(run.count, 3)
        XCTAssertTrue(run.allSatisfy { $0.y > 1e-6 })
        // 引き出しの直線部は本管と平行(始点の次の点も y=0.2u)
        XCTAssertEqual(run[1].y, u * 0.2, accuracy: 1e-6)
    }

    /// 「継手を反転」(branchReversed)で三角の頂点が反対側(下流側)へ移る
    func testBranchKitFlipsWithReversedFlag() {
        let main = refrigerant([Vec3(0, 0, 0), Vec3(6000, 0, 0)], liquid: "9.52", gas: "15.88")
        var branch = refrigerant([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)])
        guard case .pipe(let bp, var ba) = branch.kind else { return XCTFail() }
        ba.branchReversed = true
        branch.kind = .pipe(points: bp, attrs: ba)
        let tees = PipeNetwork.junctions(in: [main, branch])[main.id] ?? []
        guard case .pipe(let pts, let a) = main.kind else { return XCTFail() }
        let els = PipeSymbols.elements(points: pts, attrs: a, junctions: tees)
        let u = a.effectiveSymbolSize
        let apex = Vec2(3000 + u * 1.866, 0)
        XCTAssertTrue(els.contains {
            if case .segment(let p, let q) = $0 { return p.distance(to: apex) < 1e-6 || q.distance(to: apex) < 1e-6 }
            return false
        })
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
