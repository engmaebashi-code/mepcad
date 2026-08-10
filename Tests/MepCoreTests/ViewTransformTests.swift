import XCTest
@testable import MepCore

final class ViewTransformTests: XCTestCase {

    func testRoundTrip() {
        let t = ViewTransform(scale: 0.25, origin: Vec2(100, 400))
        let world = Vec2(1234.5, -678.9)
        let back = t.toWorld(t.toScreen(world))
        XCTAssertEqual(back.x, world.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, world.y, accuracy: 1e-9)
    }

    func testYAxisFlip() {
        // ワールドY+(上)はスクリーンYが小さくなる(上)方向
        let t = ViewTransform(scale: 1, origin: Vec2(0, 500))
        let low = t.toScreen(Vec2(0, 0))
        let high = t.toScreen(Vec2(0, 100))
        XCTAssertLessThan(high.y, low.y)
    }

    func testZoomKeepsAnchorFixed() {
        var t = ViewTransform(scale: 0.1, origin: Vec2(50, 300))
        let anchor = Vec2(400, 250)  // スクリーン座標
        let worldBefore = t.toWorld(anchor)
        t.zoom(by: 1.8, at: anchor)
        let worldAfter = t.toWorld(anchor)
        XCTAssertEqual(worldBefore.x, worldAfter.x, accuracy: 1e-6)
        XCTAssertEqual(worldBefore.y, worldAfter.y, accuracy: 1e-6)
        XCTAssertEqual(t.scale, 0.18, accuracy: 1e-9)
    }

    func testZoomClamped() {
        var t = ViewTransform(scale: 900, origin: .zero)
        t.zoom(by: 100, at: Vec2(0, 0))
        XCTAssertLessThanOrEqual(t.scale, 1000)
        var t2 = ViewTransform(scale: 0.001, origin: .zero)
        t2.zoom(by: 0.0001, at: Vec2(0, 0))
        XCTAssertGreaterThanOrEqual(t2.scale, 0.0005)
    }

    func testFitContainsBox() {
        var t = ViewTransform()
        let box = BBox(minX: 0, minY: 0, maxX: 10000, maxY: 8000)
        let viewSize = Vec2(1200, 800)
        t.fit(box, in: viewSize)
        // 四隅がビュー内に収まる
        for corner in [Vec2(0, 0), Vec2(10000, 0), Vec2(0, 8000), Vec2(10000, 8000)] {
            let s = t.toScreen(corner)
            XCTAssertGreaterThanOrEqual(s.x, -1)
            XCTAssertGreaterThanOrEqual(s.y, -1)
            XCTAssertLessThanOrEqual(s.x, viewSize.x + 1)
            XCTAssertLessThanOrEqual(s.y, viewSize.y + 1)
        }
    }
}
