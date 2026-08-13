import XCTest
@testable import MepTools
@testable import MepCore

/// M4: 選択エンジンと移動・複写状態機械のテスト(16グループ×16レイヤ)
final class SelectionEditTests: XCTestCase {

    // 共通フィクスチャ:
    // 0-0=通常 / 0-1=ロック / 0-2=非表示 / グループ1=グループごと非表示
    let normal = LayerAddress(0, 0)
    let locked = LayerAddress(0, 1)
    let hidden = LayerAddress(0, 2)
    let inHiddenGroup = LayerAddress(1, 0)

    var groups: [LayerGroup] {
        var groups = (0..<16).map { _ in LayerGroup() }
        groups[0].layers[1].isEditable = false
        groups[0].layers[2].isVisible = false
        groups[1].isVisible = false
        return groups
    }

    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double,
              on layer: LayerAddress? = nil) -> Entity {
        Entity(layer: layer ?? normal, kind: .line(a: Vec2(x1, y1), b: Vec2(x2, y2)))
    }

    // MARK: - 選択可能判定

    func testSelectableAddresses() {
        let selectable = SelectionEngine.selectableAddresses(groups)
        XCTAssertTrue(selectable.contains(normal))
        XCTAssertFalse(selectable.contains(locked))        // レイヤロック
        XCTAssertFalse(selectable.contains(hidden))        // レイヤ非表示
        XCTAssertFalse(selectable.contains(inHiddenGroup)) // グループ非表示
        XCTAssertTrue(selectable.contains(LayerAddress(2, 15)))
    }

    // MARK: - クリック選択

    func testTopmostHit() {
        let e1 = line(0, 0, 100, 0)
        let e2 = line(0, 10, 100, 10)
        let hit = SelectionEngine.topmostHit(at: Vec2(50, 1), tolerance: 5,
                                             entities: [e1, e2], groups: groups)
        XCTAssertEqual(hit, e1.id)
        // 許容外
        XCTAssertNil(SelectionEngine.topmostHit(at: Vec2(50, 300), tolerance: 5,
                                                entities: [e1, e2], groups: groups))
    }

    func testTopmostHitPrefersUpperEntity() {
        // 同じ位置に2本 → 後から描いた方(配列の後ろ)が勝つ
        let e1 = line(0, 0, 100, 0)
        let e2 = line(0, 0, 100, 0)
        let hit = SelectionEngine.topmostHit(at: Vec2(50, 0), tolerance: 5,
                                             entities: [e1, e2], groups: groups)
        XCTAssertEqual(hit, e2.id)
    }

    func testLockedAndHiddenLayersNotSelectable() {
        let onLocked = line(0, 0, 100, 0, on: locked)
        let onHidden = line(0, 0, 100, 0, on: hidden)
        let onHiddenGroup = line(0, 0, 100, 0, on: inHiddenGroup)
        XCTAssertNil(SelectionEngine.topmostHit(at: Vec2(50, 0), tolerance: 5,
                                                entities: [onLocked, onHidden, onHiddenGroup],
                                                groups: groups))
    }

    // MARK: - 矩形選択(窓・交差)

    func testWindowSelectionRequiresContainment() {
        let inside = line(10, 10, 90, 90)
        let crossing = line(-50, 50, 150, 50)
        let rect = BBox(minX: 0, minY: 0, maxX: 100, maxY: 100)

        let windowIDs = SelectionEngine.ids(in: rect, mode: .window,
                                            entities: [inside, crossing], groups: groups)
        XCTAssertEqual(windowIDs, [inside.id])

        let crossingIDs = SelectionEngine.ids(in: rect, mode: .crossing,
                                              entities: [inside, crossing], groups: groups)
        XCTAssertEqual(Set(crossingIDs), Set([inside.id, crossing.id]))
    }

    func testRectSelectionSkipsLockedLayers() {
        let onLocked = line(10, 10, 90, 90, on: locked)
        let rect = BBox(minX: 0, minY: 0, maxX: 100, maxY: 100)
        XCTAssertTrue(SelectionEngine.ids(in: rect, mode: .crossing,
                                          entities: [onLocked], groups: groups).isEmpty)
    }

    // MARK: - 移動・複写の状態機械

    func testMoveTwoClicks() {
        let op = EditOperation()
        op.begin(.move, hasSelection: true)
        XCTAssertEqual(op.phase, .awaitingBase)

        XCTAssertNil(op.click(at: Vec2(100, 100)))       // 基準点
        XCTAssertEqual(op.phase, .awaitingTarget)

        let result = op.click(at: Vec2(150, 130))         // 移動先
        XCTAssertEqual(result, .translate(Vec2(50, 30)))
        XCTAssertEqual(op.phase, .idle)                   // 移動は1回で終了
    }

    func testCopyContinuousPlacement() {
        let op = EditOperation()
        op.begin(.copy, hasSelection: true)
        XCTAssertNil(op.click(at: Vec2(0, 0)))            // 基準点

        // 連続配置: 毎回同じ基準点からのdeltaが返り、状態は継続する
        XCTAssertEqual(op.click(at: Vec2(100, 0)), .translate(Vec2(100, 0)))
        XCTAssertEqual(op.phase, .awaitingTarget)
        XCTAssertEqual(op.click(at: Vec2(200, 50)), .translate(Vec2(200, 50)))
        XCTAssertEqual(op.phase, .awaitingTarget)

        op.cancel()
        XCTAssertEqual(op.phase, .idle)
    }

    func testMoveRespectsAngleConstraint() {
        let op = EditOperation()
        op.angleConstraint = .deg90
        op.begin(.move, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        // ほぼ水平の移動先 → 完全水平に拘束
        let result = op.click(at: Vec2(1000, 40))
        guard case .translate(let delta)? = result else { return XCTFail() }
        XCTAssertEqual(delta.y, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(delta.x, 999)
    }

    // MARK: - 回転・回転複写

    func testRotateByTwoDirections() {
        let op = EditOperation()
        op.begin(.rotate, hasSelection: true)
        XCTAssertNil(op.click(at: Vec2(100, 100)))        // 基準点(回転中心)
        XCTAssertEqual(op.phase, .awaitingAngleRef)
        XCTAssertNil(op.click(at: Vec2(200, 100)))        // 方向1(0°)
        XCTAssertEqual(op.phase, .awaitingAngleTarget)

        let result = op.click(at: Vec2(100, 200))         // 方向2(90°)
        guard case .rotate(let center, let angle)? = result else { return XCTFail() }
        XCTAssertEqual(center, Vec2(100, 100))
        XCTAssertEqual(angle, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(op.phase, .idle)                   // 回転(移動)は1回で終了
    }

    func testRotateCopyContinuous() {
        let op = EditOperation()
        op.begin(.rotateCopy, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))                      // 中心
        _ = op.click(at: Vec2(100, 0))                    // 方向1
        XCTAssertNotNil(op.click(at: Vec2(0, 100)))       // 90°で1個目
        XCTAssertEqual(op.phase, .awaitingAngleTarget)    // 連続配置
        let second = op.click(at: Vec2(-100, 0))          // 180°で2個目
        guard case .rotate(_, let angle)? = second else { return XCTFail() }
        XCTAssertEqual(abs(angle), .pi, accuracy: 1e-9)
    }

    func testRotateNumericAngle() {
        let op = EditOperation()
        op.begin(.rotate, hasSelection: true)
        _ = op.click(at: Vec2(50, 50))                    // 中心
        var committed: EditTransform?
        for ch in "90" { XCTAssertTrue(op.keyInput(ch) { _ in }) }
        _ = op.keyInput("\r") { committed = $0 }
        guard case .rotate(let center, let angle)? = committed else { return XCTFail() }
        XCTAssertEqual(center, Vec2(50, 50))
        XCTAssertEqual(angle, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(op.phase, .idle)
    }

    func testRotateNumericNegativeIsClockwise() {
        let op = EditOperation()
        op.begin(.rotateCopy, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        var committed: EditTransform?
        for ch in "-45" { _ = op.keyInput(ch) { _ in } }
        _ = op.keyInput("\r") { committed = $0 }
        guard case .rotate(_, let angle)? = committed else { return XCTFail() }
        XCTAssertEqual(angle, -.pi / 4, accuracy: 1e-9)
        XCTAssertEqual(op.phase, .awaitingAngleRef)       // 回転複写は継続
    }

    func testBeginRequiresSelection() {
        let op = EditOperation()
        op.begin(.move, hasSelection: false)
        XCTAssertEqual(op.phase, .idle)
    }

    func testPreviewTransform() {
        let op = EditOperation()
        op.begin(.move, hasSelection: true)
        XCTAssertNil(op.previewTransform(cursor: Vec2(10, 10)))  // 基準点前はプレビューなし
        _ = op.click(at: Vec2(100, 100))
        XCTAssertEqual(op.previewTransform(cursor: Vec2(120, 90)), .translate(Vec2(20, -10)))
    }

    func testNumericRelativeInput() {
        let op = EditOperation()
        op.begin(.move, hasSelection: true)
        _ = op.click(at: Vec2(100, 100))

        var committed: EditTransform?
        for ch in "50,-25" { XCTAssertTrue(op.keyInput(ch) { _ in }) }
        XCTAssertTrue(op.keyInput("\r") { committed = $0 })
        XCTAssertEqual(committed, .translate(Vec2(50, -25)))
        XCTAssertEqual(op.phase, .idle)
    }

    func testNumericDistanceTowardCursor() {
        let op = EditOperation()
        op.begin(.copy, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        _ = op.previewTransform(cursor: Vec2(100, 0))  // カーソルは+X方向

        var committed: EditTransform?
        for ch in "250" { _ = op.keyInput(ch) { _ in } }
        _ = op.keyInput("\n") { committed = $0 }
        guard case .translate(let delta)? = committed else { return XCTFail() }
        XCTAssertEqual(delta.x, 250, accuracy: 1e-9)
        XCTAssertEqual(delta.y, 0, accuracy: 1e-9)
        // 複写は確定後も継続
        XCTAssertEqual(op.phase, .awaitingTarget)
    }

    // MARK: - 回転しながら移動/複写(角度プロパティ)・反転

    func testMoveWithRotationProperty() {
        let op = EditOperation()
        op.begin(.move, hasSelection: true)
        op.rotationDegrees = 180
        _ = op.click(at: Vec2(0, 0))                      // 基準点
        let result = op.click(at: Vec2(500, 0))           // 移動先
        guard case .moveRotated(let base, let delta, let angle)? = result else { return XCTFail() }
        XCTAssertEqual(base, Vec2(0, 0))
        XCTAssertEqual(delta, Vec2(500, 0))
        XCTAssertEqual(abs(angle), .pi, accuracy: 1e-9)
    }

    func testApplyingMoveRotated() {
        // (100,0)-(200,0)の線を基準点(100,0)まわりに90°回転して(0,500)移動
        let e = Entity(layer: normal, kind: .line(a: Vec2(100, 0), b: Vec2(200, 0)))
        let t = EditTransform.moveRotated(base: Vec2(100, 0), delta: Vec2(0, 500), angle: .pi / 2)
        guard case .line(let a, let b) = e.applying(t).kind else { return XCTFail() }
        XCTAssertEqual(a.x, 100, accuracy: 1e-9)
        XCTAssertEqual(a.y, 500, accuracy: 1e-9)
        XCTAssertEqual(b.x, 100, accuracy: 1e-9)
        XCTAssertEqual(b.y, 600, accuracy: 1e-9)
    }

    func testMirrorTwoPointAxis() {
        let op = EditOperation()
        op.begin(.mirror, hasSelection: true)
        XCTAssertEqual(op.phase, .awaitingMirrorA)
        XCTAssertNil(op.click(at: Vec2(0, 0)))            // 基準線1点目
        XCTAssertEqual(op.phase, .awaitingMirrorB)
        let result = op.click(at: Vec2(0, 100))           // 基準線2点目(垂直軸)
        XCTAssertEqual(result, .mirror(a: Vec2(0, 0), b: Vec2(0, 100)))
        XCTAssertEqual(op.phase, .idle)                   // 反転(移動)は1回で終了
    }

    func testMirrorCopyRestartsAxis() {
        let op = EditOperation()
        op.begin(.mirrorCopy, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        XCTAssertNotNil(op.click(at: Vec2(0, 100)))       // 1本目の基準線で確定
        XCTAssertEqual(op.phase, .awaitingMirrorA)        // 次は別の基準線から
        _ = op.click(at: Vec2(50, 0))
        XCTAssertNotNil(op.click(at: Vec2(50, 100)))
    }

    func testMirrorAxisRespectsAngleConstraint() {
        let op = EditOperation()
        op.angleConstraint = .deg90
        op.begin(.mirror, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        // ほぼ垂直の2点目 → 完全垂直の基準線に拘束
        let result = op.click(at: Vec2(20, 1000))
        guard case .mirror(_, let b)? = result else { return XCTFail() }
        XCTAssertEqual(b.x, 0, accuracy: 1e-9)
    }

    func testKeyInputIgnoredWhenIdle() {
        let op = EditOperation()
        XCTAssertFalse(op.keyInput("5") { _ in })
    }
}
