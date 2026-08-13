import XCTest
@testable import MepCore

/// M4: ヒットテスト・平行移動・一括編集コマンドのテスト
final class HitTestTests: XCTestCase {

    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Entity {
        Entity(layer: .zero, kind: .line(a: Vec2(x1, y1), b: Vec2(x2, y2)))
    }

    // MARK: - hitDistance

    func testLineHitDistance() {
        let e = line(0, 0, 100, 0)
        XCTAssertEqual(e.hitDistance(to: Vec2(50, 10)), 10, accuracy: 1e-9)
        XCTAssertEqual(e.hitDistance(to: Vec2(50, 0)), 0, accuracy: 1e-9)
        // 線分外は端点への距離
        XCTAssertEqual(e.hitDistance(to: Vec2(130, 40)), 50, accuracy: 1e-9)
    }

    func testCircleHitDistance() {
        let e = Entity(layer: .zero, kind: .circle(center: Vec2(0, 0), radius: 100))
        XCTAssertEqual(e.hitDistance(to: Vec2(110, 0)), 10, accuracy: 1e-9)
        XCTAssertEqual(e.hitDistance(to: Vec2(80, 0)), 20, accuracy: 1e-9)
        // 中心は半径ぶん離れている(円周が当たり判定)
        XCTAssertEqual(e.hitDistance(to: Vec2(0, 0)), 100, accuracy: 1e-9)
    }

    func testArcHitDistance() {
        // 0°→90°の四分円(半径100)
        let e = Entity(layer: .zero,
                       kind: .arc(center: Vec2(0, 0), radius: 100, startAngle: 0, endAngle: .pi / 2))
        // 弧の範囲内(45°方向)
        XCTAssertEqual(e.hitDistance(to: Vec2(cos(Double.pi / 4) * 110, sin(Double.pi / 4) * 110)),
                       10, accuracy: 1e-9)
        // 範囲外(180°方向)は端点への距離になる
        let d = e.hitDistance(to: Vec2(-100, 0))
        XCTAssertGreaterThan(d, 100)
    }

    // MARK: - 矩形判定(窓・交差)

    func testContainment() {
        let e = line(10, 10, 90, 90)
        XCTAssertTrue(e.isContained(in: BBox(minX: 0, minY: 0, maxX: 100, maxY: 100)))
        XCTAssertFalse(e.isContained(in: BBox(minX: 0, minY: 0, maxX: 50, maxY: 100)))
    }

    func testLineIntersectsRect() {
        // 矩形を横切る(端点は外)
        let e = line(-50, 50, 150, 50)
        let rect = BBox(minX: 0, minY: 0, maxX: 100, maxY: 100)
        XCTAssertTrue(e.intersects(rect: rect))
        XCTAssertFalse(e.isContained(in: rect))
        // 完全に外
        XCTAssertFalse(line(-50, 200, 150, 200).intersects(rect: rect))
    }

    func testCircleIntersectsRect() {
        let rect = BBox(minX: 0, minY: 0, maxX: 100, maxY: 100)
        // 円周が矩形にかかる
        XCTAssertTrue(Entity(layer: .zero, kind: .circle(center: Vec2(-20, 50), radius: 40))
            .intersects(rect: rect))
        // 円が遠い
        XCTAssertFalse(Entity(layer: .zero, kind: .circle(center: Vec2(-200, 50), radius: 40))
            .intersects(rect: rect))
        // 矩形全体が円の内側(円周は交差しない)
        XCTAssertFalse(Entity(layer: .zero, kind: .circle(center: Vec2(50, 50), radius: 1000))
            .intersects(rect: rect))
    }

    // MARK: - 平行移動・複製

