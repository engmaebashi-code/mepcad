import XCTest
@testable import MepCore

/// 配管エンティティ(M6.0)のジオメトリ・変換テスト
final class PipeTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    private func makePipe(_ points: [Vec2], annotate: Bool = true) -> Entity {
        Entity(layer: layer,
               style: Style(colorIndex: 2, lineType: 0),
               kind: .pipe(points: points,
                           attrs: PipeAttributes(usage: "CW", usageName: "給水",
                                                 material: "HIVP", materialLabel: "HIVP",
                                                 size: "50", sizeLabel: "50",
                                                 outerDiameter: 60,
                                                 annotate: annotate, textHeight: 125)))
    }

    /// 傍記は最長セグメントの中央・線の上側・読み下し方向
    func testAnnotationOnLongestSegment() {
        let points = [Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 5000)]
        guard case .pipe(_, let attrs) = makePipe(points).kind,
              let note = PipeGeometry.annotation(points: points, attrs: attrs) else {
            return XCTFail()
        }
        XCTAssertEqual(note.content, "50")
        // 最長は垂直セグメント(5000)→ 90°は読み下しで90°のまま
        XCTAssertEqual(note.angle, .pi / 2, accuracy: 1e-9)
        // 中央(y=2500)付近・線の左側(x<1000)
        let w = PipeGeometry.textWidth("50", height: 125)
        XCTAssertEqual(note.position.y, 2500 - w / 2, accuracy: 1e-9)
        XCTAssertLessThan(note.position.x, 1000)
    }

    /// 左向きセグメントの傍記は反転して読める向きになる
    func testAnnotationReadingDirection() {
        let points = [Vec2(1000, 0), Vec2(0, 0)]   // 180°方向
        guard case .pipe(_, let attrs) = makePipe(points).kind,
              let note = PipeGeometry.annotation(points: points, attrs: attrs) else {
            return XCTFail()
        }
        XCTAssertEqual(note.angle, 0, accuracy: 1e-9)
    }

    func testAnnotationOffWhenDisabled() {
        let points = [Vec2(0, 0), Vec2(1000, 0)]
        guard case .pipe(_, let attrs) = makePipe(points, annotate: false).kind else {
            return XCTFail()
        }
        XCTAssertNil(PipeGeometry.annotation(points: points, attrs: attrs))
    }

    func testLength() {
        XCTAssertEqual(PipeGeometry.length(of: [Vec2(0, 0), Vec2(3000, 0), Vec2(3000, 4000)]),
                       7000, accuracy: 1e-9)
        XCTAssertEqual(PipeGeometry.length(of: [Vec2(0, 0)]), 0)
    }

    /// 折れ線のどこでもヒット、boundsは傍記も含む
    func testHitAndBounds() {
        let e = makePipe([Vec2(0, 0), Vec2(2000, 0), Vec2(2000, 2000)])
        XCTAssertEqual(e.hitDistance(to: Vec2(1000, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(e.hitDistance(to: Vec2(2000, 1500)), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(e.hitDistance(to: Vec2(0, 2000)), 1000)
        let box = e.bounds
        XCTAssertLessThanOrEqual(box.minX, 0)
        XCTAssertGreaterThanOrEqual(box.maxY, 2000)
    }

    /// 変換: 倍率は延長だけ変わり口径(外径・呼び径)は不変
    func testTransforms() {
        let e = makePipe([Vec2(0, 0), Vec2(1000, 0)])

        let moved = e.translated(by: Vec2(0, 500))
        guard case .pipe(let p1, _) = moved.kind else { return XCTFail() }
        XCTAssertEqual(p1[0], Vec2(0, 500))

        let rotated = e.rotated(around: Vec2(0, 0), byRadians: .pi / 2)
        guard case .pipe(let p2, _) = rotated.kind else { return XCTFail() }
        XCTAssertEqual(p2[1].x, 0, accuracy: 1e-9)
        XCTAssertEqual(p2[1].y, 1000, accuracy: 1e-9)

        let scaled = e.scaled(by: 2, around: Vec2(0, 0))
        guard case .pipe(let p3, let attrs3) = scaled.kind else { return XCTFail() }
        XCTAssertEqual(p3[1], Vec2(2000, 0))
        XCTAssertEqual(attrs3.outerDiameter, 60, accuracy: 1e-9)   // 口径は実物なので不変
        XCTAssertEqual(attrs3.sizeLabel, "50")
        XCTAssertEqual(attrs3.textHeight, 250, accuracy: 1e-9)     // 傍記文字は追随
    }
}
