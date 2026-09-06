import XCTest
@testable import MepCore

/// .mepcad(自前形式)の保存・復元 M8.1
final class DocumentSnapshotTests: XCTestCase {

    func testRoundTripKeepsEverything() throws {
        let doc = Document()
        doc.resetForNewDrawing(paperSize: .a2, scaleDenominator: 30)
        doc.setLevelDatum("2FL")
        doc.updateGroup(2) { $0.name = "設備"; $0.scale = 50 }
        doc.updateLayer(at: LayerAddress(2, 1)) { $0.name = "配管"; $0.isEditable = false }
        let def = BlockDefinition(name: "室内機", entities: [
            Entity(layer: LayerAddress(0, 0), kind: .line(a: .zero, b: Vec2(840, 0)))],
            ports: [BlockPort(position: Vec2(0, 0), azimuth: 0, name: "液",
                              sizeLabel: "φ6.35", outerDiameter: 6.35, usage: "R")])
        doc.addBlockDefinition(def)
        doc.appendBulk([
            Entity(layer: LayerAddress(2, 1), style: Style(colorIndex: 9, lineType: 8),
                   kind: .pipe(points: [Vec3(0, 0, 0), Vec3(1000, 0, 0)],
                               attrs: PipeAttributes(usage: "R", usageName: "冷媒", material: "CUR",
                                                     size: "6.35", sizeLabel: "φ6.35", outerDiameter: 6.35,
                                                     branchReversed: true, bendRadius: 40,
                                                     pairSizeLabel: "φ12.7", pairOuterDiameter: 12.7))),
            Entity(layer: LayerAddress(0, 0),
                   kind: .blockRef(definitionID: def.id, insert: Vec2(10, 20), rotation: 0.5,
                                   scale: 1, mirrored: true, cachedBounds: .empty)),
        ])
        _ = doc.setCurrent(LayerAddress(2, 0))

        let data = try doc.serialize()
        let back = Document()
        try back.load(from: data)
        XCTAssertEqual(back.paperSize, .a2)
        XCTAssertEqual(back.levelDatum, "2FL")
        XCTAssertEqual(back.groups, doc.groups)
        XCTAssertEqual(back.current, LayerAddress(2, 0))
        XCTAssertEqual(back.blockDefinitions, doc.blockDefinitions)
        XCTAssertEqual(back.entities, doc.entities)
    }

    /// 後から足した配管属性のキーが無くても読める(前方互換)
    func testPipeAttributesDecodeWithMissingKeys() throws {
        let json = """
        {"usage":"CW","usageName":"給水","material":"HIVP","materialLabel":"HIVP","size":"20",
         "sizeLabel":"20","outerDiameter":26,"annotate":true,"textHeight":125,"datum":"1FL",
         "showLevel":false,"doubleLine":false,"autoFittings":true,"fittingSeries":"HI",
         "fittingDims":{"elbow90A":0,"elbow45A":0,"teeA":0,"socketDepth":0,"socketOD":0,
         "capLength":0,"elbow90LLA":0,"y45A":0},"capEnds":false,"symbolSize":0,
         "longRadius":false,"annotateMaterial":true,"branchKind":"DT"}
        """
        let a = try JSONDecoder().decode(PipeAttributes.self, from: Data(json.utf8))
        XCTAssertEqual(a.size, "20")
        XCTAssertFalse(a.branchReversed)
        XCTAssertEqual(a.bendRadius, 0)
        XCTAssertFalse(a.isPair)
    }
}
