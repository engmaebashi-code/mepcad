import XCTest
@testable import MepTools
@testable import MepCore

final class SnapEngineTests: XCTestCase {

    /// 十字に交差する2本の線を持つドキュメント
    func makeDocument() -> Document {
        let document = Document()
        document.removeAllEntities()
        let layer = document.current
        document.add(Entity(layer: layer, kind: .line(a: Vec2(0, 500), b: Vec2(1000, 500))))
        document.add(Entity(layer: layer, kind: .line(a: Vec2(500, 0), b: Vec2(500, 1000))))
        document.add(Entity(layer: layer, kind: .circle(center: Vec2(3000, 3000), radius: 200)))
        return document
    }

    func makeEngine(_ document: Document) -> SnapEngine {
        let engine = SnapEngine()
        engine.settings.grid = false  // テストではグリッドを切って個別種別を検証
        engine.rebuild(from: document)
        return engine
    }

    func testEndpointSnap() {
        let engine = makeEngine(makeDocument())
        let r = engine.snap(Vec2(990, 495), radius: 50)
        XCTAssertEqual(r?.kind, .endpoint)
        XCTAssertEqual(r?.point, Vec2(1000, 500))
    }

    func testIntersectionSnap() {
        let engine = makeEngine(makeDocument())
        // 交点(500,500)の近く(端点からは遠い)
        let r = engine.snap(Vec2(485, 515), radius: 40)
        XCTAssertEqual(r?.kind, .intersection)
        XCTAssertEqual(r!.point.x, 500, accuracy: 1e-6)
        XCTAssertEqual(r!.point.y, 500, accuracy: 1e-6)
    }

    func testMidpointSnap() {
        let engine = makeEngine(makeDocument())
        // 水平線の中点(500,500)は交点と同一なので、垂直線の中点は(500,500)…同じ。
        // 端点・交点から離れた水平線中点はないため、中点だけONにして検証
        engine.settings.endpoint = false
        engine.settings.intersection = false
        let r = engine.snap(Vec2(495, 505), radius: 40)
        XCTAssertEqual(r?.kind, .midpoint)
    }

    func testCircleCenterSnap() {
        let engine = makeEngine(makeDocument())
        let r = engine.snap(Vec2(3010, 2990), radius: 50)
        XCTAssertEqual(r?.kind, .center)
        XCTAssertEqual(r?.point, Vec2(3000, 3000))
    }

    func testOnLineSnap() {
        let engine = makeEngine(makeDocument())
        // 水平線の途中(端点・中点・交点から離れた位置)の少し上
        let r = engine.snap(Vec2(200, 512), radius: 30)
        XCTAssertEqual(r?.kind, .onLine)
        XCTAssertEqual(r!.point.x, 200, accuracy: 1e-6)
        XCTAssertEqual(r!.point.y, 500, accuracy: 1e-6)
    }

    func testPriorityEndpointBeatsOnLine() {
        let engine = makeEngine(makeDocument())
        // 端点(0,500)のすぐ近く: 線上にも乗るが端点が勝つ
        let r = engine.snap(Vec2(8, 505), radius: 30)
        XCTAssertEqual(r?.kind, .endpoint)
    }

    func testDisabledKindIsSkipped() {
        let engine = makeEngine(makeDocument())
        engine.settings.endpoint = false
        engine.settings.intersection = false
        engine.settings.midpoint = false
        engine.settings.onLine = false
        engine.settings.center = false
        XCTAssertNil(engine.snap(Vec2(990, 495), radius: 50))
    }

    func testIntersectionBeatsFartherEndpoint() {
        // 端点がカーソル半径内に居ても、交点の方が明確に近ければ交点が勝つ(重み付き競争)
        let document = Document()
        let layer = document.current
        document.add(Entity(layer: layer, kind: .line(a: Vec2(0, 500), b: Vec2(1000, 500))))
        document.add(Entity(layer: layer, kind: .line(a: Vec2(500, 0), b: Vec2(500, 1000))))
        // 交点(500,500)の近くに端点(560,500)を作る短い線
        document.add(Entity(layer: layer, kind: .line(a: Vec2(560, 500), b: Vec2(560, 300))))
        let engine = makeEngine(document)
        // カーソル(515,495): 交点まで15.8mm、端点560まで45.3mm — 両方半径内
        let r = engine.snap(Vec2(515, 495), radius: 60)
        XCTAssertEqual(r?.kind, .intersection)
        XCTAssertEqual(r!.point.x, 500, accuracy: 1e-6)
    }

    func testEndpointBeatsIntersectionWhenCloser() {
        let engine = makeEngine(makeDocument())
        // 端点(1000,500)のすぐ近く
        let r = engine.snap(Vec2(995, 503), radius: 60)
        XCTAssertEqual(r?.kind, .endpoint)
    }

    func testSegmentIntersectionMath() {
        let p = SnapEngine.segmentIntersection(Vec2(0, 0), Vec2(100, 100), Vec2(0, 100), Vec2(100, 0))
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.x, 50, accuracy: 1e-9)
        XCTAssertEqual(p!.y, 50, accuracy: 1e-9)
        // 平行線は交点なし
        XCTAssertNil(SnapEngine.segmentIntersection(Vec2(0, 0), Vec2(100, 0), Vec2(0, 10), Vec2(100, 10)))
        // 線分範囲外(延長線上でのみ交差)もなし
        XCTAssertNil(SnapEngine.segmentIntersection(Vec2(0, 0), Vec2(10, 10), Vec2(0, 100), Vec2(100, 0)))
    }
}
