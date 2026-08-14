import XCTest
@testable import MepCore

/// M5.2: 塗り・ハッチングのテスト
final class HatchTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    /// 100×100の正方形境界
    let square = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)]

    // MARK: - 内外判定

    func testPolygonContains() {
        XCTAssertTrue(HatchGeometry.polygonContains(Vec2(50, 50), square))
        XCTAssertFalse(HatchGeometry.polygonContains(Vec2(150, 50), square))
        XCTAssertFalse(HatchGeometry.polygonContains(Vec2(-1, 50), square))
        // 凹多角形(L字)
        let lShape = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 50), Vec2(50, 50),
                      Vec2(50, 100), Vec2(0, 100)]
        XCTAssertTrue(HatchGeometry.polygonContains(Vec2(25, 75), lShape))
        XCTAssertFalse(HatchGeometry.polygonContains(Vec2(75, 75), lShape))
    }

    // MARK: - パターン線生成

    func testHorizontalStrokes() {
        let pattern = HatchPattern(kind: .horizontal, spacingA: 10)
        let strokes = HatchGeometry.strokes(boundary: square, pattern: pattern)
        // y=0,10,...,100 の11本(境界上の線も含む。0/100は退化することもあるため9〜11本)
        XCTAssertTrue((9...11).contains(strokes.count), "本数: \(strokes.count)")
        // すべて水平で境界内
        for s in strokes {
            XCTAssertEqual(s.a.y, s.b.y, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(min(s.a.x, s.b.x), -1e-9)
            XCTAssertLessThanOrEqual(max(s.a.x, s.b.x), 100 + 1e-9)
        }
    }

    func testVerticalStrokesArePerpendicular() {
        let pattern = HatchPattern(kind: .vertical, spacingA: 25)
        let strokes = HatchGeometry.strokes(boundary: square, pattern: pattern)
        XCTAssertFalse(strokes.isEmpty)
        for s in strokes {
            XCTAssertEqual(s.a.x, s.b.x, accuracy: 1e-6)   // 垂直
        }
    }

    func testAngledStrokesClippedToLShape() {
        // 45°の斜線がL字の凹部に入り込まないこと(凹部内の点を通る線分が無い)
        let lShape = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 50), Vec2(50, 50),
                      Vec2(50, 100), Vec2(0, 100)]
        let pattern = HatchPattern(kind: .horizontal, spacingA: 7, angle: .pi / 4)
        let strokes = HatchGeometry.strokes(boundary: lShape, pattern: pattern)
        XCTAssertFalse(strokes.isEmpty)
        for s in strokes {
            let mid = Vec2((s.a.x + s.b.x) / 2, (s.a.y + s.b.y) / 2)
            XCTAssertTrue(HatchGeometry.polygonContains(mid, lShape)
                          || mid.distance(to: s.a) < 1e-6,
                          "凹部を横切る線分: \(s)")
        }
    }

    func testCrossHasTwoDirections() {
        let pattern = HatchPattern(kind: .cross, spacingA: 20, spacingB: 10)
        let strokes = HatchGeometry.strokes(boundary: square, pattern: pattern)
        let horizontal = strokes.filter { abs($0.a.y - $0.b.y) < 1e-6 }.count
        let vertical = strokes.filter { abs($0.a.x - $0.b.x) < 1e-6 }.count
        XCTAssertGreaterThan(horizontal, 0)
        XCTAssertGreaterThan(vertical, 0)
        XCTAssertEqual(horizontal + vertical, strokes.count)
        // A=20 → 横は約5本、B=10 → 縦は約10本
        XCTAssertGreaterThan(vertical, horizontal)
    }

    func testTwoLineGroups() {
        // A=20(組ピッチ)、B=3(組内)→ y=0,3, 20,23, 40,43…
        let pattern = HatchPattern(kind: .twoLine, spacingA: 20, spacingB: 3)
        let strokes = HatchGeometry.strokes(boundary: square, pattern: pattern)
        let ys = Set(strokes.map { ($0.a.y * 1000).rounded() / 1000 })
        XCTAssertTrue(ys.contains(3))
        XCTAssertTrue(ys.contains(23))
        XCTAssertFalse(ys.contains(10))
    }

    func testBrickHasVerticalJoints() {
        let pattern = HatchPattern(kind: .brick, spacingA: 25, spacingB: 50)
        let strokes = HatchGeometry.strokes(boundary: square, pattern: pattern)
        let joints = strokes.filter { abs($0.a.x - $0.b.x) < 1e-6 }
        XCTAssertFalse(joints.isEmpty)
        // 目地は段高(25)以下の短い線分
        for j in joints {
            XCTAssertLessThanOrEqual(abs(j.a.y - j.b.y), 25 + 1e-6)
        }
    }

    func testSolidHasNoStrokes() {
        XCTAssertTrue(HatchGeometry.strokes(boundary: square,
                                            pattern: HatchPattern(kind: .solid)).isEmpty)
    }

    func testStrokeLimitGuard() {
        // 極小間隔でも上限で打ち切られる(フリーズしない)
        let pattern = HatchPattern(kind: .horizontal, spacingA: 0.011)
        let strokes = HatchGeometry.strokes(boundary: square, pattern: pattern)
        XCTAssertLessThanOrEqual(strokes.count, HatchGeometry.strokeLimit + 10)
    }

    // MARK: - エンティティとしての振る舞い

    func testHatchEntityHitAndBounds() {
        let e = Entity(layer: layer,
                       kind: .hatch(boundary: square, pattern: HatchPattern(kind: .solid)))
        XCTAssertEqual(e.hitDistance(to: Vec2(50, 50)), 0)             // 中=ヒット
        XCTAssertEqual(e.hitDistance(to: Vec2(110, 50)), 10, accuracy: 1e-9)
        let box = e.bounds
        XCTAssertEqual(box.minX, 0)
        XCTAssertEqual(box.maxX, 100)
        XCTAssertTrue(e.isContained(in: BBox(minX: -1, minY: -1, maxX: 101, maxY: 101)))
        XCTAssertTrue(e.intersects(rect: BBox(minX: 40, minY: 40, maxX: 60, maxY: 60)))  // 矩形が完全に中
    }

    func testHatchTransforms() {
        let pattern = HatchPattern(kind: .horizontal, spacingA: 10, angle: 0)
        let e = Entity(layer: layer, kind: .hatch(boundary: square, pattern: pattern))

        let moved = e.translated(by: Vec2(50, 0))
        guard case .hatch(let b1, _) = moved.kind else { return XCTFail() }
        XCTAssertEqual(b1[0], Vec2(50, 0))

        let rotated = e.rotated(around: .zero, byRadians: .pi / 2)
        guard case .hatch(let b2, let p2) = rotated.kind else { return XCTFail() }
        XCTAssertEqual(p2.angle, .pi / 2, accuracy: 1e-9)   // パターン角度も回る
        XCTAssertEqual(b2[1].x, 0, accuracy: 1e-9)          // (100,0)→(0,100)
        XCTAssertEqual(b2[1].y, 100, accuracy: 1e-9)

        let scaled = e.scaled(by: 2, around: .zero)
        guard case .hatch(let b3, let p3) = scaled.kind else { return XCTFail() }
        XCTAssertEqual(b3[2], Vec2(200, 200))
        XCTAssertEqual(p3.spacingA, 20, accuracy: 1e-9)     // 間隔も2倍

        let mirrored = e.mirrored(acrossLineFrom: .zero, to: Vec2(0, 100))
        guard case .hatch(let b4, _) = mirrored.kind else { return XCTFail() }
        XCTAssertEqual(b4[1].x, -100, accuracy: 1e-9)
    }
}
