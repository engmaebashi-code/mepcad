import XCTest
@testable import MepCore

/// 配管エンティティ(M6.0)のジオメトリ・変換テスト
final class PipeTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    private func v3(_ pts: [Vec2]) -> [Vec3] { pts.map { Vec3($0, z: 0) } }

    private func makePipe(_ points: [Vec2], annotate: Bool = true) -> Entity {
        Entity(layer: layer,
               style: Style(colorIndex: 2, lineType: 0),
               kind: .pipe(points: v3(points),
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
              let note = PipeGeometry.annotation(points: v3(points), attrs: attrs) else {
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
              let note = PipeGeometry.annotation(points: v3(points), attrs: attrs) else {
            return XCTFail()
        }
        XCTAssertEqual(note.angle, 0, accuracy: 1e-9)
    }

    func testAnnotationOffWhenDisabled() {
        let points = [Vec2(0, 0), Vec2(1000, 0)]
        guard case .pipe(_, let attrs) = makePipe(points, annotate: false).kind else {
            return XCTFail()
        }
        XCTAssertNil(PipeGeometry.annotation(points: v3(points), attrs: attrs))
    }

    func testLength() {
        XCTAssertEqual(PipeGeometry.length(of: v3([Vec2(0, 0), Vec2(3000, 0), Vec2(3000, 4000)])),
                       7000, accuracy: 1e-9)
        XCTAssertEqual(PipeGeometry.length(of: [Vec3(0, 0, 0)]), 0)
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

    // MARK: - M6.1: 高さ・複線・継手

    func testLevelLabelAndAnnotation() {
        var attrs = PipeAttributes(sizeLabel: "50", textHeight: 125, datum: "2FL")
        XCTAssertEqual(attrs.levelLabel(0), "2FL±0")
        XCTAssertEqual(attrs.levelLabel(2500), "2FL+2500")
        attrs.datum = "GL"
        XCTAssertEqual(attrs.levelLabel(-300), "GL-300")
        XCTAssertEqual(PipeGeometry.annotationText(attrs, z: -300), "50")
        attrs.showLevel = true
        XCTAssertEqual(PipeGeometry.annotationText(attrs, z: -300), "50 GL-300")
        // 傍記は最長区間のz(水平区間)を使う
        let pts = [Vec3(0, 0, 2500), Vec3(3000, 0, 2500)]
        XCTAssertEqual(PipeGeometry.annotation(points: pts, attrs: attrs)?.content, "50 GL+2500")
    }

    /// 立管: 平面同一点でz違いの隣接頂点。上り/下りを判定、ランは立管で切れる
    func testRisersAndPlanRuns() {
        let pts = [Vec3(0, 0, 0), Vec3(2000, 0, 0),
                   Vec3(2000, 0, 3000),            // 立上り+3000
                   Vec3(2000, 1500, 3000),
                   Vec3(2000, 1500, 500),          // 立下り-2500
                   Vec3(4000, 1500, 500)]
        let risers = PipeGeometry.risers(points: pts)
        XCTAssertEqual(risers.count, 2)
        XCTAssertEqual(risers[0].position, Vec2(2000, 0))
        XCTAssertTrue(risers[0].isUp)
        XCTAssertEqual(risers[0].deltaZ, 3000, accuracy: 1e-9)
        XCTAssertFalse(risers[1].isUp)
        let runs = PipeGeometry.planRuns(points: pts)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].count, 2)
        XCTAssertEqual(runs[1].map(\.xy), [Vec2(2000, 0), Vec2(2000, 1500)])
        // 平面線分は3本(立管は長さ0で除外)
        XCTAssertEqual(PipeGeometry.planSegments(points: pts).count, 3)
        // 3D延長: 2000+3000+1500+2500+2000
        XCTAssertEqual(PipeGeometry.length(of: pts), 11000, accuracy: 1e-9)
        // 立管の付け根は90°エルボ×2、天端も×2 → 4個
        XCTAssertEqual(PipeGeometry.fittings(points: pts).filter { $0.kind == .elbow90 }.count, 4)
    }

    /// 立管だけの配管もヒット・boundsが成立する(記号の円)
    func testRiserOnlyPipeHit() {
        let attrs = PipeAttributes(outerDiameter: 60, annotate: false, textHeight: 125)
        let e = Entity(layer: layer,
                       kind: .pipe(points: [Vec3(500, 500, 0), Vec3(500, 500, 2800)], attrs: attrs))
        let rs = PipeGeometry.riserSymbolRadius(attrs)
        XCTAssertEqual(e.hitDistance(to: Vec2(500, 500)), 0, accuracy: 1e-9)
        XCTAssertEqual(e.hitDistance(to: Vec2(500 + rs + 10, 500)), 10, accuracy: 1e-9)
        XCTAssertFalse(e.bounds.isEmpty)
        XCTAssertTrue(e.intersects(rect: BBox(minX: 0, minY: 0, maxX: 1000, maxY: 1000)))
    }

    /// 折れ点の継手判定: 90°/45°/直進なし
    func testFittingsDetection() {
        let pts = v3([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000),   // 90°
                      Vec2(2000, 2000),                             // 45°
                      Vec2(3000, 3000)])                            // 直進(継手なし)
        let f = PipeGeometry.fittings(points: pts)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f[0].kind, .elbow90)
        XCTAssertEqual(f[0].position, Vec2(1000, 0))
        XCTAssertEqual(f[1].kind, .elbow45)
        XCTAssertEqual(f[1].position, Vec2(1000, 1000))
        XCTAssertTrue(PipeGeometry.fittings(points: v3([Vec2(0, 0), Vec2(1000, 0)])).isEmpty)
    }

    /// 複線: 外形線は芯から±r、直角の折れ点はマイター(角の外側は(r,r)だけ張り出す)
    func testDoubleLineMiter() {
        let attrs = PipeAttributes(outerDiameter: 100, doubleLine: true, autoFittings: true)
        let pts = v3([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000)])
        guard let layout = PipeGeometry.doubleLineLayout(points: pts, attrs: attrs),
              layout.runs.count == 1 else {
            return XCTFail()
        }
        let run = layout.runs[0]
        XCTAssertEqual(run.left.count, 3)
        XCTAssertEqual(run.right.count, 3)
        // 始点: 左法線(0,1)×50
        XCTAssertEqual(run.left[0], Vec2(0, 50))
        XCTAssertEqual(run.right[0], Vec2(0, -50))
        // 折れ点のマイター: 進行→+x→+y、左側は内側(950,50)、右側は外側(1050,-50)
        XCTAssertEqual(run.left[1].x, 950, accuracy: 1e-9)
        XCTAssertEqual(run.left[1].y, 50, accuracy: 1e-9)
        XCTAssertEqual(run.right[1].x, 1050, accuracy: 1e-9)
        XCTAssertEqual(run.right[1].y, -50, accuracy: 1e-9)
        // 終点: 左法線(-1,0)×50
        XCTAssertEqual(run.left[2], Vec2(950, 1000))
        XCTAssertEqual(run.right[2], Vec2(1050, 1000))
        // 端部閉じ線2本、エルボ1箇所=前後2枚の四角形
        XCTAssertEqual(layout.endCaps.count, 2)
        XCTAssertEqual(layout.fittingBoxes.count, 2)
        XCTAssertTrue(layout.fittingBoxes.allSatisfy { $0.count == 4 })
    }

    /// 継手Offなら継手四角形は出ない
    func testDoubleLineNoFittings() {
        let attrs = PipeAttributes(outerDiameter: 100, doubleLine: true, autoFittings: false)
        let layout = PipeGeometry.doubleLineLayout(
            points: v3([Vec2(0, 0), Vec2(1000, 0), Vec2(1000, 1000)]), attrs: attrs)
        XCTAssertTrue(layout?.fittingBoxes.isEmpty ?? false)
    }

    /// 複線+立管: ランごとに外形線、立管の付け根に水平側の受口ボックス
    func testDoubleLineWithRiser() {
        let attrs = PipeAttributes(outerDiameter: 100, annotate: false,
                                   doubleLine: true, autoFittings: true)
        let pts = [Vec3(0, 0, 0), Vec3(1000, 0, 0), Vec3(1000, 0, 2000), Vec3(1000, 800, 2000)]
        guard let layout = PipeGeometry.doubleLineLayout(points: pts, attrs: attrs) else {
            return XCTFail()
        }
        XCTAssertEqual(layout.runs.count, 2)
        XCTAssertEqual(layout.endCaps.count, 4)
        // 立管の根元(ラン1終点)と天端(ラン2始点)に1枚ずつ
        XCTAssertEqual(layout.fittingBoxes.count, 2)
    }

    /// 複線の配管は管の太さの中ならどこでもヒット
    func testDoubleLineHit() {
        let e = Entity(layer: layer,
                       kind: .pipe(points: v3([Vec2(0, 0), Vec2(1000, 0)]),
                                   attrs: PipeAttributes(outerDiameter: 100, annotate: false,
                                                         doubleLine: true)))
        XCTAssertEqual(e.hitDistance(to: Vec2(500, 40)), 0, accuracy: 1e-9)   // 太さの中
        XCTAssertEqual(e.hitDistance(to: Vec2(500, 80)), 30, accuracy: 1e-9)  // 外形から30
        // boundsも外形まで
        XCTAssertGreaterThanOrEqual(e.bounds.maxY, 50 - 1e-9)
    }

    /// 変換: 倍率は延長だけ変わり口径(外径・呼び径)は不変
    func testTransforms() {
        let e = makePipe([Vec2(0, 0), Vec2(1000, 0)])

        let moved = e.translated(by: Vec2(0, 500))
        guard case .pipe(let p1, _) = moved.kind else { return XCTFail() }
        XCTAssertEqual(p1[0], Vec3(0, 500, 0))

        let rotated = e.rotated(around: Vec2(0, 0), byRadians: .pi / 2)
        guard case .pipe(let p2, _) = rotated.kind else { return XCTFail() }
        XCTAssertEqual(p2[1].x, 0, accuracy: 1e-9)
        XCTAssertEqual(p2[1].y, 1000, accuracy: 1e-9)

        let scaled = e.scaled(by: 2, around: Vec2(0, 0))
        guard case .pipe(let p3, let attrs3) = scaled.kind else { return XCTFail() }
        XCTAssertEqual(p3[1], Vec3(2000, 0, 0))
        XCTAssertEqual(attrs3.outerDiameter, 60, accuracy: 1e-9)   // 口径は実物なので不変
        XCTAssertEqual(attrs3.sizeLabel, "50")
        XCTAssertEqual(attrs3.textHeight, 250, accuracy: 1e-9)     // 傍記文字は追随
    }
}
