import XCTest
@testable import MepCore

/// 寸法記入(M5.4)のジオメトリ・変換テスト
final class DimensionTests: XCTestCase {

    let attrs = DimAttributes(terminator: .dot, textHeight: 125, extensionLength: nil)

    // MARK: - レイアウト(投影・寸法値)

    /// 水平寸法: 斜めの2点でもX距離を測る。寸法線は指定点のYを通る
    func testHorizontalLayout() {
        let layout = DimensionGeometry.layout(a: Vec2(0, 0), b: Vec2(1000, 500),
                                              linePoint: Vec2(300, 800),
                                              angle: 0, attrs: attrs)
        XCTAssertEqual(layout.value, 1000, accuracy: 1e-9)
        XCTAssertEqual(layout.dimLine.0.y, 800, accuracy: 1e-9)
        XCTAssertEqual(layout.dimLine.1.y, 800, accuracy: 1e-9)
        XCTAssertEqual(layout.dimLine.0.x, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.dimLine.1.x, 1000, accuracy: 1e-9)
        XCTAssertEqual(layout.textContent, "1000")
        // 補助線2本(測定点→寸法線+はみ出し)
        XCTAssertEqual(layout.extLines.count, 2)
        // 黒丸は寸法線の両端
        XCTAssertEqual(layout.dotCenters.count, 2)
        XCTAssertTrue(layout.arrowStrokes.isEmpty)
    }

    /// 垂直寸法: Y距離
    func testVerticalLayout() {
        let layout = DimensionGeometry.layout(a: Vec2(0, 0), b: Vec2(1000, 500),
                                              linePoint: Vec2(-200, 0),
                                              angle: .pi / 2, attrs: attrs)
        XCTAssertEqual(layout.value, 500, accuracy: 1e-9)
        XCTAssertEqual(layout.dimLine.0.x, -200, accuracy: 1e-9)
        XCTAssertEqual(layout.dimLine.1.x, -200, accuracy: 1e-9)
        XCTAssertEqual(layout.textContent, "500")
    }

    /// 平行寸法: 2点間の実距離
    func testAlignedLayout() {
        let a = Vec2(0, 0)
        let b = Vec2(300, 400)   // 距離500
        let angle = atan2(b.y - a.y, b.x - a.x)
        let layout = DimensionGeometry.layout(a: a, b: b, linePoint: Vec2(-80, 60),
                                              angle: angle, attrs: attrs)
        XCTAssertEqual(layout.value, 500, accuracy: 1e-9)
        XCTAssertEqual(layout.textContent, "500")
    }

    /// 端部=矢印: 1端あたり2本の羽根
    func testArrowTerminator() {
        var arrowAttrs = attrs
        arrowAttrs.terminator = .arrow
        let layout = DimensionGeometry.layout(a: Vec2(0, 0), b: Vec2(1000, 0),
                                              linePoint: Vec2(0, 500),
                                              angle: 0, attrs: arrowAttrs)
        XCTAssertEqual(layout.arrowStrokes.count, 4)
        XCTAssertTrue(layout.dotCenters.isEmpty)
        // 羽根の先端は寸法線の端点
        XCTAssertEqual(layout.arrowStrokes[0].0.x, 0, accuracy: 1e-9)
        XCTAssertEqual(layout.arrowStrokes[2].0.x, 1000, accuracy: 1e-9)
        // d1の羽根はd2側(+X)へ、d2の羽根はd1側(-X)へ
        XCTAssertGreaterThan(layout.arrowStrokes[0].1.x, 0)
        XCTAssertLessThan(layout.arrowStrokes[2].1.x, 1000)
    }

    /// 補助線: nil=測定点まで / 指定長さ / 0=なし
    func testExtensionLengthModes() {
        // 測定点まで: 始点は測定点の近く(離れgap)
        let full = DimensionGeometry.layout(a: Vec2(0, 0), b: Vec2(1000, 0),
                                            linePoint: Vec2(0, 500), angle: 0, attrs: attrs)
        XCTAssertEqual(full.extLines.count, 2)
        XCTAssertEqual(full.extLines[0].0.y, attrs.extensionGap, accuracy: 1e-9)
        // 寸法線を越えるはみ出し
        XCTAssertEqual(full.extLines[0].1.y, 500 + attrs.overshoot, accuracy: 1e-9)

        // 指定長さ: 寸法線から測定点側へ200mm
        var short = attrs
        short.extensionLength = 200
        let s = DimensionGeometry.layout(a: Vec2(0, 0), b: Vec2(1000, 0),
                                         linePoint: Vec2(0, 500), angle: 0, attrs: short)
        XCTAssertEqual(s.extLines[0].0.y, 300, accuracy: 1e-9)

        // 0=補助線なし
        var none = attrs
        none.extensionLength = 0
        let n = DimensionGeometry.layout(a: Vec2(0, 0), b: Vec2(1000, 0),
                                         linePoint: Vec2(0, 500), angle: 0, attrs: none)
        XCTAssertTrue(n.extLines.isEmpty)
    }

    /// 測定点が寸法線上にあるときは補助線を作らない
    func testNoExtensionWhenOnLine() {
        let layout = DimensionGeometry.layout(a: Vec2(0, 0), b: Vec2(1000, 300),
                                              linePoint: Vec2(0, 0), angle: 0, attrs: attrs)
        XCTAssertEqual(layout.extLines.count, 1)  // aは寸法線上なのでb側のみ
    }

