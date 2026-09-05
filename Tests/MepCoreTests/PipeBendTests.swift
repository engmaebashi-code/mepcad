import XCTest
@testable import MepCore

/// 可撓管の曲げ(M7.9)
final class PipeBendTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    /// PEX13A(外径17) 曲げ半径136
    private func pex(_ pts: [Vec3], doubleLine: Bool = true) -> Entity {
        Entity(layer: layer,
               kind: .pipe(points: pts,
                           attrs: PipeAttributes(usage: "CW", usageName: "給水",
                                                 material: "PEX", materialLabel: "PEX",
                                                 size: "13", sizeLabel: "13", outerDiameter: 17,
                                                 annotate: false, doubleLine: doubleLine,
                                                 fittingSeries: "TS", bendRadius: 136)))
    }

    private func attrs(_ e: Entity) -> PipeAttributes {
        guard case .pipe(_, let a) = e.kind else { fatalError() }
        return a
    }

    /// 90°の折れ点: 直線→半径Rの円弧(左折=+90°)→直線。接点はRだけ手前/先
    func testRightAngleCornerBecomesArc() {
        let pieces = PipeBend.pieces([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000)], radius: 136)
        XCTAssertEqual(pieces.count, 3)
        guard case .line(let a, let b) = pieces[0],
              case .arc(let c, let r, _, let sweep) = pieces[1],
              case .line(let d, let e) = pieces[2] else { return XCTFail("直線・円弧・直線でない") }
        XCTAssertEqual(a, Vec2(0, 0))
        XCTAssertEqual(b.x, 864, accuracy: 1e-6)
        XCTAssertEqual(r, 136, accuracy: 1e-9)
        XCTAssertEqual(c.x, 864, accuracy: 1e-6)
        XCTAssertEqual(c.y, 136, accuracy: 1e-6)
        XCTAssertEqual(sweep, Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(d.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(d.y, 136, accuracy: 1e-6)
        XCTAssertEqual(e, Vec2(1000, 1000))
    }

    /// 右折は回転角が負、45°は接線長 R·tan(22.5°)
    func testRightTurn45() {
        let pieces = PipeBend.pieces([Vec2(0, 0), Vec2(1000, 0), Vec2(2000, -1000)], radius: 136)
        guard case .arc(_, let r, _, let sweep) = pieces[1],
              case .line(_, let b) = pieces[0] else { return XCTFail() }
        XCTAssertEqual(r, 136, accuracy: 1e-9)
        XCTAssertEqual(sweep, -Double.pi / 4, accuracy: 1e-9)
        XCTAssertEqual(1000 - b.x, 136 * tan(Double.pi / 8), accuracy: 1e-6)
    }

    /// 脚が短くて規定Rが収まらないときは収まる半径まで小さくする
    func testShortLegShrinksRadius() {
        let pieces = PipeBend.pieces([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)], radius: 136)
        let arcs = pieces.compactMap { p -> Double? in
            if case .arc(_, let r, _, _) = p { return r }
            return nil
        }
        XCTAssertEqual(arcs.count, 1)
        XCTAssertEqual(arcs[0], 100, accuracy: 1e-6)
    }

    /// 直進(折れ無し)・半径0なら直線だけ
    func testStraightOrZeroRadiusStaysLines() {
        let straight = PipeBend.pieces([Vec2(0, 0), Vec2(500, 0), Vec2(1000, 0)], radius: 136)
        XCTAssertTrue(straight.allSatisfy { if case .line = $0 { return true }; return false })
        let zero = PipeBend.pieces([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000)], radius: 0)
        XCTAssertEqual(zero.count, 2)
    }

    /// 外形線のオフセット: 左折の左線は内側(R−r)、右線は外側(R+r)
    func testOffsetPolylinesFollowArc() {
        let pieces = PipeBend.pieces([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000)], radius: 136)
        let center = Vec2(864, 136)
        let left = PipeBend.polyline(pieces, offset: 8.5)
        let right = PipeBend.polyline(pieces, offset: -8.5)
        let mid = PipeBend.polyline(pieces, offset: 0)
        XCTAssertGreaterThan(mid.count, 6)                      // 円弧が折れ線に展開されている
        // 弧の中央付近(45°)の点
        func at45(_ pts: [Vec2]) -> Vec2? {
            pts.min(by: { abs(atan2($0.y - center.y, $0.x - center.x) + Double.pi / 4)
                        < abs(atan2($1.y - center.y, $1.x - center.x) + Double.pi / 4) })
        }
        XCTAssertEqual(at45(left)!.distance(to: center), 136 - 8.5, accuracy: 1e-6)
        XCTAssertEqual(at45(right)!.distance(to: center), 136 + 8.5, accuracy: 1e-6)
        XCTAssertEqual(at45(mid)!.distance(to: center), 136, accuracy: 1e-6)
        // 端は元の端点をオフセットした位置
        XCTAssertEqual(left.first!, Vec2(0, 8.5))
        XCTAssertEqual(right.last!.x, 1008.5, accuracy: 1e-6)
    }

    /// 複線レイアウト: 可撓管は折れ点にエルボを作らず、外形線が弧に沿う。端の閉じ線は残る
    func testDoubleLineLayoutHasNoElbowForBentPipe() {
        let e = pex([Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)])
        guard case .pipe(let pts, let a) = e.kind,
              let layout = PipeGeometry.doubleLineLayout(points: pts, attrs: a) else { return XCTFail() }
        XCTAssertTrue(layout.fittings.isEmpty)
        XCTAssertEqual(layout.runs.count, 1)
        XCTAssertGreaterThan(layout.runs[0].left.count, 6)
        XCTAssertEqual(layout.endCaps.count, 2)
        // 同じ形の直管(曲げ半径0)ならエルボが出る
        var rigid = a
        rigid.bendRadius = 0
        let rigidLayout = PipeGeometry.doubleLineLayout(points: pts, attrs: rigid)
        XCTAssertEqual(rigidLayout?.fittings.count, 1)
    }

    /// 単線: 芯線が弧に沿い、折れ点のエルボ記号(ティック)は出ない
    func testSingleLineBentPipeHasNoCornerSymbols() {
        let e = pex([Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 1000, 0)], doubleLine: false)
        guard case .pipe(let pts, let a) = e.kind else { return XCTFail() }
        let runs = PipeSymbols.singleLineRuns(points: pts, attrs: a)
        XCTAssertEqual(runs.count, 1)
        XCTAssertGreaterThan(runs[0].count, 6)
        XCTAssertTrue(PipeSymbols.elements(points: pts, attrs: a, junctions: []).isEmpty)
    }

    /// 分岐(チーズ)は可撓管でも位置関係から発生する
    func testBentPipeStillGetsTee() {
        let main = pex([Vec3(0, 0, 0), Vec3(2000, 0, 0), Vec3(2000, 2000, 0)])
        let branch = pex([Vec3(1000, 0, 0), Vec3(1000, 800, 0)])
        let js = PipeNetwork.junctions(in: [main, branch])
        XCTAssertEqual(js[main.id]?.count, 1)
        if case .tee = js[main.id]?.first?.kind {} else { XCTFail("チーズでない") }
    }
}
