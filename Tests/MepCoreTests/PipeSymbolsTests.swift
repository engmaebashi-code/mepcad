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
                                          branchDims: PipeFittingDims(), mainDirection: Vec2(1, 0),
                                          verticalBranch: false, branchKind: "DT"))
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "DV", usage: "S"), junctions: [tee]).count, 3)
        XCTAssertEqual(PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                            attrs: attrs(series: "HI"), junctions: [tee]).count, 3)
        // 45°枝(排水): 主管上流-0.75u/下流+1.25u、枝1.25u
        let y = PipeJunction(pipeID: id, position: Vec2(500, 0), z: 0,
                             kind: .tee(branchDirection: Vec2(0.7071, 0.7071), branchOD: 48, branchSizeLabel: "40",
                                        branchDims: PipeFittingDims(), mainDirection: Vec2(1, 0),
                                        verticalBranch: false, branchKind: "Y"))
        let ye = PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                      attrs: attrs(series: "DV", usage: "S"), junctions: [y])
        XCTAssertEqual(ye.count, 3)
        guard case .segment(let ya, _) = ye[0], case .segment(let yb, _) = ye[1] else { return XCTFail() }
        // 枝(0.7,0.7)は+x側へ傾く=上流は+x側 → 上流ティック(-0.75u)は+x側、下流(+1.25u)は-x側
        XCTAssertEqual(ya.x, 500 + 0.75 * 125, accuracy: 1e-6)
        XCTAssertEqual(yb.x, 500 - 1.25 * 125, accuracy: 1e-6)
    }

    /// 立てチーズ: 主管±u・枝uのティック+直径uの円。大曲Y(LT): 主管-1.25u/+0.75u+45°スイープ+枝u
    func testVerticalTeeAndLTSymbols() {
        let id = EntityID()
        let vt = PipeJunction(pipeID: id, position: Vec2(500, 0), z: 0,
                              kind: .tee(branchDirection: Vec2(0, 1), branchOD: 60, branchSizeLabel: "50",
                                         branchDims: PipeFittingDims(), mainDirection: Vec2(1, 0),
                                         verticalBranch: true, branchKind: "DT"))
        let els = PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                                       attrs: attrs(series: "DV", usage: "S"), junctions: [vt])
        XCTAssertEqual(els.count, 4)
        XCTAssertTrue(els.contains { if case .circle(let c, let r) = $0 { return c == Vec2(500, 0) && abs(r - 62.5) < 1e-9 }; return false })
        var a = attrs(series: "DV", usage: "S")
        a.longRadius = true
        let lt = PipeJunction(pipeID: id, position: Vec2(500, 0), z: 0,
                              kind: .tee(branchDirection: Vec2(0, 1), branchOD: 60, branchSizeLabel: "50",
                                         branchDims: PipeFittingDims(), mainDirection: Vec2(1, 0),
                                         verticalBranch: false, branchKind: "LT"))
        let le = PipeSymbols.elements(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)], attrs: a, junctions: [lt])
        XCTAssertEqual(le.count, 4)
        guard case .segment(let t1, _) = le[0], case .segment(let t2, _) = le[1],
              case .segment(let s0, let s1) = le[2] else { return XCTFail() }
        XCTAssertEqual(t1.x, 500 - 1.25 * 125, accuracy: 1e-6)
        XCTAssertEqual(t2.x, 500 + 0.75 * 125, accuracy: 1e-6)
        XCTAssertEqual(s0, Vec2(500 - 62.5, 0))
        XCTAssertEqual(s1, Vec2(500, 62.5))
        // 枝側: LT本管への枝端は単線の管体を0.5u手前で切る
        let br = PipeJunction(pipeID: id, position: Vec2(1000, 0), z: 0,
                              kind: .teeBranch(hostDirection: Vec2(0, 1), hostLongRadius: true, vertical: false))
        let runs = PipeSymbols.singleLineRuns(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)], attrs: a, junctions: [br])
        XCTAssertEqual(runs[0].last!.x, 1000 - 62.5, accuracy: 1e-9)
    }

    /// 45°立ち下がり: 平面直進で片脚が勾配 → 水平脚にティック+「))」2本(作図方向へ)。
    /// 立管(段差)は両側の水平脚にティック
    func testTiltMarksAndRiserTicks() {
        // 水平(0..1000, z300) → 勾配(1000..1300, z300→0) → 水平(1300..2000, z0)
        let pts = [Vec3(0, 0, 300), Vec3(1000, 0, 300), Vec3(1300, 0, 0), Vec3(2000, 0, 0)]
        let els = PipeSymbols.elements(points: pts, attrs: attrs(series: "DV", usage: "S"), junctions: [])
        let arcs = els.filter { if case .arc = $0 { return true }; return false }
        let segs = els.filter { if case .segment = $0 { return true }; return false }
        XCTAssertEqual(arcs.count, 4)      // 2箇所×2本
        XCTAssertEqual(segs.count, 2)      // 水平脚のティック×2
        guard case .segment(let a, _) = segs[0] else { return XCTFail() }
        XCTAssertEqual(a.x, 1000 - 125, accuracy: 1e-9)
        // 段差(立管の両側に水平脚): ティック2本
        let step = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 0, 300), Vec3(2000, 0, 300)]
        let se = PipeSymbols.elements(points: step, attrs: attrs(series: "DV", usage: "S"), junctions: [])
        XCTAssertEqual(se.count, 2)
        XCTAssertEqual(PipeSymbols.riserLeads(points: step, riserIndex: 0).count, 2)
    }

    /// 基準寸法未設定なら文字高さ(排水)・0.8倍(給水)にフォールバック
    func testSymbolSizeFallback() {
        XCTAssertEqual(PipeAttributes(usage: "S", textHeight: 125).effectiveSymbolSize, 125, accuracy: 1e-9)
        XCTAssertEqual(PipeAttributes(usage: "CW", textHeight: 125).effectiveSymbolSize, 100, accuracy: 1e-9)
        XCTAssertEqual(PipeAttributes(usage: "CW", textHeight: 125, symbolSize: 90).effectiveSymbolSize, 90, accuracy: 1e-9)
    }

    /// 大曲(LL): 丸みR=4u、接点=4u(90°)、ティックは接点のu先。管体は接点で切れる
    func testLongRadiusCornerAndTrimmedRuns() {
        let g = PipeSymbols.cornerGeometry(unit: 125, turn: .pi / 2, longRadius: true, len1: 2000, len2: 2000)
        XCTAssertEqual(g.radius, 500, accuracy: 1e-9)
        XCTAssertEqual(g.tangent, 500, accuracy: 1e-6)
        XCTAssertEqual(g.tick, 625, accuracy: 1e-6)
        // 脚が短ければ縮む(接点は脚の半分×0.8まで)
        let g2 = PipeSymbols.cornerGeometry(unit: 125, turn: .pi / 2, longRadius: true, len1: 400, len2: 2000)
        XCTAssertEqual(g2.tangent, 160, accuracy: 1e-6)
        XCTAssertEqual(g2.tick, 200, accuracy: 1e-6)   // 接点+u だが脚の半分(200)で頭打ち
        // 排水(DL): 管体は折れ点からuの接点で2本に分かれる
        var a = attrs(series: "DV", usage: "S")
        let pts = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)]
        let runs = PipeSymbols.singleLineRuns(points: pts, attrs: a)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].last!.x, 875, accuracy: 1e-9)
        XCTAssertEqual(runs[1].first!.y, 125, accuracy: 1e-9)
        // 給水は角のまま1本
        XCTAssertEqual(PipeSymbols.singleLineRuns(points: pts, attrs: attrs(series: "HI")).count, 1)
        // 大曲なら丸みR=4u、ティックは5u
        a.longRadius = true
        let els = PipeSymbols.elements(points: pts, attrs: a, junctions: [])
        guard case .arc(_, let r, _, _)? = els.first(where: { if case .arc = $0 { return true }; return false }),
              case .segment(let t0, _) = els[0] else { return XCTFail() }
        XCTAssertEqual(r, 500, accuracy: 1e-6)
        XCTAssertEqual(t0.x, 1000 - 625, accuracy: 1e-6)
    }

    /// 規格未設定でも用途で排水/給水スタイルを判定
    func testDrainStyleFallbackByUsage() {
        XCTAssertTrue(PipeSymbols.isDrainStyle(PipeAttributes(usage: "W")))
        XCTAssertFalse(PipeSymbols.isDrainStyle(PipeAttributes(usage: "CW")))
        XCTAssertTrue(PipeSymbols.isDrainStyle(PipeAttributes(usage: "CW", fittingSeries: "DV")))
    }
}
