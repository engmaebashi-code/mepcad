import XCTest
@testable import MepFormats
@testable import MepCore

/// M5.0: DXFパーサ・リーダーの単体テスト(合成データ)
final class DxfParserTests: XCTestCase {

    /// 空行を除去してコード/値の2行ペアの整合を保つ(複数行リテラルの末尾空行対策)
    private func clean(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true).joined(separator: "\n") + "\n"
    }

    private func dxf(_ body: String, header: String = "", blocks: String = "") -> Data {
        var s = ""
        if !header.isEmpty {
            s += "  0\nSECTION\n  2\nHEADER\n" + clean(header) + "  0\nENDSEC\n"
        }
        if !blocks.isEmpty {
            s += "  0\nSECTION\n  2\nBLOCKS\n" + clean(blocks) + "  0\nENDSEC\n"
        }
        s += "  0\nSECTION\n  2\nENTITIES\n" + clean(body) + "  0\nENDSEC\n  0\nEOF\n"
        return s.data(using: .utf8)!
    }

    // MARK: - 基本図形

    func testBasicEntities() throws {
        let body = """
          0
        LINE
          8
        PIPE
         62
             1
         10
        0
         20
        0
         11
        100
         21
        50
          0
        CIRCLE
          8
        PIPE
         10
        10
         20
        20
         40
        5
          0
        ARC
          8
        PIPE
         10
        0
         20
        0
         40
        10
         50
        0
         51
        90
          0
        POINT
          8
        PIPE
         10
        7
         20
        8
          0
        TEXT
          8
        NOTE
         10
        1
         20
        2
         40
        3.5
         50
        45
          1
        FCU-1

        """
        let d = try DxfParser(data: dxf(body)).parse()
        XCTAssertEqual(d.entities.count, 5)
        XCTAssertEqual(d.entities[0].type, "LINE")
        XCTAssertEqual(d.entities[0].colorACI, 1)
        XCTAssertEqual(d.entities[0].x2, 100)
        XCTAssertEqual(d.entities[1].value40, 5)
        XCTAssertEqual(d.entities[2].angle51, 90)
        XCTAssertEqual(d.entities[4].text, "FCU-1")

        let doc = Document()
        let stats = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(stats.entityCount, 5)
        // 色: ACI 1(赤)→パレット1
        guard case .line = doc.entities[0].kind else { return XCTFail() }
        XCTAssertEqual(doc.entities[0].style.colorIndex, 1)
        // 角度は度→ラジアン
        guard case .arc(_, let r, let sa, let ea) = doc.entities[2].kind else { return XCTFail() }
        XCTAssertEqual(r, 10)
        XCTAssertEqual(sa, 0, accuracy: 1e-9)
        XCTAssertEqual(ea, .pi / 2, accuracy: 1e-9)
        guard case .text(_, let content, let h, let angle) = doc.entities[4].kind else { return XCTFail() }
        XCTAssertEqual(content, "FCU-1")
        XCTAssertEqual(h, 3.5, accuracy: 1e-9)
        XCTAssertEqual(angle, .pi / 4, accuracy: 1e-9)
    }

    // MARK: - ポリライン(bulge→円弧)

    func testLwPolylineBulgeToArc() throws {
        // (1,0)→(0,1) bulge=tan(π/8)=90°のCCW弧(中心原点・半径1)+(0,1)→(0,2)の直線
        let bulge = tan(Double.pi / 8)
        let body = """
          0
        LWPOLYLINE
          8
        0
         70
             0
         10
        1
         20
        0
         42
        \(bulge)
         10
        0
         20
        1
         10
        0
         20
        2

        """
        let d = try DxfParser(data: dxf(body)).parse()
        XCTAssertEqual(d.entities.count, 1)
        XCTAssertEqual(d.entities[0].vertices.count, 3)
        XCTAssertEqual(d.entities[0].vertices[0].bulge, bulge, accuracy: 1e-12)

        let doc = Document()
        _ = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(doc.entities.count, 2)
        guard case .arc(let c, let r, _, _) = doc.entities[0].kind else { return XCTFail() }
        XCTAssertEqual(c.x, 0, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r, 1, accuracy: 1e-9)
        guard case .line = doc.entities[1].kind else { return XCTFail() }
    }

    func testPolylineVertexSeqend() throws {
        let body = """
          0
        POLYLINE
          8
        0
         70
             1
          0
        VERTEX
         10
        0
         20
        0
          0
        VERTEX
         10
        100
         20
        0
          0
        VERTEX
         10
        100
         20
        50
          0
        SEQEND

        """
        let d = try DxfParser(data: dxf(body)).parse()
        XCTAssertEqual(d.entities.count, 1)
        XCTAssertEqual(d.entities[0].vertices.count, 3)
        XCTAssertTrue(d.entities[0].closed)
        let doc = Document()
        _ = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(doc.entities.count, 3)   // 閉じているので3辺
    }

    // MARK: - ブロックとINSERT

    func testBlockInsertBecomesBlockRef() throws {
        let blocks = """
          0
        BLOCK
          8
        0
          2
        VALVE
         70
             0
         10
        0
         20
        0
          0
        LINE
          8
        0
         10
        -50
         20
        0
         11
        50
         21
        0
          0
        CIRCLE
          8
        0
         10
        0
         20
        0
         40
        20
          0
        ENDBLK

        """
        let body = """
          0
        INSERT
          8
        PIPE
          2
        VALVE
         10
        1000
         20
        500
         41
        2
         42
        2
         50
        90

        """
        let d = try DxfParser(data: dxf(body, blocks: blocks)).parse()
        XCTAssertEqual(d.blocks.count, 1)
        XCTAssertEqual(d.blocks[0].name, "VALVE")
        XCTAssertEqual(d.blocks[0].entities.count, 2)

        let doc = Document()
        let stats = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(stats.blockRefCount, 1)
        XCTAssertEqual(stats.blockDefinitionCount, 1)
        XCTAssertEqual(doc.blockDefinitions.count, 1)
        XCTAssertEqual(doc.blockDefinitions[0].name, "VALVE")
        guard case .blockRef(let defID, let insert, let rotation, let scale, let mirrored, _)
                = doc.entities[0].kind else { return XCTFail() }
        XCTAssertEqual(defID, doc.blockDefinitions[0].id)
        XCTAssertEqual(insert, Vec2(1000, 500))
        XCTAssertEqual(rotation, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(scale, 2, accuracy: 1e-9)
        XCTAssertFalse(mirrored)
    }

    /// 負の倍率は反転+回転へ正規化される
    func testInsertNegativeScaleNormalization() {
        func placement(sx: Double, sy: Double, deg: Double = 0)
            -> (scale: Double, rotation: Double, mirrored: Bool) {
            var e = DxfEntityData()
            e.type = "INSERT"
            e.scaleX = sx
            e.scaleY = sy
            e.angle50 = deg
            return DxfReader.insertPlacement(e)
        }
        let a = placement(sx: -2, sy: 2)
        XCTAssertTrue(a.mirrored)
        XCTAssertEqual(a.rotation, 0, accuracy: 1e-9)
        XCTAssertEqual(a.scale, 2, accuracy: 1e-9)

        let b = placement(sx: 2, sy: -2)
        XCTAssertTrue(b.mirrored)
        XCTAssertEqual(b.rotation, .pi, accuracy: 1e-9)

        let c = placement(sx: -2, sy: -2)
        XCTAssertFalse(c.mirrored)
        XCTAssertEqual(c.rotation, .pi, accuracy: 1e-9)
    }

    // MARK: - MTEXT整形コード

    func testMTextPlain() {
        XCTAssertEqual(DxfTextDecoder.plainText("{\\fMS Gothic|c128;テスト}\\P2行目"), "テスト 2行目")
        XCTAssertEqual(DxfTextDecoder.plainText("\\A1;350"), "350")
        XCTAssertEqual(DxfTextDecoder.plainText("%%c50"), "φ50")
        XCTAssertEqual(DxfTextDecoder.plainText("45%%d"), "45°")
        XCTAssertEqual(DxfTextDecoder.plainText("\\S1^2;"), "1/2")
        XCTAssertEqual(DxfTextDecoder.plainText("A\\~B"), "A B")
    }

    // MARK: - Shift-JIS(R12系メーカーデータの文字コード)

    func testShiftJisText() throws {
        let body = """
          0
        TEXT
          8
        0
         10
        0
         20
        0
         40
        5
          1
        便器600以上

        """
        let s = "  0\nSECTION\n  2\nENTITIES\n" + clean(body) + "  0\nENDSEC\n  0\nEOF\n"
        // UTF-8では不正になるShift-JISバイト列を作る
        let sjis = s.data(using: .shiftJIS)!
        XCTAssertNil(String(data: sjis, encoding: .utf8))   // 前提: UTF-8厳密読みは失敗する
        let d = try DxfParser(data: sjis).parse()
        XCTAssertEqual(d.entities[0].text, "便器600以上")
    }

    // MARK: - 縮尺・用紙の復元(JWW変換DXFのヘッダ)

    func testScaleAndPaperFromHeader() throws {
        let header = """
          9
        $LTSCALE
         40
        30.0
          9
        $LIMMIN
         10
        0.0
         20
        0.0
          9
        $LIMMAX
         10
        25230.0
         20
        17820.0

        """
        let body = """
          0
        LINE
          8
        0
         10
        0
         20
        0
         11
        25230
         21
        0

        """
        let d = try DxfParser(data: dxf(body, header: header)).parse()
        XCTAssertEqual(d.ltScale, 30)
        let doc = Document()
        let stats = DxfReader.importDrawing(d, into: doc)
        XCTAssertTrue(stats.paperDetected)
        XCTAssertEqual(doc.paperSize, .a1)               // 25230×17820 = A1(841×594)×30
        XCTAssertEqual(doc.currentScale, 30, accuracy: 1e-9)
        // 用紙中心=原点へ平行移動される
        guard case .line(let a, let b) = doc.entities[0].kind else { return XCTFail() }
        XCTAssertEqual(a.x, -12615, accuracy: 1e-6)
        XCTAssertEqual(b.x, 12615, accuracy: 1e-6)
    }

    func testNotADxf() {
        XCTAssertThrowsError(try DxfParser(data: Data("hello".utf8)).parse())
    }

    // MARK: - 塗り(SOLID / HATCH。M5.2)

    /// DXF SOLIDの頂点順はジグザグ(1,2,4,3)
    func testSolidZigzagOrder() throws {
        let body = """
          0
        SOLID
          8
        0
         62
        2
         10
        0
         20
        0
         11
        100
         21
        0
         12
        0
         22
        100
         13
        100
         23
        100
        """
        let d = try DxfParser(data: dxf(body)).parse()
        XCTAssertEqual(d.entities.count, 1)
        let doc = Document()
        _ = DxfReader.importDrawing(d, into: doc)
        XCTAssertEqual(doc.entities.count, 1)
        guard case .hatch(let boundary, let pattern) = doc.entities[0].kind else { return XCTFail() }
        XCTAssertEqual(pattern.kind, .solid)
        // 1,2,4,3 の順=正方形(自己交差しない)
        XCTAssertEqual(boundary, [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)])
    }

    /// HATCH(ソリッド・エッジループ境界)→塗りエンティティ
    func testHatchSolidEdgeLoop() throws {
        let body = """
          0
        HATCH
          8
        0
          2
        SOLID
         70
        1
         91
        1
         92
        0
         93
        3
         72
        1
         10
        0
         20
        0
         11
        100
         21
        0
         72
        1
         10
        100
         20
        0
         11
        50
         21
        80
         72
        1
         10
        50
         20
        80
         11
        0
         21
        0
         75
        0
        """
        let d = try DxfParser(data: dxf(body)).parse()
        XCTAssertEqual(d.entities.count, 1)
        XCTAssertEqual(d.entities[0].vertices.count, 3)
        let doc = Document()
        _ = DxfReader.importDrawing(d, into: doc)
        guard case .hatch(let boundary, let pattern) = doc.entities[0].kind else { return XCTFail() }
        XCTAssertEqual(pattern.kind, .solid)
        XCTAssertEqual(boundary.count, 3)
        XCTAssertEqual(boundary[1], Vec2(100, 0))
    }

    /// HATCH(パターン塗り)は角度と間隔を継承する
    func testHatchPatternInherited() throws {
        let body = """
          0
        HATCH
          8
        0
          2
        ANSI31
         70
        0
         91
        1
         92
        2
         93
        4
         10
        0
         20
        0
         10
        100
         20
        0
         10
        100
         20
        100
         10
        0
         20
        100
         75
        0
         78
        1
         53
        45.0
         43
        0
         44
        0
         45
        -2.5
         46
        2.5
        """
        let d = try DxfParser(data: dxf(body)).parse()
        let doc = Document()
        _ = DxfReader.importDrawing(d, into: doc)
        guard case .hatch(let boundary, let pattern) = doc.entities[0].kind else { return XCTFail() }
        XCTAssertEqual(boundary.count, 4)
        XCTAssertEqual(pattern.kind, .horizontal)
        XCTAssertEqual(pattern.angle, .pi / 4, accuracy: 1e-9)
        XCTAssertEqual(pattern.spacingA, (2.5 * 2.0.squareRoot()), accuracy: 1e-6)
    }

    /// Windows改行(CRLF)のファイルが読めること。
    /// SwiftのStringは\r\nを1文字として扱うため、split(separator: "\n")では
    /// CRLFファイルが分割できない — 実メーカーDXFで発覚した回帰の再発防止
    func testCrlfLineEndings() throws {
        let body = """
          0
        LINE
          8
        0
         10
        0
         20
        0
         11
        100
         21
        0

        """
        let lf = String(data: dxf(body), encoding: .utf8)!
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let d = try DxfParser(data: crlf.data(using: .utf8)!).parse()
        XCTAssertEqual(d.entities.count, 1)
        XCTAssertEqual(d.entities[0].x2, 100)

        // CR単独(旧Mac改行)も読める
        let cr = lf.replacingOccurrences(of: "\n", with: "\r")
        let d2 = try DxfParser(data: cr.data(using: .utf8)!).parse()
        XCTAssertEqual(d2.entities.count, 1)
    }
}
