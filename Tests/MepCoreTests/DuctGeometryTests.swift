import XCTest
@testable import MepCore

/// ダクトの平面ジオメトリ(M9.0)
final class DuctGeometryTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    private func duct(_ pts: [Vec3], shape: DuctSpec.Shape = .rect, w: Double = 600, h: Double = 300,
                      hopper: Bool = false) -> Entity {
        let spec = DuctSpec(shape: shape, width: w, height: h, hopperBranch: hopper)
        return Entity(layer: layer,
                      kind: .pipe(points: pts,
                                  attrs: PipeAttributes(usage: "SA", usageName: "給気", material: "DUCT",
                                                        materialLabel: "", size: spec.sizeLabel,
                                                        sizeLabel: spec.sizeLabel, outerDiameter: w,
                                                        annotate: true, doubleLine: true,
                                                        annotateMaterial: false,
                                                        branchKind: hopper ? "H" : "T",
                                                        bendRadius: shape == .flex ? w : 0, duct: spec)))
    }

    private func layout(_ e: Entity, in all: [Entity]) -> PipeDoubleLineLayout? {
        guard case .pipe(let pts, let a) = e.kind else { return nil }
        let js = PipeNetwork.junctions(in: all)[e.id] ?? []
        return PipeGeometry.doubleLineLayout(points: pts, attrs: a, junctions: js)
    }

    private func polylines(_ l: PipeDoubleLineLayout) -> [[Vec2]] {
        l.fittings.flatMap { $0.parts.compactMap { if case .polyline(let p) = $0 { return p }; return nil } }
    }

    /// 90°エルボ: 壁が弧(内R=W/2・外R=1.5W)になり、両端に継目の線。芯線は描かない
    func testRectElbow() throws {
        let e = duct([Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 3000, 0)])
        let l = try XCTUnwrap(layout(e, in: [e]))
        XCTAssertEqual(l.runs.count, 1)
        XCTAssertTrue(l.runs[0].center.isEmpty)
        XCTAssertGreaterThan(l.runs[0].left.count, 6)
        // 内側(左折なので左壁)の弧は中心(2400, 600)から半径300
        let c = Vec2(3000 - 600, 600)
        let inner = l.runs[0].left.filter { abs($0.distance(to: c) - 300) < 1e-6 }
        XCTAssertGreaterThan(inner.count, 3)
        let outer = l.runs[0].right.filter { abs($0.distance(to: c) - 900) < 1e-6 }
        XCTAssertGreaterThan(outer.count, 3)
        XCTAssertEqual(polylines(l).count, 2)          // 継目2本
        XCTAssertEqual(l.endCaps.count, 2)
    }

    /// 直付け分岐: 本ダクトは枝の幅ぶん壁が開き、枝は本ダクトの壁で止まって端を閉じない
    func testTeeBranchOpensHostWall() throws {
        let host = duct([Vec3(0, 0, 0), Vec3(6000, 0, 0)])
        let branch = duct([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)], w: 300, h: 250)
        let hl = try XCTUnwrap(layout(host, in: [host, branch]))
        // 枝側(+y=左壁)が2本に割れる
        XCTAssertEqual(hl.runs.count, 2)
        let leftPieces = hl.runs.map(\.left).filter { !$0.isEmpty }
        XCTAssertEqual(leftPieces.count, 2)
        XCTAssertEqual(leftPieces[0].last!.x, 2850, accuracy: 1e-6)
        XCTAssertEqual(leftPieces[1].first!.x, 3150, accuracy: 1e-6)
        XCTAssertEqual(leftPieces[0].last!.y, 300, accuracy: 1e-6)
        // 右壁(反対側)は切れない
        XCTAssertEqual(hl.runs[0].right.count, 2)

        let bl = try XCTUnwrap(layout(branch, in: [host, branch]))
        XCTAssertEqual(bl.runs[0].left.first!.y, 300, accuracy: 1e-6)     // 本ダクトの壁で止まる
        XCTAssertEqual(bl.runs[0].left.first!.x, 2850, accuracy: 1e-6)
        XCTAssertEqual(bl.endCaps.count, 1)                              // 分岐側は開いたまま
    }

    /// ホッパー分岐: 枝の端が45°で広がり、本ダクトの開口もその分広い
    func testHopperBranch() throws {
        let host = duct([Vec3(0, 0, 0), Vec3(6000, 0, 0)])
        let branch = duct([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)], w: 300, h: 250, hopper: true)
        let h = DuctGeometry.hopperFlare(branchWidth: 300)
        XCTAssertEqual(h, 150, accuracy: 1e-9)
        let hl = try XCTUnwrap(layout(host, in: [host, branch]))
        let leftPieces = hl.runs.map(\.left).filter { !$0.isEmpty }
        XCTAssertEqual(leftPieces[0].last!.x, 2700, accuracy: 1e-6)
        XCTAssertEqual(leftPieces[1].first!.x, 3300, accuracy: 1e-6)
        let bl = try XCTUnwrap(layout(branch, in: [host, branch]))
        let left = bl.runs[0].left
        XCTAssertEqual(left[0].x, 2700, accuracy: 1e-6)                  // 外へ150広がる
        XCTAssertEqual(left[0].y, 300, accuracy: 1e-6)
        XCTAssertEqual(left[1].x, 2850, accuracy: 1e-6)                  // 45°の折れ点
        XCTAssertEqual(left[1].y, 450, accuracy: 1e-6)
        let right = bl.runs[0].right
        XCTAssertEqual(right[0].x, 3300, accuracy: 1e-6)
    }

    /// 変形: 幅の違うダクトを突き合わせると太い側の端が片側30°で絞られる
    func testTransitionAtReducer() throws {
        let big = duct([Vec3(0, 0, 0), Vec3(3000, 0, 0)])
        let small = duct([Vec3(3000, 0, 0), Vec3(6000, 0, 0)], w: 400, h: 250)
        let bl = try XCTUnwrap(layout(big, in: [big, small]))
        let len = DuctGeometry.transitionLength(from: 600, to: 400)
        XCTAssertEqual(len, 100 / tan(Double.pi / 6), accuracy: 1e-9)
        XCTAssertEqual(bl.runs[0].left.last!.x, 3000 - len, accuracy: 1e-6)
        XCTAssertEqual(bl.endCaps.count, 1)                              // 突き合わせ側は絞りに置き換わる
        let lines = polylines(bl)
        XCTAssertEqual(lines.count, 3)                                   // 斜線2+太い側の終わり
        XCTAssertTrue(lines.contains { $0.last!.distance(to: Vec2(3000, 200)) < 1e-6 })
        XCTAssertTrue(lines.contains { $0.last!.distance(to: Vec2(3000, -200)) < 1e-6 })
        // 細い側はそのまま(端の線が継目になる)
        let sl = try XCTUnwrap(layout(small, in: [big, small]))
        XCTAssertEqual(sl.endCaps.count, 2)
    }

    /// フレキ: 壁が波線(点が多く、直線から外れる)
    func testFlexWalls() throws {
        let e = duct([Vec3(0, 0, 0), Vec3(3000, 0, 0)], shape: .flex, w: 200, h: 0)
        let l = try XCTUnwrap(layout(e, in: [e]))
        XCTAssertGreaterThan(l.runs[0].left.count, 20)
        let ys = Set(l.runs[0].left.map { ($0.y * 10).rounded() })
        XCTAssertGreaterThan(ys.count, 3)
        XCTAssertTrue(polylines(l).isEmpty)                              // 継目は出さない
    }

    /// キャンバス: 壁は直線、その間にジグザグ
    func testCanvasZigzag() throws {
        let e = duct([Vec3(0, 0, 0), Vec3(300, 0, 0)], shape: .canvas, w: 600, h: 300)
        let l = try XCTUnwrap(layout(e, in: [e]))
        XCTAssertEqual(l.runs[0].left.count, 2)
        let zig = polylines(l)
        XCTAssertEqual(zig.count, 1)
        XCTAssertGreaterThanOrEqual(zig[0].count, 3)
        XCTAssertTrue(zig[0].contains { abs($0.y - 300) < 1e-6 })
        XCTAssertTrue(zig[0].contains { abs($0.y + 300) < 1e-6 })
    }

    /// 傍記: 角はW×H、丸はφD、フレキ・キャンバスは種別を添える
    func testAnnotation() {
        var a = PipeAttributes(duct: DuctSpec(shape: .rect, width: 600, height: 300))
        a.annotateMaterial = false
        XCTAssertEqual(PipeGeometry.annotationText(a, z: 0), "600×300")
        a.duct = DuctSpec(shape: .round, width: 300)
        XCTAssertEqual(PipeGeometry.annotationText(a, z: 0), "φ300")
        a.duct = DuctSpec(shape: .flex, width: 150)
        XCTAssertEqual(PipeGeometry.annotationText(a, z: 0), "φ150 フレキ")
        XCTAssertEqual(DuctSpec(shape: .rect, width: 600, height: 300).perimeter, 1800, accuracy: 1e-9)
    }

    /// 壁の線へスナップして描いた枝(端が芯線から本ダクトの半幅の位置)も分岐になる(M9.1)
    func testBranchSnappedToWallConnects() throws {
        let host = duct([Vec3(0, 0, 0), Vec3(6000, 0, 0)])
        let branch = duct([Vec3(3000, 300, 0), Vec3(3000, 2000, 0)], w: 300, h: 250)
        let js = PipeNetwork.junctions(in: [host, branch])
        XCTAssertEqual(js[host.id]?.count, 1)
        XCTAssertEqual(js[branch.id]?.count, 1)
        let hl = try XCTUnwrap(layout(host, in: [host, branch]))
        let leftPieces = hl.runs.map(\.left).filter { !$0.isEmpty }
        XCTAssertEqual(leftPieces.count, 2)
        XCTAssertEqual(leftPieces[0].last!.x, 2850, accuracy: 1e-6)
        let bl = try XCTUnwrap(layout(branch, in: [host, branch]))
        XCTAssertEqual(bl.runs[0].left.first!.y, 300, accuracy: 1e-6)       // 切り詰めなしで壁に揃う
        XCTAssertEqual(bl.runs[0].left.last!.y, 2000, accuracy: 1e-6)
        XCTAssertEqual(bl.endCaps.count, 1)
    }

    /// 配管同士は従来どおり芯線上でしか繋がらない(壁の緩和はダクト同士だけ)
    func testPipesStillRequireCenterline() {
        let a = Entity(layer: layer, kind: .pipe(points: [Vec3(0, 0, 0), Vec3(6000, 0, 0)],
                                                  attrs: PipeAttributes(outerDiameter: 114, doubleLine: true)))
        let b = Entity(layer: layer, kind: .pipe(points: [Vec3(3000, 40, 0), Vec3(3000, 2000, 0)],
                                                  attrs: PipeAttributes(outerDiameter: 89, doubleLine: true)))
        XCTAssertNil(PipeNetwork.junctions(in: [a, b])[a.id])
    }

    /// 45°の枝: 本ダクトの開口は枝の幅/sin45°に広がり、枝の壁の端は本ダクトの壁の線に揃う
    func testObliqueBranch() throws {
        let host = duct([Vec3(0, 0, 0), Vec3(6000, 0, 0)])
        let branch = duct([Vec3(3000, 0, 0), Vec3(5000, 2000, 0)], w: 300, h: 250)
        let hl = try XCTUnwrap(layout(host, in: [host, branch]))
        let leftPieces = hl.runs.map(\.left).filter { !$0.isEmpty }
        XCTAssertEqual(leftPieces.count, 2)
        let s = 2.0.squareRoot()
        // 軸が壁と交わる x=3300 を中心に、幅 300·√2 の開口
        XCTAssertEqual(leftPieces[0].last!.x, 3300 - 150 * s, accuracy: 1e-6)
        XCTAssertEqual(leftPieces[1].first!.x, 3300 + 150 * s, accuracy: 1e-6)
        let bl = try XCTUnwrap(layout(branch, in: [host, branch]))
        XCTAssertEqual(bl.runs[0].left.first!.y, 300, accuracy: 1e-6)
        XCTAssertEqual(bl.runs[0].right.first!.y, 300, accuracy: 1e-6)
        XCTAssertEqual(bl.runs[0].left.first!.x, 3300 - 150 * s, accuracy: 1e-6)
        XCTAssertEqual(bl.runs[0].right.first!.x, 3300 + 150 * s, accuracy: 1e-6)
    }

    /// ダクトには配管の継手形状(ソケット等)は出ない
    func testNoPipeFittingShapesForDuct() {
        let host = duct([Vec3(0, 0, 0), Vec3(6000, 0, 0)])
        let branch = duct([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)], w: 300, h: 250)
        let js = PipeNetwork.junctions(in: [host, branch])
        guard let tee = js[host.id]?.first, case .pipe(_, let a) = host.kind else { return XCTFail() }
        XCTAssertTrue(PipeNetwork.junctionShapes(tee, attrs: a).isEmpty)
        XCTAssertEqual(js[branch.id]?.first?.hostOD ?? 0, 600, accuracy: 1e-9)
    }
}