    /// 寸法値の表記: ほぼ整数は整数、それ以外は小数1桁
    func testValueFormat() {
        XCTAssertEqual(DimensionGeometry.formatValue(1000), "1000")
        XCTAssertEqual(DimensionGeometry.formatValue(999.98), "1000")
        XCTAssertEqual(DimensionGeometry.formatValue(100.5), "100.5")
        XCTAssertEqual(DimensionGeometry.formatValue(1118.03), "1118")
    }

    /// 寸法値文字は読み下し方向(±90°内)に正規化される
    func testTextReadingDirection() {
        // 180°方向の寸法 → 文字は0°
        let layout = DimensionGeometry.layout(a: Vec2(1000, 0), b: Vec2(0, 0),
                                              linePoint: Vec2(0, 500),
                                              angle: .pi, attrs: attrs)
        XCTAssertEqual(layout.textAngle, 0, accuracy: 1e-9)
    }

    // MARK: - エンティティ(bounds・ヒット・変換)

    private func makeDim() -> Entity {
        Entity(layer: LayerAddress(0, 0),
               kind: .dimension(a: Vec2(0, 0), b: Vec2(1000, 0),
                                linePoint: Vec2(0, 500), angle: 0, attrs: attrs))
    }

    func testBoundsCoverDimLineAndText() {
        let box = makeDim().bounds
        XCTAssertLessThanOrEqual(box.minY, 50.001)     // 補助線の始点(gap)
        XCTAssertGreaterThanOrEqual(box.maxY, 500 + attrs.overshoot - 1e-9)
        XCTAssertLessThanOrEqual(box.minX, 0)
        XCTAssertGreaterThanOrEqual(box.maxX, 1000)
    }

    func testHitOnDimensionLine() {
        let dim = makeDim()
        // 寸法線の中央をクリック
        XCTAssertEqual(dim.hitDistance(to: Vec2(500, 500)), 0, accuracy: 1e-9)
        // 補助線上
        XCTAssertEqual(dim.hitDistance(to: Vec2(0, 250)), 0, accuracy: 1e-9)
        // 離れた点
        XCTAssertGreaterThan(dim.hitDistance(to: Vec2(500, 1000)), 400)
    }

    func testTransformsKeepValue() {
        let dim = makeDim()

        let moved = dim.translated(by: Vec2(100, -50))
        XCTAssertEqual(DimensionGeometry.layout(of: moved)!.value, 1000, accuracy: 1e-9)

        let rotated = dim.rotated(around: Vec2(0, 0), byRadians: .pi / 2)
        let rl = DimensionGeometry.layout(of: rotated)!
        XCTAssertEqual(rl.value, 1000, accuracy: 1e-9)
        // 90°回転後の寸法線は垂直
        XCTAssertEqual(rl.dimLine.0.x, rl.dimLine.1.x, accuracy: 1e-9)

        let mirrored = dim.mirrored(acrossLineFrom: Vec2(0, 0), to: Vec2(0, 100))
        XCTAssertEqual(DimensionGeometry.layout(of: mirrored)!.value, 1000, accuracy: 1e-9)

        let scaled = dim.scaled(by: 2, around: Vec2(0, 0))
        let sl = DimensionGeometry.layout(of: scaled)!
        XCTAssertEqual(sl.value, 2000, accuracy: 1e-9)   // 寸法値は実測なので倍
        if case .dimension(_, _, _, _, let a2) = scaled.kind {
            XCTAssertEqual(a2.textHeight, 250, accuracy: 1e-9)  // 見た目も追随
        } else {
            XCTFail("dimensionでない")
        }
    }

    // MARK: - 回転文字のヒット(M5.4: 縦文字の選択改善)

    /// 90°回転の縦文字は、回転後のグリフ本体のどこでも選択できる
    func testRotatedTextHit() {
        let text = Entity(layer: LayerAddress(0, 0),
                          kind: .text(position: Vec2(0, 0), content: "AC-1",
                                      height: 350, angle: .pi / 2))
        // 幅=4×350×0.9=1260 → 回転後の本体は x∈[-350,0], y∈[0,1260]
        XCTAssertEqual(text.hitDistance(to: Vec2(-175, 600)), 0, accuracy: 1e-9)
        // 旧・未回転ボックスの領域(x>0側)はヒットしない
        XCTAssertGreaterThan(text.hitDistance(to: Vec2(600, 100)), 100)
    }

    /// 270°(=-90°)の縦文字も本体でヒットする
    func testRotatedText270Hit() {
        let text = Entity(layer: LayerAddress(0, 0),
                          kind: .text(position: Vec2(0, 0), content: "AB",
                                      height: 100, angle: -.pi / 2))
        // 幅=180 → 回転後の本体は x∈[0,100], y∈[-180,0]
        XCTAssertEqual(text.hitDistance(to: Vec2(50, -90)), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(text.hitDistance(to: Vec2(50, 90)), 80)
    }

    /// 回転文字の矩形交差判定(交差選択)
    func testRotatedTextIntersects() {
        let text = Entity(layer: LayerAddress(0, 0),
                          kind: .text(position: Vec2(0, 0), content: "AC-1",
                                      height: 350, angle: .pi / 2))
        // 回転後の本体(x∈[-350,0])と重なる矩形
        XCTAssertTrue(text.intersects(rect: BBox(minX: -300, minY: 500, maxX: -100, maxY: 700)))
        // 未回転ボックス側(x>0)の矩形は交差しない
        XCTAssertFalse(text.intersects(rect: BBox(minX: 300, minY: 50, maxX: 700, maxY: 200)))
    }
}
