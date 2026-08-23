import XCTest
@testable import MepTools
@testable import MepCore

/// M4.9: 伸縮(グリップ編集)のテスト
final class GripTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    // MARK: - グリップ一覧

    func testGripsForLine() {
        let e = Entity(layer: layer, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        let grips = GripEngine.grips(for: e)
        XCTAssertEqual(grips.count, 2)
        XCTAssertEqual(grips[0].kind, .lineStart)
        XCTAssertEqual(grips[0].point, Vec2(0, 0))
        XCTAssertEqual(grips[1].kind, .lineEnd)
        XCTAssertEqual(grips[1].point, Vec2(100, 0))
        XCTAssertTrue(grips.allSatisfy { $0.entityID == e.id })
    }

    func testGripsForCircleAreQuadrants() {
        let e = Entity(layer: layer, kind: .circle(center: Vec2(10, 20), radius: 5))
        let grips = GripEngine.grips(for: e)
        XCTAssertEqual(grips.count, 4)
        XCTAssertEqual(grips[0].point.x, 15, accuracy: 1e-9)   // +X
        XCTAssertEqual(grips[0].point.y, 20, accuracy: 1e-9)
        XCTAssertEqual(grips[1].point.x, 10, accuracy: 1e-9)   // +Y
        XCTAssertEqual(grips[1].point.y, 25, accuracy: 1e-9)
    }

    func testGripsForArcAreEndpoints() {
        let e = Entity(layer: layer, kind: .arc(center: Vec2(0, 0), radius: 10,
                                                startAngle: 0, endAngle: .pi / 2))
        let grips = GripEngine.grips(for: e)
        XCTAssertEqual(grips.count, 2)
        XCTAssertEqual(grips[0].point.x, 10, accuracy: 1e-9)
        XCTAssertEqual(grips[0].point.y, 0, accuracy: 1e-9)
        XCTAssertEqual(grips[1].point.x, 0, accuracy: 1e-9)
        XCTAssertEqual(grips[1].point.y, 10, accuracy: 1e-9)
    }

    func testGripsForTextPointBlockAreSinglePosition() {
        let t = Entity(layer: layer, kind: .text(position: Vec2(1, 2), content: "FCU",
                                                 height: 5, angle: 0))
        let p = Entity(layer: layer, kind: .point(position: Vec2(3, 4)))
        let b = Entity(layer: layer,
                       kind: .blockRef(definitionID: UUID(), insert: Vec2(5, 6),
                                       rotation: 0, scale: 1, mirrored: false,
                                       cachedBounds: BBox(minX: 0, minY: 0, maxX: 10, maxY: 10)))
        for (e, expect) in [(t, Vec2(1, 2)), (p, Vec2(3, 4)), (b, Vec2(5, 6))] {
            let grips = GripEngine.grips(for: e)
            XCTAssertEqual(grips.count, 1)
            XCTAssertEqual(grips[0].kind, .position)
            XCTAssertEqual(grips[0].point, expect)
        }
    }

    // MARK: - グリップ適用(伸縮)

    func testApplyLineEndStretches() {
        let e = Entity(layer: layer, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        let out = GripEngine.apply(.lineEnd, to: e, at: Vec2(250, 0))
        guard case .line(let a, let b) = out.kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(0, 0))                     // 反対端は固定
        XCTAssertEqual(b, Vec2(250, 0))
        XCTAssertEqual(out.id, e.id)                      // idは維持(Undo/選択継続)
    }

    func testApplyLineStartStretches() {
        let e = Entity(layer: layer, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        let out = GripEngine.apply(.lineStart, to: e, at: Vec2(-50, 30))
        guard case .line(let a, let b) = out.kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(-50, 30))
        XCTAssertEqual(b, Vec2(100, 0))
    }

    func testApplyCircleRadius() {
        let e = Entity(layer: layer, kind: .circle(center: Vec2(10, 10), radius: 5))
        let out = GripEngine.apply(.circleRadius(quadrant: 0), to: e, at: Vec2(40, 10))
        guard case .circle(let c, let r) = out.kind else { return XCTFail() }
        XCTAssertEqual(c, Vec2(10, 10))                   // 中心は固定
        XCTAssertEqual(r, 30, accuracy: 1e-9)
    }

    func testApplyArcEndChangesAngleKeepsRadius() {
        let e = Entity(layer: layer, kind: .arc(center: Vec2(0, 0), radius: 10,
                                                startAngle: 0, endAngle: .pi / 2))
        // 端点を(-10, 0)方向へ → 終了角がπに(半径は10のまま。距離は無関係)
        let out = GripEngine.apply(.arcEnd, to: e, at: Vec2(-99, 0))
        guard case .arc(_, let r, let sa, let ea) = out.kind else { return XCTFail() }
        XCTAssertEqual(r, 10, accuracy: 1e-9)
        XCTAssertEqual(sa, 0, accuracy: 1e-9)
        XCTAssertEqual(ea, .pi, accuracy: 1e-9)
    }

    func testApplyPositionMovesBlockRefWithBounds() {
        let box = BBox(minX: -10, minY: -10, maxX: 10, maxY: 10)
        let e = Entity(layer: layer,
                       kind: .blockRef(definitionID: UUID(), insert: Vec2(0, 0),
                                       rotation: 0, scale: 1, mirrored: false,
                                       cachedBounds: box))
        let out = GripEngine.apply(.position, to: e, at: Vec2(500, 300))
        guard case .blockRef(_, let insert, _, _, _, let cached) = out.kind else { return XCTFail() }
        XCTAssertEqual(insert, Vec2(500, 300))
        XCTAssertEqual(cached.minX, 490, accuracy: 1e-9)  // 境界キャッシュも追随
        XCTAssertEqual(cached.maxY, 310, accuracy: 1e-9)
    }

    func testApplyDegenerateReturnsOriginal() {
        // 端点を反対端と同じ点へ → 退化するので元のまま
        let e = Entity(layer: layer, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        XCTAssertEqual(GripEngine.apply(.lineEnd, to: e, at: Vec2(0, 0)), e)
        // 円の半径を中心へ → 半径0は不可
        let c = Entity(layer: layer, kind: .circle(center: Vec2(5, 5), radius: 5))
        XCTAssertEqual(GripEngine.apply(.circleRadius(quadrant: 0), to: c, at: Vec2(5, 5)), c)
        // 不正な組合せ(円に線グリップ)も元のまま
        XCTAssertEqual(GripEngine.apply(.lineEnd, to: c, at: Vec2(9, 9)), c)
    }

    // MARK: - 固定点(数値入力の基準)

    func testFixedPoints() {
        let l = Entity(layer: layer, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        XCTAssertEqual(GripEngine.fixedPoint(for: .lineStart, of: l), Vec2(100, 0))
        XCTAssertEqual(GripEngine.fixedPoint(for: .lineEnd, of: l), Vec2(0, 0))
        let c = Entity(layer: layer, kind: .circle(center: Vec2(7, 8), radius: 3))
        XCTAssertEqual(GripEngine.fixedPoint(for: .circleRadius(quadrant: 2), of: c), Vec2(7, 8))
        XCTAssertNil(GripEngine.fixedPoint(for: .position, of: l))
    }

    // MARK: - スナップ索引の除外(編集中の自己吸着防止)

    // MARK: - 寸法グリップ(M5.4.1: 補助線の2本同時伸縮)

    func makeDim(extensionLength: Double? = nil) -> Entity {
        Entity(layer: layer,
               kind: .dimension(a: Vec2(0, 0), b: Vec2(1000, 0),
                                linePoint: Vec2(0, 500), angle: 0,
                                attrs: DimAttributes(terminator: .dot, textHeight: 125,
                                                     extensionLength: extensionLength)))
    }

    /// 寸法のグリップ: 測定点2+寸法線位置1+補助線の端2
    func testGripsForDimension() {
        let grips = GripEngine.grips(for: makeDim())
        XCTAssertEqual(grips.count, 5)
        XCTAssertEqual(grips[0].kind, .dimStart)
        XCTAssertEqual(grips[0].point, Vec2(0, 0))
        XCTAssertEqual(grips[1].kind, .dimEnd)
        XCTAssertEqual(grips[2].kind, .dimLine)
        XCTAssertEqual(grips[2].point.x, 500, accuracy: 1e-9)
        XCTAssertEqual(grips[2].point.y, 500, accuracy: 1e-9)
        // 補助線の端=測定点側の始点(測定点までモードでは gap=50 の位置)
        XCTAssertEqual(grips[3].kind, .dimExtension)
        XCTAssertEqual(grips[3].point.y, 50, accuracy: 1e-9)
        XCTAssertEqual(grips[4].kind, .dimExtension)
    }

    /// 補助線グリップのドラッグ: 寸法線からの垂直距離が長さになる(2本同時)
    func testApplyDimExtensionDrag() {
        let dim = makeDim()
        // 寸法線(y=500)から200mmの位置へドラッグ → 長さ200
        let e = GripEngine.apply(.dimExtension, to: dim, at: Vec2(0, 300))
        guard case .dimension(_, _, _, _, let attrs) = e.kind else { return XCTFail() }
        XCTAssertEqual(attrs.extensionLength ?? -1, 200, accuracy: 1e-9)
        // レイアウトも2本とも始点y=300になる
        let layout = DimensionGeometry.layout(of: e)!
        XCTAssertEqual(layout.extLines.count, 2)
        XCTAssertEqual(layout.extLines[0].0.y, 300, accuracy: 1e-9)
        XCTAssertEqual(layout.extLines[1].0.y, 300, accuracy: 1e-9)
    }

    /// 測定点の近くまで引っ張ると「測定点まで」(nil)に戻る
    func testApplyDimExtensionDragToMeasurePoint() {
        let dim = makeDim(extensionLength: 100)
        // 測定点(y=0)近くへ(gap=50以内: 500-50=450以上の長さになる位置)
        let e = GripEngine.apply(.dimExtension, to: dim, at: Vec2(500, 20))
        guard case .dimension(_, _, _, _, let attrs) = e.kind else { return XCTFail() }
        XCTAssertNil(attrs.extensionLength)
    }

    /// 寸法線ぎりぎりまで縮めても補助線は消えない(最小長=gapの半分。「なし」は選択肢から)
    func testApplyDimExtensionDragNeverVanishes() {
        let dim = makeDim()
        let e = GripEngine.apply(.dimExtension, to: dim, at: Vec2(500, 499))
        guard case .dimension(_, _, _, _, let attrs) = e.kind else { return XCTFail() }
        XCTAssertEqual(attrs.extensionLength ?? -1, 25, accuracy: 1e-9)  // gap50の半分
        XCTAssertEqual(DimensionGeometry.layout(of: e)!.extLines.count, 2)
    }

    /// 寸法線の反対側へドラッグしても距離の絶対値で効く
    func testApplyDimExtensionDragOppositeSide() {
        let dim = makeDim()
        let e = GripEngine.apply(.dimExtension, to: dim, at: Vec2(500, 800))
        guard case .dimension(_, _, _, _, let attrs) = e.kind else { return XCTFail() }
        XCTAssertEqual(attrs.extensionLength ?? -1, 300, accuracy: 1e-9)
    }

    func testSnapRebuildExcluding() {
        let doc = Document()
        let e1 = Entity(layer: layer, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        let e2 = Entity(layer: layer, kind: .line(a: Vec2(1000, 0), b: Vec2(1100, 0)))
        doc.appendBulk([e1, e2])

        let engine = SnapEngine()
        engine.settings.grid = false
        engine.rebuild(from: doc, excluding: [e1.id])
        // e1の端点(0,0)には吸着しない
        XCTAssertNil(engine.snap(Vec2(2, 2), radius: 10))
        // e2の端点(1000,0)には吸着する
        let r = engine.snap(Vec2(1002, 2), radius: 10)
        XCTAssertEqual(r?.point, Vec2(1000, 0))
    }

    // MARK: - 配管の伸縮(M7.1)

    /// 配管の頂点グリップは既定で「伸縮」— 継手の角度を保ったまま脚が伸び縮みする
    func testPipeVertexGripPreservesFittingAngles() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 4000, 0)]
        let entity = Entity(layer: LayerAddress(0, 0),
                            kind: .pipe(points: pts, attrs: PipeAttributes()))
        let kept = GripEngine.apply(.pipeVertex(index: 1), to: entity, at: Vec2(4500, 500))
        guard case .pipe(let keptPts, _) = kept.kind else { return XCTFail() }
        XCTAssertEqual(PipeGeometry.fittings(points: keptPts).first?.kind, .elbow90)
        XCTAssertEqual(keptPts[1].xy, Vec2(4500, 500))   // 掴んだ点はカーソルに追随

        // 切ると従来どおり頂点だけが自由に動く(角度も変わる)
        let free = GripEngine.apply(.pipeVertex(index: 1), to: entity, at: Vec2(4500, 500),
                                    preserveAngles: false)
        guard case .pipe(let freePts, _) = free.kind else { return XCTFail() }
        XCTAssertEqual(freePts[0], pts[0])
        XCTAssertEqual(freePts[2], pts[2])
        XCTAssertNotEqual(PipeGeometry.fittings(points: freePts).first?.kind, .elbow90)
    }
}
