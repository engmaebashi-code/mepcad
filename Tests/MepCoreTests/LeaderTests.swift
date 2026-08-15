import XCTest
@testable import MepCore

/// 引出線文字・バルーン(M5.5)のジオメトリ・変換テスト
final class LeaderTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    // MARK: - 引出線文字(傍記)

    /// 右向き: 指示点→折れ点+文字下の水平線、文字は折れ点から右へ
    func testPlainLeaderRight() {
        let attrs = LeaderAttributes(balloon: false, arrow: true, textHeight: 175)
        let layout = LeaderGeometry.layout(tip: Vec2(0, 0), elbow: Vec2(500, 300),
                                           content: "VD150", attrs: attrs)
        XCTAssertEqual(layout.segments.count, 2)
        XCTAssertEqual(layout.segments[0].0, Vec2(0, 0))
        XCTAssertEqual(layout.segments[0].1, Vec2(500, 300))
        // 水平線は右へ文字幅ぶん
        let w = LeaderGeometry.textWidth("VD150", height: 175)
        XCTAssertEqual(layout.segments[1].1.x, 500 + w, accuracy: 1e-9)
        XCTAssertEqual(layout.segments[1].1.y, 300, accuracy: 1e-9)
        // 文字は水平線の少し上・折れ点から書き出し
        XCTAssertEqual(layout.texts[0].position.x, 500, accuracy: 1e-9)
        XCTAssertGreaterThan(layout.texts[0].position.y, 300)
        // 矢印は2本
        XCTAssertEqual(layout.arrowStrokes.count, 2)
        XCTAssertEqual(layout.arrowStrokes[0].0, Vec2(0, 0))
        XCTAssertTrue(layout.ellipses.isEmpty)
    }

    /// 左向き: 文字は折れ点から左へ書く(指示点と反対側)
    func testPlainLeaderLeft() {
        let attrs = LeaderAttributes(balloon: false, arrow: false, textHeight: 175)
        let layout = LeaderGeometry.layout(tip: Vec2(1000, 0), elbow: Vec2(200, 300),
                                           content: "AB", attrs: attrs)
        let w = LeaderGeometry.textWidth("AB", height: 175)
        XCTAssertEqual(layout.segments[1].1.x, 200 - w, accuracy: 1e-9)
        XCTAssertEqual(layout.texts[0].position.x, 200 - w, accuracy: 1e-9)
        XCTAssertTrue(layout.arrowStrokes.isEmpty)   // 矢印Off
    }

    // MARK: - バルーン

    /// 楕円は文字ボックスを内包する自動サイズ、引出線は枠の外周まで
    func testBalloonLayout() {
        let attrs = LeaderAttributes(balloon: true, doubleFrame: false,
                                     arrow: true, textHeight: 175, aspectPercent: 80)
        let layout = LeaderGeometry.layout(tip: Vec2(0, 0), elbow: Vec2(1000, 1000),
                                           content: "PAC-1", attrs: attrs)
        XCTAssertEqual(layout.ellipses.count, 1)
        let e = layout.ellipses[0]
        XCTAssertEqual(e.center, Vec2(1000, 1000))
        XCTAssertEqual(e.ry, e.rx * 0.8, accuracy: 1e-9)
        // 文字ボックスの四隅が楕円の内側にある
        let w = LeaderGeometry.textWidth("PAC-1", height: 175)
        for corner in [Vec2(-w / 2, -87.5), Vec2(w / 2, -87.5), Vec2(w / 2, 87.5), Vec2(-w / 2, 87.5)] {
            let q = (corner.x / e.rx) * (corner.x / e.rx) + (corner.y / e.ry) * (corner.y / e.ry)
            XCTAssertLessThanOrEqual(q, 1.0)
        }
        // 引出線は1本、終端は楕円の外周上
        XCTAssertEqual(layout.segments.count, 1)
        let end = layout.segments[0].1
        let q = ((end.x - 1000) / e.rx) * ((end.x - 1000) / e.rx)
              + ((end.y - 1000) / e.ry) * ((end.y - 1000) / e.ry)
        XCTAssertEqual(q, 1.0, accuracy: 1e-6)
        // 文字はバルーン中央(左下基準)
        XCTAssertEqual(layout.texts[0].position.x, 1000 - w / 2, accuracy: 1e-9)
        XCTAssertEqual(layout.texts[0].position.y, 1000 - 87.5, accuracy: 1e-9)
    }

    /// 二重枠: 楕円2個、引出線は外側の枠まで
    func testBalloonDoubleFrame() {
        let attrs = LeaderAttributes(balloon: true, doubleFrame: true,
                                     arrow: false, textHeight: 175, aspectPercent: 80)
        let layout = LeaderGeometry.layout(tip: Vec2(0, 1000), elbow: Vec2(1000, 1000),
                                           content: "P-1", attrs: attrs)
        XCTAssertEqual(layout.ellipses.count, 2)
        XCTAssertEqual(layout.ellipses[1].rx, layout.ellipses[0].rx + attrs.frameOffset,
                       accuracy: 1e-9)
        // 引出線の終端は外側の枠(y=1000の水平線上なのでx = 1000 - 外側rx)
        XCTAssertEqual(layout.segments[0].1.x, 1000 - layout.ellipses[1].rx, accuracy: 1e-6)
    }

    /// 指示点がバルーンの中にあるときは引出線を引かない
    func testBalloonTipInsideNoSegment() {
        let attrs = LeaderAttributes(balloon: true, arrow: true, textHeight: 175)
        let layout = LeaderGeometry.layout(tip: Vec2(1010, 1000), elbow: Vec2(1000, 1000),
                                           content: "P-1", attrs: attrs)
        XCTAssertTrue(layout.segments.isEmpty)
    }

    /// 横サイズ指定: 指定直径がそのまま使われる(文字数に依存しない)
    func testBalloonFixedWidth() {
        let attrs = LeaderAttributes(balloon: true, arrow: true, textHeight: 175,
                                     aspectPercent: 80, balloonWidth: 700)
        let layout = LeaderGeometry.layout(tip: Vec2(0, 0), elbow: Vec2(1000, 1000),
                                           content: "PAC-1", attrs: attrs)
        XCTAssertEqual(layout.ellipses[0].rx, 350, accuracy: 1e-9)
        XCTAssertEqual(layout.ellipses[0].ry, 280, accuracy: 1e-9)
        // 文字数を変えてもサイズは同じ
        let layout2 = LeaderGeometry.layout(tip: Vec2(0, 0), elbow: Vec2(1000, 1000),
                                            content: "P", attrs: attrs)
        XCTAssertEqual(layout2.ellipses[0].rx, 350, accuracy: 1e-9)
    }

    /// 文字幅の見積り: 半角0.62・全角0.95(機器番号の半角列が過大にならない)
    func testTextWidthHalfAndFullWidth() {
        XCTAssertEqual(LeaderGeometry.textWidth("AB", height: 100), 124, accuracy: 1e-9)
        XCTAssertEqual(LeaderGeometry.textWidth("あい", height: 100), 190, accuracy: 1e-9)
        XCTAssertEqual(LeaderGeometry.textWidth("A明", height: 100), 157, accuracy: 1e-9)
    }

    // MARK: - 複数行バルーン(M5.5.2: 「,」区切りで二段・三段)

    /// 「,」区切りで行が分かれ、行間に区切り線(楕円の弦)が入る
    func testBalloonMultiLine() {
        let attrs = LeaderAttributes(balloon: true, arrow: true,
                                     textHeight: 175, aspectPercent: 80)
        let layout = LeaderGeometry.layout(tip: Vec2(0, 0), elbow: Vec2(1000, 1000),
                                           content: "排水管,125φ,GL-250", attrs: attrs)
        XCTAssertEqual(layout.texts.count, 3)
        XCTAssertEqual(layout.texts[0].content, "排水管")
        XCTAssertEqual(layout.texts[1].content, "125φ")
        XCTAssertEqual(layout.texts[2].content, "GL-250")
        XCTAssertEqual(layout.dividers.count, 2)
        // 行は上から下へ並ぶ
        XCTAssertGreaterThan(layout.texts[0].position.y, layout.texts[1].position.y)
        XCTAssertGreaterThan(layout.texts[1].position.y, layout.texts[2].position.y)
        // 各行は水平中央
        let e = layout.ellipses[0]
        for t in layout.texts {
            let w = LeaderGeometry.textWidth(t.content, height: 175)
            XCTAssertEqual(t.position.x + w / 2, 1000, accuracy: 1e-9)
        }
        // 区切り線の端点は内側の楕円周上
        for d in layout.dividers {
            for p in [d.0, d.1] {
                let q = ((p.x - 1000) / e.rx) * ((p.x - 1000) / e.rx)
                      + ((p.y - 1000) / e.ry) * ((p.y - 1000) / e.ry)
                XCTAssertEqual(q, 1.0, accuracy: 1e-6)
            }
        }
        // 自動サイズは3行ぶんの高さを包む(1行より大きい)
        let single = LeaderGeometry.balloonRadii(content: "排水管", attrs: attrs)
        XCTAssertGreaterThan(e.ry, single.ry)
        // 全行の文字ボックスが楕円の内側
        for t in layout.texts {
            let w = LeaderGeometry.textWidth(t.content, height: 175)
            for corner in [Vec2(t.position.x, t.position.y),
                           Vec2(t.position.x + w, t.position.y + 175)] {
                let q = ((corner.x - 1000) / e.rx) * ((corner.x - 1000) / e.rx)
                      + ((corner.y - 1000) / e.ry) * ((corner.y - 1000) / e.ry)
                XCTAssertLessThanOrEqual(q, 1.0 + 1e-9)
            }
        }
    }

    /// 区切りの解釈: 全角カンマも可・空要素は捨てる・区切りなしは1行
    func testSplitLines() {
        XCTAssertEqual(LeaderGeometry.splitLines("A,B"), ["A", "B"])
        XCTAssertEqual(LeaderGeometry.splitLines("A，B，C"), ["A", "B", "C"])
        XCTAssertEqual(LeaderGeometry.splitLines("A,,B"), ["A", "B"])
        XCTAssertEqual(LeaderGeometry.splitLines("PAC-1"), ["PAC-1"])
        XCTAssertEqual(LeaderGeometry.splitLines(" A , B "), ["A", "B"])
    }

    // MARK: - エンティティ(ヒット・変換)

    private func makeBalloon() -> Entity {
        Entity(layer: layer,
               kind: .leader(tip: Vec2(0, 0), elbow: Vec2(1000, 1000), content: "PAC-1",
                             attrs: LeaderAttributes(balloon: true, arrow: true,
                                                     textHeight: 175)))
    }

    /// バルーンの中はどこでもヒット、引出線上もヒット
    func testBalloonHit() {
        let e = makeBalloon()
        XCTAssertEqual(e.hitDistance(to: Vec2(1000, 1000)), 0, accuracy: 1e-9)  // 中心
        XCTAssertEqual(e.hitDistance(to: Vec2(500, 500)), 0, accuracy: 1)       // 引出線上
        XCTAssertGreaterThan(e.hitDistance(to: Vec2(0, 2000)), 500)
    }

    /// boundsはバルーン全体と引出線を覆う
    func testBalloonBounds() {
        let e = makeBalloon()
        let box = e.bounds
        XCTAssertLessThanOrEqual(box.minX, 0)
        XCTAssertLessThanOrEqual(box.minY, 0)
        guard let layout = LeaderGeometry.layout(of: e), let el = layout.ellipses.first else {
            return XCTFail()
        }
        XCTAssertGreaterThanOrEqual(box.maxX, 1000 + el.rx - 1e-9)
        XCTAssertGreaterThanOrEqual(box.maxY, 1000 + el.ry - 1e-9)
    }

    /// 変換: 回転は位置のみ(文字・バルーンは水平のまま)、倍率は文字サイズも追随
    func testTransforms() {
        let e = makeBalloon()

        let moved = e.translated(by: Vec2(100, -100))
        guard case .leader(let tip1, let elbow1, _, _) = moved.kind else { return XCTFail() }
        XCTAssertEqual(tip1, Vec2(100, -100))
        XCTAssertEqual(elbow1, Vec2(1100, 900))

        let rotated = e.rotated(around: Vec2(0, 0), byRadians: .pi / 2)
        guard case .leader(let tip2, let elbow2, _, let attrs2) = rotated.kind else { return XCTFail() }
        XCTAssertEqual(tip2.x, 0, accuracy: 1e-9)
        XCTAssertEqual(elbow2.x, -1000, accuracy: 1e-9)
        XCTAssertEqual(elbow2.y, 1000, accuracy: 1e-9)
        XCTAssertEqual(attrs2.textHeight, 175, accuracy: 1e-9)  // 文字は水平・サイズ不変

        let scaled = e.scaled(by: 2, around: Vec2(0, 0))
        guard case .leader(_, let elbow3, _, let attrs3) = scaled.kind else { return XCTFail() }
        XCTAssertEqual(elbow3, Vec2(2000, 2000))
        XCTAssertEqual(attrs3.textHeight, 350, accuracy: 1e-9)
    }
}
