import XCTest
@testable import MepTools
@testable import MepCore

/// 接続口へのスナップ(M7)
final class PortSnapTests: XCTestCase {

    private func attrs() -> PipeAttributes {
        PipeAttributes(usage: "S", usageName: "汚水", material: "VP", materialLabel: "VP",
                       size: "100", sizeLabel: "100", outerDiameter: 114,
                       fittingSeries: "DV",
                       fittingDims: PipeFittingDims(elbow90A: 112, elbow45A: 67, teeA: 113,
                                                    socketDepth: 50, socketOD: 124))
    }

    private func makeDocument(_ build: (Document, LayerAddress) -> Void) -> Document {
        let document = Document()
        document.removeAllEntities()
        build(document, document.current)
        return document
    }

    private func makeEngine(_ document: Document) -> SnapEngine {
        let engine = SnapEngine()
        engine.settings.grid = false
        engine.rebuild(from: document)
        return engine
    }

    /// 配管の自由端は「接続口」として吸着する(同じ位置の端点より優先)
    func testFreeEndSnapsAsPort() {
        let doc = makeDocument { d, layer in
            d.add(Entity(layer: layer,
                         kind: .pipe(points: [Vec3(0, 0, 0), Vec3(5000, 0, 0)], attrs: attrs())))
        }
        let engine = makeEngine(doc)
        let r = engine.snap(Vec2(4990, 8), radius: 50)
        XCTAssertEqual(r?.kind, .port)
        XCTAssertEqual(r?.point, Vec2(5000, 0))
        XCTAssertEqual(SnapKind.port.label, "接続口")
    }

    /// 吸着した口から口径・管種を引ける(作図側が引き継ぐために使う)
    func testPortLookupCarriesAttributes() {
        let doc = makeDocument { d, layer in
            d.add(Entity(layer: layer,
                         kind: .pipe(points: [Vec3(0, 0, 0), Vec3(5000, 0, 0)], attrs: attrs())))
        }
        let engine = makeEngine(doc)
        let port = engine.port(at: Vec2(5010, 0), radius: 50)
        XCTAssertEqual(port?.sizeLabel, "100")
        XCTAssertEqual(port?.material, "VP")
        XCTAssertEqual(port?.usage, "S")
        XCTAssertEqual(port?.socketDepth, 50)
    }

    /// 接続済みの端(2本が突き合わさっている点)には接続口が出ない
    func testConnectedEndIsNotAPort() {
        let doc = makeDocument { d, layer in
            d.add(Entity(layer: layer,
                         kind: .pipe(points: [Vec3(0, 0, 0), Vec3(3000, 0, 0)], attrs: attrs())))
            d.add(Entity(layer: layer,
                         kind: .pipe(points: [Vec3(3000, 0, 0), Vec3(6000, 0, 0)], attrs: attrs())))
        }
        let engine = makeEngine(doc)
        XCTAssertNil(engine.port(at: Vec2(3000, 0), radius: 50))
        XCTAssertEqual(engine.snap(Vec2(3000, 5), radius: 50)?.kind, .endpoint)
        XCTAssertEqual(engine.indexedOpenPorts.count, 2)
    }

    /// 機器(ポート付きブロック)の接続口にも吸着する
    func testEquipmentPortSnaps() {
        var def = BlockDefinition(name: "洗面器", entities: [
            Entity(layer: LayerAddress(0, 0), kind: .line(a: Vec2(-200, -200), b: Vec2(200, 200)))
        ])
        def.ports = [BlockPort(position: Vec2(0, 300), azimuth: .pi / 2, z: 500,
                               name: "排水", sizeLabel: "50", outerDiameter: 60, usage: "W")]
        let doc = makeDocument { d, layer in
            d.addBlockDefinition(def)
            d.add(Entity(layer: layer,
                         kind: .blockRef(definitionID: def.id, insert: Vec2(2000, 1000),
                                         rotation: 0, scale: 1, mirrored: false,
                                         cachedBounds: def.bounds(insert: Vec2(2000, 1000),
                                                                  rotation: 0, scale: 1,
                                                                  mirrored: false))))
        }
        let engine = makeEngine(doc)
        let r = engine.snap(Vec2(2005, 1295), radius: 40)
        XCTAssertEqual(r?.kind, .port)
        XCTAssertEqual(r?.point, Vec2(2000, 1300))
        let port = engine.port(at: Vec2(2000, 1300), radius: 10)
        XCTAssertEqual(port?.name, "排水")
        XCTAssertEqual(port?.position.z, 500)
        XCTAssertEqual(port?.role, .equipment)
    }

    /// 設定で接続口スナップを切れる
    func testPortSnapCanBeDisabled() {
        let doc = makeDocument { d, layer in
            d.add(Entity(layer: layer,
                         kind: .pipe(points: [Vec3(0, 0, 0), Vec3(5000, 0, 0)], attrs: attrs())))
        }
        let engine = makeEngine(doc)
        engine.settings.port = false
        XCTAssertEqual(engine.snap(Vec2(4990, 8), radius: 50)?.kind, .endpoint)
    }
}
