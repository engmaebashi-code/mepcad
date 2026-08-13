import XCTest
@testable import MepCore

/// M4.8: ブロック定義(定義+参照モデル)のテスト
final class BlockTests: XCTestCase {

    /// L字の器具っぽい定義(基準点=原点)
    func makeDefinition() -> BlockDefinition {
        BlockDefinition(name: "テスト器具", entities: [
            Entity(layer: .zero, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0))),
            Entity(layer: .zero, kind: .line(a: Vec2(0, 0), b: Vec2(0, 50))),
            Entity(layer: .zero, kind: .circle(center: Vec2(100, 0), radius: 10)),
        ])
    }

    func refEntity(_ def: BlockDefinition, insert: Vec2, rotation: Double = 0,
                   scale: Double = 1, mirrored: Bool = false) -> Entity {
        let bounds = def.bounds(insert: insert, rotation: rotation, scale: scale, mirrored: mirrored)
        return Entity(layer: .zero,
                      kind: .blockRef(definitionID: def.id, insert: insert,
                                      rotation: rotation, scale: scale,
                                      mirrored: mirrored, cachedBounds: bounds))
    }

    // MARK: - 実体化

    func testInstantiateTranslation() {
        let def = makeDefinition()
        let out = def.instantiate(insert: Vec2(1000, 500), rotation: 0, scale: 1,
                                  mirrored: false, layer: LayerAddress(0, 3))
        XCTAssertEqual(out.count, 3)
        guard case .line(let a, let b) = out[0].kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(1000, 500))
        XCTAssertEqual(b, Vec2(1100, 500))
        // レイヤは配置側のものに揃う
        XCTAssertTrue(out.allSatisfy { $0.layer == LayerAddress(0, 3) })
    }

    func testInstantiateRotation90() {
        let def = makeDefinition()
        let out = def.instantiate(insert: Vec2(0, 0), rotation: .pi / 2, scale: 1,
                                  mirrored: false, layer: .zero)
        guard case .line(_, let b) = out[0].kind else { return XCTFail() }
        // (100,0) → 90°回転 → (0,100)
        XCTAssertEqual(b.x, 0, accuracy: 1e-9)
        XCTAssertEqual(b.y, 100, accuracy: 1e-9)
    }

    func testInstantiateScaleAndMirror() {
        let def = makeDefinition()
        let out = def.instantiate(insert: Vec2(0, 0), rotation: 0, scale: 2,
                                  mirrored: true, layer: .zero)
        guard case .line(_, let b) = out[0].kind else { return XCTFail() }
        // (100,0) → 縦軸反転 → (-100,0) → ×2 → (-200,0)
        XCTAssertEqual(b.x, -200, accuracy: 1e-9)
        XCTAssertEqual(b.y, 0, accuracy: 1e-9)
        guard case .circle(_, let r) = out[2].kind else { return XCTFail() }
        XCTAssertEqual(r, 20, accuracy: 1e-9)
    }

    // MARK: - 参照エンティティの変換とcachedBoundsの整合

    func testRefTranslatedKeepsBoundsConsistent() {
        let def = makeDefinition()
        let ref = refEntity(def, insert: Vec2(0, 0))
        let moved = ref.translated(by: Vec2(500, 300))
        guard case .blockRef(_, let insert, _, _, _, let cached) = moved.kind else { return XCTFail() }
        XCTAssertEqual(insert, Vec2(500, 300))
        let expected = def.bounds(insert: Vec2(500, 300), rotation: 0, scale: 1, mirrored: false)
        XCTAssertEqual(cached.minX, expected.minX, accuracy: 1e-6)
        XCTAssertEqual(cached.maxY, expected.maxY, accuracy: 1e-6)
    }

    /// 重要な不変条件: 「参照を鏡映してから実体化」=「実体化してから鏡映」
    func testMirrorComposition() {
        let def = makeDefinition()
        let ref = refEntity(def, insert: Vec2(500, 500), rotation: .pi / 6)

        // 垂直軸(x=0)で鏡映
        let axisA = Vec2(0, 0)
        let axisB = Vec2(0, 100)

        let mirroredRef = ref.mirrored(acrossLineFrom: axisA, to: axisB)
        guard case .blockRef(_, let insert, let rot, let scale, let mir, _) = mirroredRef.kind else {
            return XCTFail()
        }
        let viaRef = def.instantiate(insert: insert, rotation: rot, scale: scale,
                                     mirrored: mir, layer: .zero)

        let direct = def.instantiate(insert: Vec2(500, 500), rotation: .pi / 6, scale: 1,
                                     mirrored: false, layer: .zero)
            .map { $0.mirrored(acrossLineFrom: axisA, to: axisB) }

        // 先頭の線分の両端点が一致すること
        guard case .line(let a1, let b1) = viaRef[0].kind,
              case .line(let a2, let b2) = direct[0].kind else { return XCTFail() }
        XCTAssertEqual(a1.x, a2.x, accuracy: 1e-6)
        XCTAssertEqual(a1.y, a2.y, accuracy: 1e-6)
        XCTAssertEqual(b1.x, b2.x, accuracy: 1e-6)
        XCTAssertEqual(b1.y, b2.y, accuracy: 1e-6)
    }

    /// 「参照を回転してから実体化」=「実体化してから回転」
    func testRotateComposition() {
        let def = makeDefinition()
        let ref = refEntity(def, insert: Vec2(300, 0), mirrored: true)

        let center = Vec2(100, 100)
        let angle = Double.pi / 3

        let rotatedRef = ref.rotated(around: center, byRadians: angle)
        guard case .blockRef(_, let insert, let rot, _, let mir, _) = rotatedRef.kind else {
            return XCTFail()
        }
        let viaRef = def.instantiate(insert: insert, rotation: rot, scale: 1,
                                     mirrored: mir, layer: .zero)
        let direct = def.instantiate(insert: Vec2(300, 0), rotation: 0, scale: 1,
                                     mirrored: true, layer: .zero)
            .map { $0.rotated(around: center, byRadians: angle) }

        guard case .line(let a1, let b1) = viaRef[0].kind,
              case .line(let a2, let b2) = direct[0].kind else { return XCTFail() }
        XCTAssertEqual(a1.x, a2.x, accuracy: 1e-6)
        XCTAssertEqual(a1.y, a2.y, accuracy: 1e-6)
        XCTAssertEqual(b1.x, b2.x, accuracy: 1e-6)
        XCTAssertEqual(b1.y, b2.y, accuracy: 1e-6)
    }

    // MARK: - ヒットテスト(バウンディングボックス方式)

    func testRefHitByBounds() {
        let def = makeDefinition()
        let ref = refEntity(def, insert: Vec2(1000, 1000))
        // ボックス内=ヒット
        XCTAssertEqual(ref.hitDistance(to: Vec2(1050, 1020)), 0, accuracy: 1e-9)
        // ボックス外は距離
        XCTAssertGreaterThan(ref.hitDistance(to: Vec2(2000, 1000)), 800)
    }

    // MARK: - コマンド(ブロック化・解除)

    func testBlockifyCommandUndo() {
        let doc = Document()
        let e1 = Entity(layer: .zero, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        let e2 = Entity(layer: .zero, kind: .circle(center: Vec2(50, 0), radius: 20))
        doc.appendBulk([e1, e2])
        let countBefore = doc.entities.count
        let stack = CommandStack(document: doc)

        let def = BlockDefinition(name: "B1", entities: [
            Entity(layer: .zero, kind: .line(a: Vec2(-50, 0), b: Vec2(50, 0))),
            Entity(layer: .zero, kind: .circle(center: Vec2(0, 0), radius: 20)),
        ])
        let ref = Entity(layer: .zero,
                         kind: .blockRef(definitionID: def.id, insert: Vec2(50, 0),
                                         rotation: 0, scale: 1, mirrored: false,
                                         cachedBounds: BBox(minX: 0, minY: -20, maxX: 100, maxY: 20)))

        stack.run(BlockifyCommand(definition: def, memberIDs: [e1.id, e2.id], reference: ref))
        XCTAssertEqual(doc.entities.count, countBefore - 1)   // 2個→参照1個
        XCTAssertNotNil(doc.blockDefinition(id: def.id))
        XCTAssertNotNil(doc.entity(id: ref.id))

        stack.undo()
        XCTAssertEqual(doc.entities.count, countBefore)
        XCTAssertNil(doc.blockDefinition(id: def.id))
        XCTAssertNotNil(doc.entity(id: e1.id))

        stack.redo()
        XCTAssertNotNil(doc.blockDefinition(id: def.id))
        XCTAssertNotNil(doc.entity(id: ref.id))
    }

    func testExplodeCommandUndoKeepsDefinition() {
        let doc = Document()
        let def = makeDefinition()
        doc.addBlockDefinition(def)
        let ref = refEntity(def, insert: Vec2(0, 0))
        doc.add(ref)
        let stack = CommandStack(document: doc)

        let expanded = def.instantiate(insert: Vec2(0, 0), rotation: 0, scale: 1,
                                       mirrored: false, layer: ref.layer, freshIDs: true)
        stack.run(ExplodeBlockCommand(reference: ref, expanded: expanded))
        XCTAssertNil(doc.entity(id: ref.id))
        XCTAssertEqual(doc.entities.filter { expanded.map(\.id).contains($0.id) }.count, 3)
        XCTAssertNotNil(doc.blockDefinition(id: def.id))  // 定義は残る

        stack.undo()
        XCTAssertNotNil(doc.entity(id: ref.id))
        XCTAssertNotNil(doc.blockDefinition(id: def.id))
    }
}