    func testTranslatedKeepsID() {
        let e = line(0, 0, 100, 0)
        let moved = e.translated(by: Vec2(10, 20))
        XCTAssertEqual(moved.id, e.id)
        guard case .line(let a, let b) = moved.kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(10, 20))
        XCTAssertEqual(b, Vec2(110, 20))
    }

    func testRotatedAroundCenter() {
        let e = line(100, 0, 200, 0)
        // 原点まわりに90°回転(反時計回り)
        let rotated = e.rotated(around: .zero, byRadians: .pi / 2)
        XCTAssertEqual(rotated.id, e.id)
        guard case .line(let a, let b) = rotated.kind else { return XCTFail() }
        XCTAssertEqual(a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(a.y, 100, accuracy: 1e-9)
        XCTAssertEqual(b.x, 0, accuracy: 1e-9)
        XCTAssertEqual(b.y, 200, accuracy: 1e-9)
    }

    func testRotatedArcShiftsAngles() {
        let e = Entity(layer: .zero,
                       kind: .arc(center: Vec2(100, 0), radius: 50, startAngle: 0, endAngle: .pi / 2))
        let rotated = e.rotated(around: .zero, byRadians: .pi / 2)
        guard case .arc(let c, let r, let sa, let ea) = rotated.kind else { return XCTFail() }
        XCTAssertEqual(c.x, 0, accuracy: 1e-9)
        XCTAssertEqual(c.y, 100, accuracy: 1e-9)
        XCTAssertEqual(r, 50, accuracy: 1e-9)
        XCTAssertEqual(sa, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(ea, .pi, accuracy: 1e-9)
    }

    func testRotateEntitiesCommandUndoExact() {
        let doc = Document()
        let e = line(0.1, 0.2, 100.3, 0.7)
        doc.appendBulk([e])
        let stack = CommandStack(document: doc)

        stack.run(RotateEntitiesCommand(ids: [e.id], center: Vec2(50, 50), angle: .pi / 3))
        stack.undo()
        guard case .line(let a, let b) = doc.entity(id: e.id)!.kind else { return XCTFail() }
        // スナップショット復元なのでビット単位で一致
        XCTAssertEqual(a, Vec2(0.1, 0.2))
        XCTAssertEqual(b, Vec2(100.3, 0.7))
    }

    func testDuplicatedNewID() {
        let e = line(0, 0, 100, 0)
        let copy = e.duplicated(by: Vec2(10, 0))
        XCTAssertNotEqual(copy.id, e.id)
        guard case .line(let a, _) = copy.kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(10, 0))
    }

    // MARK: - 一括編集コマンド(Undo/Redo)

    func testTranslateEntitiesCommandUndo() {
        let doc = Document()
        let e1 = line(0, 0, 100, 0)
        let e2 = line(0, 50, 100, 50)
        doc.appendBulk([e1, e2])
        let stack = CommandStack(document: doc)

        stack.run(TranslateEntitiesCommand(ids: [e1.id, e2.id], delta: Vec2(10, 20)))
        guard case .line(let a, _) = doc.entity(id: e1.id)!.kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(10, 20))

        stack.undo()
        guard case .line(let a2, _) = doc.entity(id: e1.id)!.kind else { return XCTFail() }
        XCTAssertEqual(a2, Vec2(0, 0))

        stack.redo()
        guard case .line(let a3, _) = doc.entity(id: e1.id)!.kind else { return XCTFail() }
        XCTAssertEqual(a3, Vec2(10, 20))
    }

    func testRemoveEntitiesCommandUndo() {
        let doc = Document()
        let e1 = line(0, 0, 100, 0)
        let e2 = line(0, 50, 100, 50)
        doc.appendBulk([e1, e2])
        let countBefore = doc.entities.count
        let stack = CommandStack(document: doc)

        stack.run(RemoveEntitiesCommand(entities: [e1, e2]))
        XCTAssertEqual(doc.entities.count, countBefore - 2)

        stack.undo()
        XCTAssertEqual(doc.entities.count, countBefore)
        XCTAssertNotNil(doc.entity(id: e1.id))
    }

    func testRemoveEntitiesUndoRestoresZOrder() {
        let doc = Document()
        let e1 = line(0, 0, 100, 0)
        let e2 = line(0, 10, 100, 10)
        let e3 = line(0, 20, 100, 20)
        doc.appendBulk([e1, e2, e3])
        let orderBefore = doc.entities.map(\.id)
        let stack = CommandStack(document: doc)

        // 真ん中のe2を削除→Undoで元の位置(重なり順)に戻ること
        stack.run(RemoveEntitiesCommand(entities: [e2]))
        stack.undo()
        XCTAssertEqual(doc.entities.map(\.id), orderBefore)
    }

    func testTranslateUndoRestoresExactCoordinates() {
        let doc = Document()
        // 浮動小数の往復誤差が出やすい座標
        let e = Entity(layer: .zero, kind: .line(a: Vec2(0.1, 0.2), b: Vec2(100.3, 0.7)))
        doc.appendBulk([e])
        let stack = CommandStack(document: doc)

        stack.run(TranslateEntitiesCommand(ids: [e.id], delta: Vec2(0.2, 0.1)))
        stack.undo()
        guard case .line(let a, let b) = doc.entity(id: e.id)!.kind else { return XCTFail() }
        // スナップショット復元なのでビット単位で一致する
        XCTAssertEqual(a, Vec2(0.1, 0.2))
        XCTAssertEqual(b, Vec2(100.3, 0.7))
    }

    func testAddEntitiesCommandUndo() {
        let doc = Document()
        let base = doc.entities.count
        let copies = [line(0, 0, 10, 0), line(0, 5, 10, 5)]
        let stack = CommandStack(document: doc)

        stack.run(AddEntitiesCommand(name: "複写", entities: copies))
        XCTAssertEqual(doc.entities.count, base + 2)

        stack.undo()
        XCTAssertEqual(doc.entities.count, base)
    }

    func testUpdateEntitiesCommandUndo() {
        let doc = Document()
        let e = line(0, 0, 100, 0)
        doc.appendBulk([e])
        var after = e
        after.style.colorIndex = 3
        let stack = CommandStack(document: doc)

        stack.run(UpdateEntitiesCommand(before: [e], after: [after]))
        XCTAssertEqual(doc.entity(id: e.id)?.style.colorIndex, 3)

        stack.undo()
        XCTAssertNil(doc.entity(id: e.id)?.style.colorIndex)
    }

    /// レイヤ間移動(属性変更コマンド経由)のUndo
    func testMoveToLayerUndo() {
        let doc = Document()
        let e = line(0, 0, 100, 0)
        doc.appendBulk([e])
        var after = e
        after.layer = LayerAddress(2, 5)
        let stack = CommandStack(document: doc)

        stack.run(UpdateEntitiesCommand(name: "レイヤへ移動", before: [e], after: [after]))
        XCTAssertEqual(doc.entity(id: e.id)?.layer, LayerAddress(2, 5))

        stack.undo()
        XCTAssertEqual(doc.entity(id: e.id)?.layer, .zero)
    }

    // MARK: - 16グループ×16レイヤの構造

    func testDocumentAlways16x16() {
        let doc = Document()
        XCTAssertEqual(doc.groups.count, 16)
        XCTAssertTrue(doc.groups.allSatisfy { $0.layers.count == 16 })
        // 既定カレントは基本作図(0-2)
        XCTAssertEqual(doc.current, LayerAddress(0, 2))
        XCTAssertEqual(doc.layer(at: doc.current).name, "基本作図")
    }

    func testEffectiveVisibility() {
        let doc = Document()
        let address = LayerAddress(0, 2)
        XCTAssertTrue(doc.isVisible(address))
        // レイヤ非表示
        doc.updateLayer(at: address) { $0.isVisible = false }
        XCTAssertFalse(doc.isVisible(address))
        doc.updateLayer(at: address) { $0.isVisible = true }
        // グループ非表示でもレイヤは見えない(実効状態)
        doc.updateGroup(0) { $0.isVisible = false }
        XCTAssertFalse(doc.isVisible(address))
    }

    func testCurrentLayerCannotBeHiddenOrLocked() {
        let doc = Document()
        let hidden = LayerAddress(1, 0)
        doc.updateLayer(at: hidden) { $0.isVisible = false }
        XCTAssertFalse(doc.setCurrent(hidden))

        let locked = LayerAddress(1, 1)
        doc.updateLayer(at: locked) { $0.isEditable = false }
        XCTAssertFalse(doc.setCurrent(locked))

        let ok = LayerAddress(1, 2)
        XCTAssertTrue(doc.setCurrent(ok))
        XCTAssertEqual(doc.current, ok)
    }

    func testLayerAddressDescription() {
        XCTAssertEqual(LayerAddress(0, 2).description, "0-2")
        XCTAssertEqual(LayerAddress(15, 10).description, "F-A")
        // 範囲外はクランプ
        XCTAssertEqual(LayerAddress(99, -1), LayerAddress(15, 0))
    }
}
