import XCTest
@testable import MepFormats
@testable import MepCore

/// M4.1: JWW→16グループ×16レイヤ展開のテスト(合成データ)
final class JwwGroupLayerTests: XCTestCase {

    /// グループ0(1/50)に2本、グループ3(1/1=図枠想定)に1本。
    /// グループ3は非表示。レイヤ状態: 0-0=書込(3) 0-1=編集可(2) 0-2=表示のみ(1) 0-3=非表示(0)
    func makeDrawing() -> JwwDrawing {
        var d = JwwDrawing()
        d.scales = [50, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        d.lines = [
            JwwLine(x1: 0, y1: 0, x2: 100, y2: 0, layer: 0, glayer: 0, lntp: 1, color: 1),
            JwwLine(x1: 0, y1: 10, x2: 100, y2: 10, layer: 1, glayer: 0, lntp: 5, color: 2),
            JwwLine(x1: 0, y1: 0, x2: 420, y2: 0, layer: 0, glayer: 3, lntp: 1, color: 1),
        ]
        var groupStates = [UInt8](repeating: 2, count: 16)
        groupStates[0] = 3  // 書込グループ
        groupStates[3] = 0  // 非表示
        d.groupStates = groupStates

        var layerStates = [UInt8](repeating: 2, count: 256)
        layerStates[0] = 3  // 0-0 書込
        layerStates[1] = 2  // 0-1 編集可
        layerStates[2] = 1  // 0-2 表示のみ
        layerStates[3] = 0  // 0-3 非表示
        d.layerStates = layerStates
        return d
    }

    func testAlways16x16AfterImport() {
        let doc = Document()
        let count = JwwReader.importDrawing(makeDrawing(), into: doc)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(doc.groups.count, 16)
        XCTAssertTrue(doc.groups.allSatisfy { $0.layers.count == 16 })
    }

    func testGroupScaleAndVisibilityInherited() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        XCTAssertEqual(doc.group(0).scale, 50)
        XCTAssertEqual(doc.group(3).scale, 1)
        XCTAssertTrue(doc.group(0).isVisible)
        XCTAssertFalse(doc.group(3).isVisible)   // 図枠グループ非表示を引き継ぐ
    }

    func testLayerStatesInherited() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        // 0-0 書込 → カレント
        XCTAssertEqual(doc.current, LayerAddress(0, 0))
        // 0-1 編集可
        XCTAssertTrue(doc.layer(at: LayerAddress(0, 1)).isVisible)
        XCTAssertTrue(doc.layer(at: LayerAddress(0, 1)).isEditable)
        // 0-2 表示のみ → 見えるがロック
        XCTAssertTrue(doc.layer(at: LayerAddress(0, 2)).isVisible)
        XCTAssertFalse(doc.layer(at: LayerAddress(0, 2)).isEditable)
        // 0-3 非表示
        XCTAssertFalse(doc.layer(at: LayerAddress(0, 3)).isVisible)
    }

    func testEntitiesAssignedToOriginalAddresses() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        XCTAssertEqual(doc.entities.filter { $0.layer == LayerAddress(0, 0) }.count, 1)
        XCTAssertEqual(doc.entities.filter { $0.layer == LayerAddress(0, 1) }.count, 1)
        XCTAssertEqual(doc.entities.filter { $0.layer == LayerAddress(3, 0) }.count, 1)
    }

    func testScaleAppliedPerGroup() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        // 1/50グループ: 実寸 = 座標×50
        guard let e = doc.entities.first(where: { $0.layer == LayerAddress(0, 0) }),
              case .line(_, let b) = e.kind else { return XCTFail() }
        XCTAssertEqual(b.x, 5000, accuracy: 1e-9)
        // 1/1グループはそのまま
        guard let f = doc.entities.first(where: { $0.layer == LayerAddress(3, 0) }),
              case .line(_, let fb) = f.kind else { return XCTFail() }
        XCTAssertEqual(fb.x, 420, accuracy: 1e-9)
    }

    func testColorAndLineTypeImported() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        guard let e0 = doc.entities.first(where: { $0.layer == LayerAddress(0, 0) }),
              let e1 = doc.entities.first(where: { $0.layer == LayerAddress(0, 1) }) else {
            return XCTFail()
        }
        XCTAssertEqual(e0.style.colorIndex, 1)
        XCTAssertEqual(e0.style.lineType, 0)   // lntp1=実線
        XCTAssertEqual(e1.style.colorIndex, 2)
        XCTAssertEqual(e1.style.lineType, 2)   // lntp5=一点鎖線系
    }

    func testReimportReplacesEverything() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        let firstCount = doc.entities.count

        // 開き直し = 全置換(前の図面の要素は残らない)
        JwwReader.importDrawing(makeDrawing(), into: doc)
        XCTAssertEqual(doc.entities.count, firstCount)
        XCTAssertEqual(doc.groups.count, 16)
    }

    func testStateDecode() {
        // 0=非表示 1=表示のみ 2=編集可 3=書込 / +8=プロテクト
        XCTAssertEqual(JwwReader.decodeState(0).visible, false)
        let readOnly = JwwReader.decodeState(1)
        XCTAssertTrue(readOnly.visible)
        XCTAssertFalse(readOnly.editable)
        let editable = JwwReader.decodeState(2)
        XCTAssertTrue(editable.visible)
        XCTAssertTrue(editable.editable)
        let current = JwwReader.decodeState(3)
        XCTAssertTrue(current.isCurrent)
        // プロテクトビット → 編集不可
        let protected2 = JwwReader.decodeState(2 | 8)
        XCTAssertTrue(protected2.visible)
        XCTAssertFalse(protected2.editable)
    }

    func testFallbackCurrentWhenAllLocked() {
        var d = makeDrawing()
        // 全レイヤ・全グループ表示のみ(書込不能)にする
        d.groupStates = [UInt8](repeating: 1, count: 16)
        d.layerStates = [UInt8](repeating: 1, count: 256)
        let doc = Document()
        JwwReader.importDrawing(d, into: doc)
        // フォールバックで0-0が書込可能になっている
        XCTAssertTrue(doc.isSelectable(doc.current))
    }
}
