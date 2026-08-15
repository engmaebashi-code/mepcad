import XCTest
@testable import MepCore

/// 単線継手シンボル(M6.4)
final class PipeSymbolsTests: XCTestCase {

    private func attrs(series: String, usage: String = "CW", od: Double = 60) -> PipeAttributes {
        PipeAttributes(usage: usage, outerDiameter: od, annotate: false, textHeight: 125,
                       fittingSeries: series,
                       fittingDims: PipeFittingDims(elbow90A: 50, elbow45A: 30, teeA: 50,
                                                    socketDepth: 30, socketOD: 70, capLength: 38))
    }

    /// 排水系(DV): 90°折れ点は受口ティック2本+丸み円弧
    func testDrainElbowSymbols() {
        let pts = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)]
        let els = PipeSymbols.elements(points: pts, attrs: attrs(series: "DV", usage: "S"),
                                       junctions: [])
        let segs = els.filter { if case .segment = $0 { return true }; return false }
        let arcs = els.filter { if case .arc = $0 { return true }; return false }
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(arcs.count, 1)
        // ティックは折れ点からA=50手前(x=950)と先(y=50)、芯線に直交
        guard case .segment(let a, let b) = segs[0] else { return XCTFail() }
        XCTAssertEqual(a.x, 950, accuracy: 1e-9)
        XCTAssertEqual(b.x, 950, accuracy: 1e-9)
        XCTAssertNotEqual(a.y, b.y)
        // 丸みの円弧中心は角の内側(950+25, 25)… r=25 → center=(975, 25)
        guard case .arc(let c, let r, _, _) = arcs[0] else { return XCTFail() }
        XCTAssertEqual(r, 25, accuracy: 1e-9)
        XCTAssertEqual(c.x, 975, accuracy: 1e-9)
        XCTAssertEqual(c.y, 25, accuracy: 1e-9)
    }

    /// 給水系(HI): 折れ点は×印(線分2本)、直進には出ない
    func testSupplyElbowIsCross() {
        let pts = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0), Vec3(1000, 2000, 0)]
        let els = PipeSymbols.elements(points: pts, attrs: attrs(series: "HI"), junctions: [])
        XCTAssertEqual(els.count, 2)   // 折れ点1箇所×2本。直進(1000,1000)は無し
        XCTAssertTrue(els.allSatisfy { if case .segment = $0 { return true }; return false })
    }

    /// 継手Offなら何も出ない
    func testNoSymbolsWhenFittingsOff() {
        var a = attrs(series: "DV")
        a.autoFittings = false
        XCTAssertTrue(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)],
                                           attrs: a, junctions: []).isEmpty)
    }

    /// ネットワーク由来: キャップは○+×(円1+線分2)、レデューサは>形(線分2)、
    /// 排水ティーズはティック3本、給水ティーズは×
    func testJunctionSymbols() {
        let id = EntityID()
        let cap = PipeJunction(pipeID: id, position: Vec2(0, 0), z: 0, kind: .cap(direction: Vec2(-1, 0)))
        let els = PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                       attrs: attrs(series: "DV", usage: "S"), junctions: [cap])
        XCTAssertEqual(els.filter { if case .circle = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(els.filter { if case .segment = $0 { return true }; return false }.count, 2)

        let red = PipeJunction(pipeID: id, position: Vec2(1000, 0), z: 0,
                               kind: .reducer(direction: Vec2(1, 0), otherOD: 48, otherSizeLabel: "40"))
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "HI"), junctions: [red]).count, 2)

        let tee = PipeJunction(pipeID: id, position: Vec2(500, 0), z: 0,
                               kind: .tee(branchDirection: Vec2(0, 1), branchOD: 48, branchSizeLabel: "40"))
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "DV", usage: "S"), junctions: [tee]).count, 3)
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "HI"), junctions: [tee]).count, 2)
    }

    /// 規格未設定でも用途で排水/給水スタイルを判定
    func testDrainStyleFallbackByUsage() {
        XCTAssertTrue(PipeSymbols.isDrainStyle(PipeAttributes(usage: "W")))
        XCTAssertFalse(PipeSymbols.isDrainStyle(PipeAttributes(usage: "CW")))
        XCTAssertTrue(PipeSymbols.isDrainStyle(PipeAttributes(usage: "CW", fittingSeries: "DV")))
    }
}
