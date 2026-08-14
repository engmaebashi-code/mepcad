import XCTest
@testable import MepFormats
@testable import MepCore

/// M5.0: 実メーカーCADデータ(TOTO/LG/ダイキン)に対するDXF読込の回帰テスト。
/// 期待値はPython参照実装(パーサの忠実移植)による解析結果。
final class DxfFixtureTests: XCTestCase {

    private func fixturesURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Fixturesフォルダがバンドルにありません")
        }
        return url
    }

    private func load(_ name: String) throws -> DxfDrawing {
        let url = try fixturesURL().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) がありません")
        }
        return try DxfParser(data: Data(contentsOf: url)).parse()
    }

    private func kindCounts(_ doc: Document) -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in doc.entities {
            let key: String
            switch e.kind {
            case .line: key = "line"
            case .circle: key = "circle"
            case .arc: key = "arc"
            case .text: key = "text"
            case .point: key = "point"
            case .blockRef: key = "blockRef"
            case .hatch: key = "hatch"
            }
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// TOTO 大便器(ヘッダ最小・R12相当・ブロックなし)
    func testToto() throws {
        let d = try load("CES9530C.DXF")
        XCTAssertNil(d.acadVersion)
        XCTAssertEqual(d.layers.count, 3)
        XCTAssertTrue(d.skippedTypes.isEmpty)

        let doc = Document()
        let stats = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(stats.entityCount, 537)
        let counts = kindCounts(doc)
        XCTAssertEqual(counts["line"], 215)
        XCTAssertEqual(counts["arc"], 320)
        XCTAssertEqual(counts["circle"], 1)
        XCTAssertEqual(counts["point"], 1)
        // 全レイヤが選択可能な状態で開く
        XCTAssertTrue(doc.entities.allSatisfy { doc.isSelectable($0.layer) })
    }

    /// LG 空調機(R12・Shift-JIS・TEXTに日本語)
    func testLg() throws {
        let d = try load("LGHN50RXW3.dxf")
        XCTAssertEqual(d.acadVersion, "AC1009")
        XCTAssertEqual(d.layers.count, 12)

        let doc = Document()
        let stats = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(stats.entityCount, 633)
        let counts = kindCounts(doc)
        XCTAssertEqual(counts["line"], 419)
        XCTAssertEqual(counts["arc"], 104)
        XCTAssertEqual(counts["circle"], 38)
        XCTAssertEqual(counts["text"], 26)
        XCTAssertEqual(counts["point"], 46)

        // Shift-JISの日本語が読めている
        let texts = doc.entities.compactMap { e -> String? in
            if case .text(_, let content, _, _) = e.kind { return content }
            return nil
        }
        XCTAssertTrue(texts.contains("600以上"), "実際: \(texts.prefix(8))")
        XCTAssertTrue(texts.contains("150～250"))
    }

    /// ダイキン 屋外機(R13相当・MTEXT・POLYLINE)
    func testDaikinOutdoor() throws {
        let d = try load("RSRP160D.DXF")
        XCTAssertEqual(d.acadVersion, "AC1012")
        XCTAssertEqual(d.skippedTypes["VIEWPORT"], 2)

        let doc = Document()
        let stats = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(stats.entityCount, 541)
        let counts = kindCounts(doc)
        XCTAssertEqual(counts["line"], 436)      // LINE 422 + POLYLINE分解 14
        XCTAssertEqual(counts["arc"], 73)        // ARC 60 + bulge円弧 13
        XCTAssertEqual(counts["circle"], 6)
        XCTAssertEqual(counts["text"], 26)       // TEXT 1 + MTEXT 25

        // MTEXTの書式コード(\A1;等)が落ちている
        for e in doc.entities {
            if case .text(_, let content, _, _) = e.kind {
                XCTAssertFalse(content.contains("\\A"), "整形コード残り: \(content)")
                XCTAssertFalse(content.contains("{"))
            }
        }
    }

    /// ダイキン 天井吊形(R13相当)
    func testDaikinIndoor() throws {
        let d = try load("FHCP160GA.DXF")
        XCTAssertEqual(d.acadVersion, "AC1012")

        let doc = Document()
        let stats = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(stats.entityCount, 650)
        let counts = kindCounts(doc)
        XCTAssertEqual(counts["line"], 526)      // LINE 459 + POLYLINE分解 67
        XCTAssertEqual(counts["arc"], 89)        // ARC 54 + bulge円弧 35
        XCTAssertEqual(counts["circle"], 5)
        XCTAssertEqual(counts["text"], 30)       // TEXT 1 + MTEXT 29

        // 実寸のバウンディングボックス(Python参照実装の値と一致すること。
        // 文字は位置点のみ・円弧は全周ボックスというMepCad側の仕様で計算)
        let box = doc.bounds
        XCTAssertEqual(box.minX, -1418.7, accuracy: 1)
        XCTAssertEqual(box.minY, -1115.0, accuracy: 1)
        XCTAssertEqual(box.maxX, 1493.2, accuracy: 1)
        XCTAssertEqual(box.maxY, 1325.0, accuracy: 1)
    }
}
