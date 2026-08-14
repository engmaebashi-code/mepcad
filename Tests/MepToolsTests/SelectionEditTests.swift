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

    // MARK: - 文字の選択(M5.3.1回帰: 本体クリックで選べること)

    /// 文字はグリフ本体のどこをクリックしても選択できる
    /// (以前はboundsが基準点1点でtopmostHitの前段フィルタに弾かれ、
    ///  プロパティの文字セクションが出ない実害があった)
    func testTextSelectableOnGlyphBody(){
        let text = Entity(layer: normal,
                          kind: .text(position: Vec2(1000, 500), content: "AC-1",
                                      height: 350, angle: 0))
        // グリフ中央付近(基準点から遠い)をクリック
        let mid = Vec2(1000 + 350 * 0.9 * 2, 500 + 175)
        let hit = SelectionEngine.topmostHit(at: mid, tolerance: 50,
                                             entities: [text], groups: groups)
        XCTAssertEqual(hit, text.id)
        // boundsもグリフボックスを覆う
        let box = text.bounds
        XCTAssertEqual(box.minX, 1000)
        XCTAssertGreaterThanOrEqual(box.maxX, 1000 + 4 * 350 * 0.9 - 1)
        XCTAssertEqual(box.maxY, 850, accuracy: 1e-9)
    }

    /// 回転した文字のboundsは回転後の四隅を覆う
    func testRotatedTextBounds() {
        let text = Entity(layer: normal,
                          kind: .text(position: Vec2(0, 0), content: "AB",
                                      height: 100, angle: .pi / 2))
        let box = text.bounds
        // 90°回転: 幅方向が+Y、 高さ方向が-X
        XCTAssertEqual(box.minX, -100, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(box.maxY, 100)
        XCTAssertEqual(box.minY, 0, accuracy: 1e-9)
    }

    // MARK: - 拡大縮小(M4.9)

    /// 基準点→参照点→目標点: 距離比が倍率になる
    func testScaleByReferenceDrag() {
        let op = EditOperation()
        op.begin(.scale, hasSelection: true)
        XCTAssertEqual(op.phase, .awaitingBase)
        XCTAssertNil(op.click(at: Vec2(100, 100)))         // 基準点
        XCTAssertEqual(op.phase, .awaitingScaleRef)
        XCTAssertNil(op.click(at: Vec2(200, 100)))         // 参照点(距離100)
        XCTAssertEqual(op.phase, .awaitingScaleTarget)

        // プレビュー: 距離200 → 倍率2
        guard case .scale(let c, let f)? = op.previewTransform(cursor: Vec2(300, 100)) else {
            return XCTFail()
        }
        XCTAssertEqual(c, Vec2(100, 100))
        XCTAssertEqual(f, 2, accuracy: 1e-9)

        // 確定: 距離50 → 倍率0.5、1回で終了
        guard case .scale(_, let factor)? = op.click(at: Vec2(150, 100)) else { return XCTFail() }
        XCTAssertEqual(factor, 0.5, accuracy: 1e-9)
        XCTAssertEqual(op.phase, .idle)
    }

    /// 基準点の直後に数値⏎で倍率確定(参照点なし)
    func testScaleByNumericInput() {
        let op = EditOperation()
        op.begin(.scale, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        var committed: EditTransform?
        for ch in "2.5" { _ = op.keyInput(ch) { _ in } }
        _ = op.keyInput("\r") { committed = $0 }
        guard case .scale(let c, let f)? = committed else { return XCTFail() }
        XCTAssertEqual(c, Vec2(0, 0))
        XCTAssertEqual(f, 2.5, accuracy: 1e-9)
        XCTAssertEqual(op.phase, .idle)
    }

    /// 0や負の倍率は確定しない
    func testScaleRejectsNonPositiveFactor() {
        let op = EditOperation()
        op.begin(.scale, hasSelection: true)
        _ = op.click(at: Vec2(0, 0))
        var committed = false
        for ch in "-2" { _ = op.keyInput(ch) { _ in } }
        _ = op.keyInput("\r") { _ in committed = true }
        XCTAssertFalse(committed)
        XCTAssertEqual(op.phase, .awaitingScaleRef)        // 操作は継続中
    }

    /// applying(.scale): 線・円・ブロック配置に等倍率が効く
    func testApplyingScale() {
        let t = EditTransform.scale(center: Vec2(0, 0), factor: 2)

        let l = line(10, 0, 20, 0)
        guard case .line(let a, let b) = l.applying(t).kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(20, 0))
        XCTAssertEqual(b, Vec2(40, 0))

        let circle = Entity(layer: normal, kind: .circle(center: Vec2(10, 10), radius: 5))
        guard case .circle(let cc, let r) = circle.applying(t).kind else { return XCTFail() }
        XCTAssertEqual(cc, Vec2(20, 20))
        XCTAssertEqual(r, 10, accuracy: 1e-9)

        // ブロック配置: 挿入点が拡大され、scaleパラメータに合成される
        let box = BBox(minX: 90, minY: -10, maxX: 110, maxY: 10)
        let ref = Entity(layer: normal,
                         kind: .blockRef(definitionID: UUID(), insert: Vec2(100, 0),
                                         rotation: 0, scale: 1.5, mirrored: false,
                                         cachedBounds: box))
        guard case .blockRef(_, let insert, _, let scale, _, let cached) = ref.applying(t).kind else {
            return XCTFail()
        }
        XCTAssertEqual(insert, Vec2(200, 0))
        XCTAssertEqual(scale, 3, accuracy: 1e-9)
        XCTAssertEqual(cached.minX, 180, accuracy: 1e-9)
        XCTAssertEqual(cached.maxX, 220, accuracy: 1e-9)
    }
}
