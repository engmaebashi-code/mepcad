import XCTest
@testable import MepCore

/// 単線継手シンボル(M6.4)
final class PipeSymbolsTests: XCTestCase {

    /// 基準寸法u=125(紙面2.5mm×1/50)
    private func attrs(series: String, usage: String = "CW", od: Double = 60) -> PipeAttributes {
        PipeAttributes(usage: usage, outerDiameter: od, annotate: false, textHeight: 125,
                       fittingSeries: series,
                       fittingDims: PipeFittingDims(elbow90A: 50, elbow45A: 30, teeA: 50,
                                                    socketDepth: 30, socketOD: 70, capLength: 38),
                       symbolSize: 125)
    }

    /// 排水系(DV): 90°折れ点は折れ点からuの位置に受口ティック2本+脚に接するR=uの丸み
    func testDrainElbowSymbols() {
        let pts = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)]
        let els = PipeSymbols.elements(points: pts, attrs: attrs(series: "DV", usage: "S"),
                                       junctions: [])
        let segs = els.filter { if case .segment = $0 { return true }; return false }
        let arcs = els.filter { if case .arc = $0 { return true }; return false }
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(arcs.count, 1)
        // ティックは折れ点からu=125手前(x=875)、長さu(±62.5)、芯線に直交
        guard case .segment(let a, let b) = segs[0] else { return XCTFail() }
        XCTAssertEqual(a.x, 875, accuracy: 1e-9)
        XCTAssertEqual(b.x, 875, accuracy: 1e-9)
        XCTAssertEqual(abs(a.y - b.y), 125, accuracy: 1e-9)
        // 丸み: R=u=125、中心は角の内側(875, 125)
        guard case .arc(let c, let r, _, _) = arcs[0] else { return XCTFail() }
        XCTAssertEqual(r, 125, accuracy: 1e-9)
        XCTAssertEqual(c.x, 875, accuracy: 1e-9)
        XCTAssertEqual(c.y, 125, accuracy: 1e-9)
        // 45°: R = u/tan(22.5°) ≒ 2.414u
        let pts45 = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(2000, 1000, 0)]
        let els45 = PipeSymbols.elements(points: pts45, attrs: attrs(series: "DV", usage: "S"), junctions: [])
        guard case .arc(_, let r45, _, _)? = els45.first(where: { if case .arc = $0 { return true }; return false })
        else { return XCTFail() }
        XCTAssertEqual(r45, 125 / tan(.pi / 8), accuracy: 1e-6)
    }

    /// 給水系(HI): 折れ点はティック2本(丸みなし)、直進には出ない
    func testSupplyElbowIsTicksOnly() {
        let pts = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0), Vec3(1000, 2000, 0)]
        let els = PipeSymbols.elements(points: pts, attrs: attrs(series: "HI"), junctions: [])
        XCTAssertEqual(els.count, 2)   // 折れ点1箇所×2本。直進(1000,1000)は無し
        XCTAssertTrue(els.allSatisfy { if case .segment = $0 { return true }; return false })
    }

    /// 立管: 手前uにティック。C形の開き方向は水平脚の方向
    func testRiserTickAndLead() {
        let pts = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 0, 2500)]
        let els = PipeSymbols.elements(points: pts, attrs: attrs(series: "DV", usage: "S"), junctions: [])
        XCTAssertEqual(els.count, 1)
        guard case .segment(let a, _) = els[0] else { return XCTFail() }
        XCTAssertEqual(a.x, 875, accuracy: 1e-9)
        let lead = PipeSymbols.riserLead(points: pts, riserIndex: 0)
        XCTAssertEqual(lead?.toward.x ?? 0, -1, accuracy: 1e-9)
        XCTAssertNil(PipeSymbols.riserLead(points: [Vec3(0, 0, 0), Vec3(0, 0, 2500)], riserIndex: 0))
        // 単線の立管記号半径 = u/2
        XCTAssertEqual(PipeGeometry.riserSymbolRadius(attrs(series: "DV", usage: "S")), 62.5, accuracy: 1e-9)
    }

    /// 継手Offなら何も出ない
    func testNoSymbolsWhenFittingsOff() {
        var a = attrs(series: "DV")
        a.autoFittings = false
        XCTAssertTrue(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)],
                                           attrs: a, junctions: []).isEmpty)
    }

    /// ネットワーク由来: キャップは○+×(円1+線分2)、レデューサは▷(線分3)、
    /// ティーズはティック3本(排水・給水とも)、排水の45°枝はY形(3本)
    func testJunctionSymbols() {
        let id = EntityID()
        let cap = PipeJunction(pipeID: id, position: Vec2(0, 0), z: 0, kind: .cap(direction: Vec2(-1, 0)))
        let els = PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                       attrs: attrs(series: "DV", usage: "S"), junctions: [cap])
        XCTAssertEqual(els.filter { if case .circle = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(els.filter { if case .segment = $0 { return true }; return false }.count, 2)

        let red = PipeJunction(pipeID: id, position: Vec2(1000, 0), z: 0,
                               kind: .reducer(direction: Vec2(1, 0), otherOD: 48, otherSizeLabel: "40",
                                              otherDims: PipeFittingDims()))
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "HI"), junctions: [red]).count, 3)

        let tee = PipeJunction(pipeID: id, position: Vec2(500, 0), z: 0,
                               kind: .tee(branchDirection: Vec2(0, 1), branchOD: 48, branchSizeLabel: "40",
                                          branchDims: PipeFittingDims(), mainDirection: Vec2(1, 0)))
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "DV", usage: "S"), junctions: [tee]).count, 3)
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "HI"), junctions: [tee]).count, 3)
        // 45°枝(排水): 主管上流-0.75u/下流+1.25u、枝1.25u
        let y = PipeJunction(pipeID: id, position: Vec2(500, 0), z: 0,
                             kind: .tee(branchDirection: Vec2(0.7071, 0.7071), branchOD: 48, branchSizeLabel: "40",
                                        branchDims: PipeFittingDims(), mainDirection: Vec2(1, 0)))
        let ye = PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                      attrs: attrs(series: "DV", usage: "S"), junctions: [y])
        XCTAssertEqual(ye.count, 3)
        guard case .segment(let ya, _) = ye[0], case .segment(let yb, _) = ye[1] else { return XCTFail() }
        XCTAssertEqual(ya.x, 500 - 0.75 * 125, accuracy: 1e-6)
        XCTAssertEqual(yb.x, 500 + 1.25 * 125, accuracy: 1e-6)
    }

    /// 基準寸法未設定なら文字高さ(排水)・0.8倍(給水)にフォールバック
    func testSymbolSizeFallback() {
        XCTAssertEqual(PipeAttributes(usage: "S", textHeight: 125).effectiveSymbolSize, 125, accuracy: 1e-9)
        XCTAssertEqual(PipeAttributes(usage: "CW", textHeight: 125).effectiveSymbolSize, 100, accuracy: 1e-9)
        XCTAssertEqual(PipeAttributes(usage: "CW", textHeight: 125, symbolSize: 90).effectiveSymbolSize, 90, accuracy: 1e-9)
    }

    /// 規格未設定でも用途で排水/給水スタイルを判定
    func testDrainStyleFallbackByUsage() {
        XCTAssertTrue(PipeSymbols.isDrainStyle(PipeAttributes(usage: "W")))
        XCTAssertFalse(PipeSymbols.isDrainStyle(PipeAttributes(usage: "CW")))
        XCTAssertTrue(PipeSymbols.isDrainStyle(PipeAttributes(usage: "CW", fittingSeries: "DV")))
    }
}
