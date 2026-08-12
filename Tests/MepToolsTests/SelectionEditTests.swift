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

        let delta = op.click(at: Vec2(150, 130))          // 移動先
        XCTAssertEqual(delta, Vec2(50, 30))
        XCTAssertEqual(op.phase, .idle)                   // 移動は1回で終了
    }

    func testCopyContinuousPlacement() {
        let op = EditOperation()
        op.begin(.copy, hasSelection: true)
        XCTAssertNil(op.click(at: Vec2(0, 0)))            // 基準点

        // 連続配置: 毎回同じ基準点からのdeltaが返り、状態は継続する
        XCTAssertEqual(op.click(at: Vec2(100, 0)), Vec2(100, 0))
        XCTAssertEqual(op.phase, .awaitingTarget)
        XCTAssertEqual(op.click(at: Vec2(200, 50)), Vec2(200, 50))
        XCTAssertEqual(op.phase, .awaitingTarget)

        op.cancel()
        XCTAssertEqual(op.phase, .idle)
    }

    func testBeginRequiresSelection() {
        let op = EditOperation()
        op.begin(.move, hasSelection: false)
        XCTAssertEqual(op.phase, .idle)
    }

    func testPreviewDelta() {
        let op = EditOperation()
        op.begin(.move, hasSelection: true)
        XCTAssertNil(op.previewDelta(cursor: Vec2(10, 10)))  // 基準点前はプレビューなし
        _ = op.click(at: Vec2(100, 100))
        XCTAssertEqual(op.previewDelta(cursor: Vec2(120, 90)), Vec2(20, -10))
    }

    func testNumericRelativeInput() {
        let op = EditOperation()
        op.begin(.move, hasSelection: true)
        _ = op.click(at: Vec2(100, 100))

        var committed: Vec2?
        for ch in "50,-25" { XCTAssertTrue(op.keyInput(ch) { _ in }) }
        XCTAssertTrue(op.keyInput("\r") { committed = $0 })
        XCTAssertEqual(committed, Vec2(50, -25))
        XCTAssertEqual(op.phase, .idle)
    }

    func testNumericDistanceTowardCursor() {
        let op = EditOperation()
        op.begin(.copy, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        _ = op.previewDelta(cursor: Vec2(100, 0))  // カーソルは+X方向

        var committed: Vec2?
        for ch in "250" { _ = op.keyInput(ch) { _ in } }
        _ = op.keyInput("\n") { committed = $0 }
        XCTAssertNotNil(committed)
        XCTAssertEqual(committed!.x, 250, accuracy: 1e-9)
        XCTAssertEqual(committed!.y, 0, accuracy: 1e-9)
        // 複写は確定後も継続
        XCTAssertEqual(op.phase, .awaitingTarget)
    }

    func testKeyInputIgnoredWhenIdle() {
        let op = EditOperation()
        XCTAssertFalse(op.keyInput("5") { _ in })
    }
}
