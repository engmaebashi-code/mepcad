import XCTest
@testable import MepFormats
@testable import MepCore

/// JWW書き出し(M8.1): 書いたものを自前のJwwParser/JwwReaderで読み戻して確かめる
final class JwwWriterTests: XCTestCase {

    /// 1/50のグループ0と1/1のグループ3に要素を置いた図面
    private func makeDocument() -> Document {
        let doc = Document()
        doc.resetForNewDrawing(paperSize: .a2, scaleDenominator: 50)
        doc.updateGroup(3) { $0.scale = 1; $0.name = "図枠" }
        doc.updateLayer(at: LayerAddress(0, 1)) { $0.name = "配管" }
        doc.updateLayer(at: LayerAddress(0, 2)) { $0.isEditable = false }
        doc.updateLayer(at: LayerAddress(0, 3)) { $0.isVisible = false }
        doc.appendBulk([
            Entity(layer: LayerAddress(0, 0), style: Style(colorIndex: 2, lineType: 4),
                   kind: .line(a: Vec2(0, 0), b: Vec2(5000, 2500))),
            Entity(layer: LayerAddress(0, 1), kind: .circle(center: Vec2(1000, 1000), radius: 250)),
            Entity(layer: LayerAddress(0, 1),
                   kind: .arc(center: Vec2(2000, 0), radius: 500, startAngle: 0, endAngle: .pi / 2)),
            Entity(layer: LayerAddress(0, 0),
                   kind: .text(position: Vec2(100, 100), content: "冷媒 φ6.35×φ12.7", height: 125, angle: 0)),
            Entity(layer: LayerAddress(0, 0), kind: .point(position: Vec2(300, 300))),
            Entity(layer: LayerAddress(0, 0),
                   kind: .hatch(boundary: [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)],
                                pattern: HatchPattern(kind: .solid))),
            Entity(layer: LayerAddress(3, 0), kind: .line(a: Vec2(0, 0), b: Vec2(594, 420))),
        ])
        return doc
    }

    func testHeaderRoundTrip() throws {
        let doc = makeDocument()
        let data = JwwWriter(memo: "テスト").data(from: doc)
        XCTAssertEqual(String(bytes: data.prefix(8), encoding: .ascii), "JwwData.")
        let drawing = try JwwParser(data: data).parse()
        XCTAssertEqual(drawing.version, 700)
        XCTAssertEqual(drawing.paperCode, PaperSize.a2.rawValue)
        XCTAssertEqual(drawing.scales[0], 50, accuracy: 1e-9)
        XCTAssertEqual(drawing.scales[3], 1, accuracy: 1e-9)
        // レイヤ状態: 0-0=書込(3) 0-1=編集可(2) 0-2=表示のみ(1) 0-3=非表示(0)
        XCTAssertEqual(drawing.layerStates?[0], 3)
        XCTAssertEqual(drawing.layerStates?[1], 2)
        XCTAssertEqual(drawing.layerStates?[2], 1)
        XCTAssertEqual(drawing.layerStates?[3], 0)
        XCTAssertEqual(drawing.groupStates?[0], 3)      // 書込グループ
        XCTAssertEqual(drawing.groupStates?[3], 2)
    }

    func testEntitiesRoundTrip() throws {
        let doc = makeDocument()
        let data = JwwWriter().data(from: doc)
        let drawing = try JwwParser(data: data).parse()
        // 線2(図枠の線は1/1)、円1+弧1、文字1、ソリッド2(四角は三角2つ)
        XCTAssertEqual(drawing.lines.count, 2)
        XCTAssertEqual(drawing.arcs.count, 2)
        XCTAssertEqual(drawing.texts.count, 1)
        XCTAssertEqual(drawing.solids.count, 2)
        // 図寸で書かれている(1/50 → 5000mm は 100)
        let l0 = drawing.lines.first { $0.glayer == 0 }
        XCTAssertEqual(l0?.x2 ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(l0?.y2 ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(l0?.color, 2)
        XCTAssertEqual(l0?.lntp, 5)                     // 内部4(一点鎖1) → JWW 5
        let l3 = drawing.lines.first { $0.glayer == 3 }
        XCTAssertEqual(l3?.x2 ?? 0, 594, accuracy: 1e-9)
        // 読み戻すと実寸に戻る
        let back = Document()
        JwwReader.importDrawing(drawing, into: back)
        let lines = back.entities.compactMap { e -> (Vec2, Vec2)? in
            if case .line(let a, let b) = e.kind { return (a, b) }
            return nil
        }
        XCTAssertTrue(lines.contains { $0.1.distance(to: Vec2(5000, 2500)) < 1e-6 })
        XCTAssertTrue(lines.contains { $0.1.distance(to: Vec2(594, 420)) < 1e-6 })
        let circles = back.entities.compactMap { e -> (Vec2, Double)? in
            if case .circle(let c, let r) = e.kind { return (c, r) }
            return nil
        }
        XCTAssertEqual(circles.count, 1)
        XCTAssertEqual(circles[0].1, 250, accuracy: 1e-6)
        let texts = back.entities.compactMap { e -> (String, Double)? in
            if case .text(_, let s, let h, _) = e.kind { return (s, h) }
            return nil
        }
        XCTAssertEqual(texts.first?.0, "冷媒 φ6.35×φ12.7")
        XCTAssertEqual(texts.first?.1 ?? 0, 125, accuracy: 1e-6)
    }

    /// 配管・寸法・引出線・ブロックは線・円弧・文字に分解される
    func testCompositeEntitiesExplode() throws {
        let doc = Document()
        doc.resetForNewDrawing(paperSize: .a3, scaleDenominator: 50)
        let def = BlockDefinition(name: "器具", entities: [
            Entity(layer: LayerAddress(0, 0), kind: .line(a: Vec2(-100, 0), b: Vec2(100, 0))),
            Entity(layer: LayerAddress(0, 0), kind: .circle(center: .zero, radius: 50)),
        ])
        doc.addBlockDefinition(def)
        doc.appendBulk([
            Entity(layer: LayerAddress(0, 0),
                   kind: .blockRef(definitionID: def.id, insert: Vec2(1000, 1000), rotation: 0,
                                   scale: 1, mirrored: false, cachedBounds: .empty)),
            Entity(layer: LayerAddress(0, 0),
                   kind: .pipe(points: [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 2000, 0)],
                               attrs: PipeAttributes(size: "50", sizeLabel: "50", outerDiameter: 60,
                                                     annotate: true, doubleLine: false,
                                                     annotateMaterial: false))),
            Entity(layer: LayerAddress(0, 0),
                   kind: .dimension(a: Vec2(0, -500), b: Vec2(3000, -500), linePoint: Vec2(0, -900),
                                    angle: 0, attrs: DimAttributes())),
        ])
        let data = JwwWriter().data(from: doc)
        let drawing = try JwwParser(data: data).parse()
        XCTAssertGreaterThanOrEqual(drawing.lines.count, 4)   // ブロックの線・配管2区間・寸法線
        XCTAssertGreaterThanOrEqual(drawing.arcs.count, 1)    // ブロックの円
        XCTAssertGreaterThanOrEqual(drawing.texts.count, 2)   // 口径傍記・寸法値
        XCTAssertTrue(drawing.texts.contains { $0.text == "50" })
    }

    /// 65535個以上でもMFC流の個数表記(0xFFFF+DWORD)とタグで書ける
    func testLargeCount() throws {
        let doc = Document()
        doc.resetForNewDrawing(paperSize: .a1, scaleDenominator: 100)
        var lines: [Entity] = []
        for i in 0..<70000 {
            let y = Double(i)
            lines.append(Entity(layer: LayerAddress(0, 0), kind: .line(a: Vec2(0, y), b: Vec2(100, y))))
        }
        doc.appendBulk(lines)
        let data = JwwWriter().data(from: doc)
        let drawing = try JwwParser(data: data).parse()
        XCTAssertEqual(drawing.lines.count, 70000)
    }
}
