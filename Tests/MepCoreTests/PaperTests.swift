import XCTest
@testable import MepCore

/// M4.10: 用紙サイズ・縮尺・新規作成のテスト
final class PaperTests: XCTestCase {

    func testPaperSizesAndJwwCodes() {
        XCTAssertEqual(PaperSize(jwwCode: 1), .a1)
        XCTAssertEqual(PaperSize(jwwCode: 3), .a3)
        XCTAssertNil(PaperSize(jwwCode: 8))    // 2A以上は対応外
        XCTAssertNil(PaperSize(jwwCode: -1))
        XCTAssertEqual(PaperSize.a1.widthMm, 841)
        XCTAssertEqual(PaperSize.a1.heightMm, 594)
        XCTAssertEqual(PaperSize.a3.widthMm, 420)
        XCTAssertEqual(PaperSize.a3.heightMm, 297)
    }

    /// 用紙枠: 実寸 = 紙面mm × 書込グループ縮尺、中心=原点
    func testPaperFrameUsesCurrentGroupScale() {
        let doc = Document()
        doc.setPaperSize(.a1)
        doc.setCurrentScale(50)
        let frame = doc.paperFrame
        XCTAssertEqual(frame.maxX - frame.minX, 841 * 50, accuracy: 1e-9)
        XCTAssertEqual(frame.maxY - frame.minY, 594 * 50, accuracy: 1e-9)
        XCTAssertEqual(frame.minX, -frame.maxX, accuracy: 1e-9)   // 中心=原点

        doc.setCurrentScale(30)
        XCTAssertEqual(doc.paperFrame.maxX - doc.paperFrame.minX, 841 * 30, accuracy: 1e-9)
        XCTAssertEqual(doc.currentScaleLabel, "1/30")
    }

    /// 縮尺変更は実寸固定(図形の座標は変わらない)
    func testSetCurrentScaleKeepsEntities() {
        let doc = Document()
        let e = Entity(layer: doc.current, kind: .line(a: Vec2(0, 0), b: Vec2(1000, 0)))
        doc.add(e)
        doc.setCurrentScale(20)
        guard case .line(let a, let b) = doc.entity(id: e.id)!.kind else { return XCTFail() }
        XCTAssertEqual(a, Vec2(0, 0))
        XCTAssertEqual(b, Vec2(1000, 0))
    }

    func testResetForNewDrawing() {
        let doc = Document()
        doc.loadDemoContent()
        doc.addBlockDefinition(BlockDefinition(name: "B", entities: []))
        XCTAssertFalse(doc.entities.isEmpty)

        var changed = 0
        doc.onChange = { changed += 1 }
        doc.resetForNewDrawing(paperSize: .a2, scaleDenominator: 30)

        XCTAssertEqual(changed, 1)                        // onChangeは1回だけ
        XCTAssertTrue(doc.entities.isEmpty)
        XCTAssertTrue(doc.blockDefinitions.isEmpty)
        XCTAssertEqual(doc.paperSize, .a2)
        XCTAssertEqual(doc.current, DefaultLayers.standardCurrent)
        XCTAssertTrue(doc.groups.allSatisfy { abs($0.scale - 30) < 1e-9 })
        // レイヤ名は標準構成に戻る
        XCTAssertEqual(doc.layer(at: LayerAddress(0, 2)).name, "基本作図")
    }
}
