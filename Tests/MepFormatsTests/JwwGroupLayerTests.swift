import XCTest
@testable import MepFormats
@testable import MepCore

/// M4: JWWグループ→下敷きレイヤ展開のテスト(合成データ)
final class JwwGroupLayerTests: XCTestCase {

    func makeDrawing() -> JwwDrawing {
        var d = JwwDrawing()
        d.scales = [50, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        // グループ0(1/50)に2本、グループ3(1/1=図枠想定)に1本
        d.lines = [
            JwwLine(x1: 0, y1: 0, x2: 100, y2: 0, layer: 0, glayer: 0, lntp: 0, color: 1),
            JwwLine(x1: 0, y1: 10, x2: 100, y2: 10, layer: 0, glayer: 0, lntp: 0, color: 1),
            JwwLine(x1: 0, y1: 0, x2: 420, y2: 0, layer: 0, glayer: 3, lntp: 0, color: 1),
        ]
        // グループ3は非表示
        var states = [UInt8](repeating: 2, count: 16)
        states[3] = 0
        d.groupStates = states
        return d
    }

    func testGroupsBecomeUnderlayLayers() {
        let doc = Document()
        let count = JwwReader.importDrawing(makeDrawing(), into: doc)
        XCTAssertEqual(count, 3)

        let underlays = doc.layers.filter { $0.isUnderlay }
        XCTAssertEqual(underlays.count, 2)
        XCTAssertTrue(underlays.contains { $0.name.contains("G0") && $0.name.contains("1/50") })
        XCTAssertTrue(underlays.contains { $0.name.contains("G3") && $0.name.contains("1/1") })
        // 下敷きは既定でロック
        XCTAssertTrue(underlays.allSatisfy { !$0.isEditable })
    }

    func testGroupVisibilityInherited() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        let g0 = doc.layers.first { $0.name.contains("G0") }
        let g3 = doc.layers.first { $0.name.contains("G3") }
        XCTAssertEqual(g0?.isVisible, true)
        XCTAssertEqual(g3?.isVisible, false)
    }

    func testEntitiesAssignedToGroupLayers() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        guard let g0 = doc.layers.first(where: { $0.name.contains("G0") }),
              let g3 = doc.layers.first(where: { $0.name.contains("G3") }) else {
            return XCTFail("グループレイヤが作られていない")
        }
        XCTAssertEqual(doc.entities.filter { $0.layerID == g0.id }.count, 2)
        XCTAssertEqual(doc.entities.filter { $0.layerID == g3.id }.count, 1)
    }

    func testScaleAppliedPerGroup() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        guard let g0 = doc.layers.first(where: { $0.name.contains("G0") }) else { return XCTFail() }
        let g0Lines = doc.entities.filter { $0.layerID == g0.id }
        // 1/50グループ: 実寸 = 座標×50
        guard case .line(_, let b) = g0Lines[0].kind else { return XCTFail() }
        XCTAssertEqual(b.x, 5000, accuracy: 1e-9)
    }

    func testReimportReplacesUnderlayLayers() {
        let doc = Document()
        JwwReader.importDrawing(makeDrawing(), into: doc)
        let firstIDs = Set(doc.layers.filter(\.isUnderlay).map(\.id))

        // 開き直し(コントローラと同じ手順)
        doc.removeAllEntities()
        doc.removeLayers(where: { $0.isUnderlay })
        XCTAssertTrue(doc.layers.filter(\.isUnderlay).isEmpty)

        JwwReader.importDrawing(makeDrawing(), into: doc)
        let secondIDs = Set(doc.layers.filter(\.isUnderlay).map(\.id))
        XCTAssertEqual(secondIDs.count, 2)
        XCTAssertTrue(firstIDs.isDisjoint(with: secondIDs))
    }
}
