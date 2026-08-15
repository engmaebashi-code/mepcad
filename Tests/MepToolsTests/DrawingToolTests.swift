import XCTest
@testable import MepTools
@testable import MepCore

/// 作図ツール状態機械のテスト(UI非依存)
final class DrawingToolTests: XCTestCase {

    final class Capture: DrawingToolDelegate {
        var produced: [Entity] = []
        var groups: [(entities: [Entity], name: String)] = []
        var hints: [String] = []
        var kinds: [ToolKind] = []
        var textToReturn: String? = "テスト"

        func toolDidProduce(_ entity: Entity) { produced.append(entity) }
        func toolDidProduceGroup(_ entities: [Entity], name: String) {
            groups.append((entities, name))
            produced.append(contentsOf: entities)
        }
        func toolRequestsText(at point: Vec2, completion: @escaping (String?) -> Void) {
            completion(textToReturn)
        }
        func toolStatusChanged(_ hint: String) { hints.append(hint) }
        func toolKindChanged(_ kind: ToolKind) { kinds.append(kind) }
        var dimStyle = DimensionToolStyle()
        func toolDimensionStyle() -> DimensionToolStyle { dimStyle }
        var leaderStyle = LeaderToolStyle()
        func toolLeaderStyle() -> LeaderToolStyle { leaderStyle }
        var pipeStyle = PipeToolStyle()
        func toolPipeStyle() -> PipeToolStyle { pipeStyle }
    }

    func makeTool() -> (DrawingToolController, Capture) {
        let capture = Capture()
        let tool = DrawingToolController(currentLayer: .zero)
        tool.delegate = capture
        return (tool, capture)
    }

    func testLineChainDrawing() {
        let (tool, cap) = makeTool()
        tool.select(.line)
        tool.click(at: Vec2(0, 0), shiftDown: false)       // 始点
        tool.click(at: Vec2(1000, 0), shiftDown: false)    // 1本目確定
        tool.click(at: Vec2(1000, 500), shiftDown: false)  // 連続作図2本目
        XCTAssertEqual(cap.produced.count, 2)
        if case .line(let a, let b) = cap.produced[1].kind {
            XCTAssertEqual(a, Vec2(1000, 0))
            XCTAssertEqual(b, Vec2(1000, 500))
        } else {
            XCTFail("線分でない")
        }
    }

    func testNumericDistanceInput() {
        let (tool, cap) = makeTool()
        tool.select(.line)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        _ = tool.preview(cursor: Vec2(200, 0), shiftDown: false)  // カーソルは右方向
        for ch in "1500" { XCTAssertTrue(tool.keyInput(ch)) }
        XCTAssertTrue(tool.keyInput("\r"))
        XCTAssertEqual(cap.produced.count, 1)
        if case .line(let a, let b) = cap.produced[0].kind {
            XCTAssertEqual(a, Vec2(0, 0))
            XCTAssertEqual(b.x, 1500, accuracy: 1e-9)
            XCTAssertEqual(b.y, 0, accuracy: 1e-9)
        } else {
            XCTFail("線分でない")
        }
    }

    func testNumericRelativeInput() {
        let (tool, cap) = makeTool()
        tool.select(.line)
        tool.click(at: Vec2(100, 100), shiftDown: false)
        for ch in "500,-250" { _ = tool.keyInput(ch) }
        _ = tool.keyInput("\r")
        XCTAssertEqual(cap.produced.count, 1)
        if case .line(_, let b) = cap.produced[0].kind {
            XCTAssertEqual(b, Vec2(600, -150))
        } else {
            XCTFail("線分でない")
        }
    }

    func testCircleNumericRadius() {
        let (tool, cap) = makeTool()
        tool.select(.circle)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        for ch in "750" { _ = tool.keyInput(ch) }
        _ = tool.keyInput("\r")
        XCTAssertEqual(cap.produced.count, 1)
        if case .circle(let c, let r) = cap.produced[0].kind {
            XCTAssertEqual(c, Vec2(0, 0))
            XCTAssertEqual(r, 750, accuracy: 1e-9)
        } else {
            XCTFail("円でない")
        }
    }

    func testShiftConstrains45Degrees() {
        let (tool, cap) = makeTool()
        tool.select(.line)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        // ほぼ水平の点を⇧付きでクリック → 完全水平に拘束される
        tool.click(at: Vec2(1000, 30), shiftDown: true)
        XCTAssertEqual(cap.produced.count, 1)
        if case .line(_, let b) = cap.produced[0].kind {
            XCTAssertEqual(b.y, 0, accuracy: 1e-9)
        } else {
            XCTFail("線分でない")
        }
    }

    func testAngleConstraintPalette90() {
        let (tool, cap) = makeTool()
        tool.select(.line)
        tool.angleConstraint = .deg90
        tool.click(at: Vec2(0, 0), shiftDown: false)
        // ⇧なしでも90°拘束(パレット設定が常時有効)
        tool.click(at: Vec2(80, 1000), shiftDown: false)
        XCTAssertEqual(cap.produced.count, 1)
        if case .line(_, let b) = cap.produced[0].kind {
            XCTAssertEqual(b.x, 0, accuracy: 1e-9)  // ほぼ垂直→完全垂直
        } else {
            XCTFail("線分でない")
        }
    }

    func testNumericDistanceRespectsAngleConstraint() {
        let (tool, cap) = makeTool()
        tool.select(.line)
        tool.angleConstraint = .deg90
        tool.click(at: Vec2(0, 0), shiftDown: false)
        // カーソルはほぼ垂直(少し右に流れている)→ 拘束後は完全垂直
        _ = tool.preview(cursor: Vec2(80, 1000), shiftDown: false)
        for ch in "2000" { _ = tool.keyInput(ch) }
        _ = tool.keyInput("\r")
        XCTAssertEqual(cap.produced.count, 1)
        if case .line(_, let b) = cap.produced[0].kind {
            XCTAssertEqual(b.x, 0, accuracy: 1e-9)      // 生カーソル方向でなく拘束方向
            XCTAssertEqual(b.y, 2000, accuracy: 1e-9)
        } else {
            XCTFail("線分でない")
        }
    }

    func testTextPlacement() {
        let (tool, cap) = makeTool()
        tool.select(.text)
        tool.click(at: Vec2(500, 500), shiftDown: false)
        XCTAssertEqual(cap.produced.count, 1)
        if case .text(let pos, let content, _, _) = cap.produced[0].kind {
            XCTAssertEqual(pos, Vec2(500, 500))
            XCTAssertEqual(content, "テスト")
        } else {
            XCTFail("文字でない")
        }
    }

    // MARK: - M4.5: 矩形・円弧・点・2線・中心線

    func testRectProducesFourLinesAsGroup() {
        let (tool, cap) = makeTool()
        tool.select(.rect)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 500), shiftDown: false)
        XCTAssertEqual(cap.groups.count, 1)
        XCTAssertEqual(cap.groups[0].name, "矩形")
        XCTAssertEqual(cap.groups[0].entities.count, 4)
        // 4隅が正しい(周長で確認)
        let total = cap.groups[0].entities.reduce(0.0) { sum, e in
            if case .line(let a, let b) = e.kind { return sum + a.distance(to: b) }
            return sum
        }
        XCTAssertEqual(total, 3000, accuracy: 1e-9)
    }

    func testRectNumericWH() {
        let (tool, cap) = makeTool()
        tool.select(.rect)
        tool.click(at: Vec2(100, 100), shiftDown: false)
        for ch in "600,300" { _ = tool.keyInput(ch) }
        _ = tool.keyInput("\r")
        XCTAssertEqual(cap.groups.count, 1)
        var maxX = -Double.infinity, maxY = -Double.infinity
        for e in cap.groups[0].entities {
            if case .line(let a, let b) = e.kind {
                maxX = max(maxX, a.x, b.x); maxY = max(maxY, a.y, b.y)
            }
        }
        XCTAssertEqual(maxX, 700, accuracy: 1e-9)
        XCTAssertEqual(maxY, 400, accuracy: 1e-9)
    }

    func testArcCenterStartEnd() {
        let (tool, cap) = makeTool()
        tool.select(.arc)
        tool.click(at: Vec2(0, 0), shiftDown: false)      // 中心
        tool.click(at: Vec2(100, 0), shiftDown: false)    // 始点(半径100, 0°)
        tool.click(at: Vec2(0, 50), shiftDown: false)     // 終点方向(90°)
        XCTAssertEqual(cap.produced.count, 1)
        if case .arc(let c, let r, let a1, let a2) = cap.produced[0].kind {
            XCTAssertEqual(c, Vec2(0, 0))
            XCTAssertEqual(r, 100, accuracy: 1e-9)
            XCTAssertEqual(a1, 0, accuracy: 1e-9)
            XCTAssertEqual(a2, .pi / 2, accuracy: 1e-9)
        } else {
            XCTFail("円弧でない")
        }
    }

    func testPointPlacement() {
        let (tool, cap) = makeTool()
        tool.select(.point)
        tool.click(at: Vec2(300, 400), shiftDown: false)
        XCTAssertEqual(cap.produced.count, 1)
        if case .point(let p) = cap.produced[0].kind {
            XCTAssertEqual(p, Vec2(300, 400))
        } else {
            XCTFail("点でない")
        }
    }

    func testDoubleLineHalfSplitWidth() {
        let (tool, cap) = makeTool()
        tool.select(.doubleLine)
        // 単独数値=振分半々(全幅150 → 各75)
        for ch in "150" { XCTAssertTrue(tool.keyInput(ch)) }
        _ = tool.keyInput("\r")
        XCTAssertEqual(tool.doubleLineOffsetA, 75, accuracy: 1e-9)
        XCTAssertEqual(tool.doubleLineOffsetB, 75, accuracy: 1e-9)

        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 0), shiftDown: false)
        XCTAssertEqual(cap.groups.count, 1)
        XCTAssertEqual(cap.groups[0].name, "2線")
        let lines = cap.groups[0].entities
        XCTAssertEqual(lines.count, 2)
        guard case .line(let a1, _) = lines[0].kind,
              case .line(let a2, _) = lines[1].kind else { return XCTFail() }
        XCTAssertEqual(abs(a1.y - a2.y), 150, accuracy: 1e-9)
        XCTAssertEqual(a1.y + a2.y, 0, accuracy: 1e-9)
        // 連続作図: 次の始点は基準線の終点
        tool.click(at: Vec2(1000, 800), shiftDown: false)
        XCTAssertEqual(cap.groups.count, 2)
    }

    func testDoubleLineAsymmetricOffsets() {
        let (tool, cap) = makeTool()
        tool.select(.doubleLine)
        // `a,b⏎` = A側100 / B側50
        for ch in "100,50" { XCTAssertTrue(tool.keyInput(ch)) }
        _ = tool.keyInput("\r")
        XCTAssertEqual(tool.doubleLineOffsetA, 100, accuracy: 1e-9)
        XCTAssertEqual(tool.doubleLineOffsetB, 50, accuracy: 1e-9)

        // +X方向の基準線 → A側=左(+y)に100 / B側=右(-y)に50
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 0), shiftDown: false)
        let lines = cap.groups[0].entities
        guard case .line(let a1, _) = lines[0].kind,
              case .line(let a2, _) = lines[1].kind else { return XCTFail() }
        XCTAssertEqual(a1.y, 100, accuracy: 1e-9)
        XCTAssertEqual(a2.y, -50, accuracy: 1e-9)
    }

    func testRectSizeFirstPlacement() {
        let (tool, cap) = makeTool()
        tool.select(.rect)
        // 寸法先行指定: 900×600 → クリック位置を中心に配置(連続配置可)
        for ch in "900,600" { XCTAssertTrue(tool.keyInput(ch)) }
        _ = tool.keyInput("\r")
        XCTAssertEqual(tool.pendingRectSize, Vec2(900, 600))

        tool.click(at: Vec2(1000, 1000), shiftDown: false)
        XCTAssertEqual(cap.groups.count, 1)
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for e in cap.groups[0].entities {
            if case .line(let a, let b) = e.kind {
                minX = min(minX, a.x, b.x); maxX = max(maxX, a.x, b.x)
                minY = min(minY, a.y, b.y); maxY = max(maxY, a.y, b.y)
            }
        }
        XCTAssertEqual(minX, 550, accuracy: 1e-9)   // 1000 - 450
        XCTAssertEqual(maxX, 1450, accuracy: 1e-9)
        XCTAssertEqual(minY, 700, accuracy: 1e-9)   // 1000 - 300
        XCTAssertEqual(maxY, 1300, accuracy: 1e-9)

        // 連続配置できる
        tool.click(at: Vec2(3000, 1000), shiftDown: false)
        XCTAssertEqual(cap.groups.count, 2)
        // escで解除
        tool.cancel()
        XCTAssertNil(tool.pendingRectSize)
    }

    func testCenterlineUsesChainLineType() {
        let (tool, cap) = makeTool()
        tool.select(.centerline)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(2000, 0), shiftDown: false)
        XCTAssertEqual(cap.produced.count, 1)
        XCTAssertEqual(cap.produced[0].style.lineType, 4)  // 一点鎖1
    }

    /// 文字パレットのサイズ・角度が配置に反映される(M5.3)
    func testTextHeightAndAngleApplied() {
        let (tool, cap) = makeTool()
        tool.textHeight = 175          // 紙面3.5mm×1/50
        tool.textAngleDegrees = 90
        tool.select(.text)
        tool.click(at: Vec2(100, 200), shiftDown: false)   // スタブが「テスト」を返す
        XCTAssertEqual(cap.produced.count, 1)
        guard case .text(let p, let content, let h, let angle) = cap.produced[0].kind else {
            return XCTFail()
        }
        XCTAssertEqual(p, Vec2(100, 200))
        XCTAssertEqual(content, "テスト")
        XCTAssertEqual(h, 175, accuracy: 1e-9)
        XCTAssertEqual(angle, .pi / 2, accuracy: 1e-9)
    }

    // MARK: - ハッチング(M5.2)

    func testHatchPolygonClickAndEnterCommit() {
        let (tool, cap) = makeTool()
        tool.select(.hatch)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 800), shiftDown: false)
        XCTAssertTrue(cap.produced.isEmpty)
        XCTAssertTrue(tool.keyInput("\r"))                 // ⏎で閉じて確定
        XCTAssertEqual(cap.produced.count, 1)
        guard case .hatch(let boundary, let pattern) = cap.produced[0].kind else { return XCTFail() }
        XCTAssertEqual(boundary.count, 3)
        XCTAssertEqual(pattern.kind, .horizontal)          // デリゲート既定実装の値
        XCTAssertTrue(tool.hatchPoints.isEmpty)            // 次の領域へ
        XCTAssertEqual(tool.kind, .hatch)
    }

    func testHatchCloseByClickingStart() {
        let (tool, cap) = makeTool()
        tool.select(.hatch)
        tool.closeTolerance = 50
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 800), shiftDown: false)
        tool.click(at: Vec2(10, 10), shiftDown: false)     // 始点近く→閉じて確定
        XCTAssertEqual(cap.produced.count, 1)
        guard case .hatch(let boundary, _) = cap.produced[0].kind else { return XCTFail() }
        XCTAssertEqual(boundary.count, 3)
    }

    func testHatchEscCancels() {
        let (tool, cap) = makeTool()
        tool.select(.hatch)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(100, 0), shiftDown: false)
        tool.cancel()
        XCTAssertTrue(tool.hatchPoints.isEmpty)
        XCTAssertTrue(cap.produced.isEmpty)
        XCTAssertEqual(tool.kind, .hatch)                  // 1回目のescは中止のみ
    }

    // MARK: - 寸法(M5.4)

    func testDimensionThreeClicksProduce() {
        let (tool, cap) = makeTool()
        cap.dimStyle = DimensionToolStyle(
            axis: .horizontal,
            attrs: DimAttributes(terminator: .arrow, textHeight: 175, extensionLength: nil),
            colorIndex: 2)
        tool.select(.dimension)
        tool.click(at: Vec2(0, 0), shiftDown: false)        // 測定点1
        tool.click(at: Vec2(1000, 300), shiftDown: false)   // 測定点2
        XCTAssertTrue(cap.produced.isEmpty)                 // まだ確定しない
        tool.click(at: Vec2(500, 800), shiftDown: false)    // 寸法線位置
        XCTAssertEqual(cap.produced.count, 1)
        guard case .dimension(let a, let b, let lp, let angle, let attrs) = cap.produced[0].kind else {
            return XCTFail("寸法でない")
        }
        XCTAssertEqual(a, Vec2(0, 0))
        XCTAssertEqual(b, Vec2(1000, 300))
        XCTAssertEqual(lp, Vec2(500, 800))
        XCTAssertEqual(angle, 0, accuracy: 1e-9)
        XCTAssertEqual(attrs.terminator, .arrow)
        XCTAssertEqual(attrs.textHeight, 175, accuracy: 1e-9)
        XCTAssertEqual(cap.produced[0].style.colorIndex, 2)
        // 確定後は次の寸法の待機状態(連続記入)
        XCTAssertNil(tool.dimA)
        XCTAssertNil(tool.dimB)
        XCTAssertEqual(tool.kind, .dimension)
    }

    func testDimensionAlignedAngle() {
        let (tool, cap) = makeTool()
        cap.dimStyle.axis = .aligned
        tool.select(.dimension)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(300, 400), shiftDown: false)
        tool.click(at: Vec2(0, 1000), shiftDown: false)
        XCTAssertEqual(cap.produced.count, 1)
        guard case .dimension(_, _, _, let angle, _) = cap.produced[0].kind else {
            return XCTFail("寸法でない")
        }
        XCTAssertEqual(angle, atan2(400.0, 300.0), accuracy: 1e-9)
        let layout = DimensionGeometry.layout(of: cap.produced[0])!
        XCTAssertEqual(layout.value, 500, accuracy: 1e-9)
    }

    func testDimensionDegenerateSpanNotProduced() {
        let (tool, cap) = makeTool()
        cap.dimStyle.axis = .vertical
        tool.select(.dimension)
        tool.click(at: Vec2(0, 100), shiftDown: false)
        tool.click(at: Vec2(1000, 100), shiftDown: false)   // 垂直方向の差0
        tool.click(at: Vec2(500, 800), shiftDown: false)
        XCTAssertTrue(cap.produced.isEmpty)                 // 長さ0の寸法は作らない
    }

    func testDimensionEscCancels() {
        let (tool, cap) = makeTool()
        tool.select(.dimension)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 0), shiftDown: false)
        tool.cancel()
        XCTAssertNil(tool.dimA)
        XCTAssertNil(tool.dimB)
        XCTAssertTrue(cap.produced.isEmpty)
        XCTAssertEqual(tool.kind, .dimension)
    }

    // MARK: - 引出線(M5.5)

    func testLeaderTwoClicksOpensTextAndProduces() {
        let (tool, cap) = makeTool()
        cap.leaderStyle = LeaderToolStyle(
            attrs: LeaderAttributes(balloon: true, doubleFrame: false, arrow: true,
                                    textHeight: 175, aspectPercent: 80),
            colorIndex: 4)
        cap.textToReturn = "PAC-1"
        tool.select(.leader)
        tool.click(at: Vec2(0, 0), shiftDown: false)        // 指示点
        XCTAssertTrue(cap.produced.isEmpty)
        tool.click(at: Vec2(1000, 800), shiftDown: false)   // 文字位置 → 入力 → 確定
        XCTAssertEqual(cap.produced.count, 1)
        guard case .leader(let tip, let elbow, let content, let attrs) = cap.produced[0].kind else {
            return XCTFail("引出線でない")
        }
        XCTAssertEqual(tip, Vec2(0, 0))
        XCTAssertEqual(elbow, Vec2(1000, 800))
        XCTAssertEqual(content, "PAC-1")
        XCTAssertTrue(attrs.balloon)
        XCTAssertEqual(cap.produced[0].style.colorIndex, 4)
        // 確定後は次の引出線の待機状態(連続記入)
        XCTAssertNil(tool.leaderTip)
        XCTAssertEqual(tool.kind, .leader)
    }

    func testLeaderCancelledTextProducesNothing() {
        let (tool, cap) = makeTool()
        cap.textToReturn = nil                              // 入力をesc
        tool.select(.leader)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 800), shiftDown: false)
        XCTAssertTrue(cap.produced.isEmpty)
        XCTAssertNil(tool.leaderTip)
    }

    func testLeaderEscCancels() {
        let (tool, cap) = makeTool()
        tool.select(.leader)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.cancel()
        XCTAssertNil(tool.leaderTip)
        XCTAssertTrue(cap.produced.isEmpty)
        XCTAssertEqual(tool.kind, .leader)
    }

    // MARK: - 配管(M6.0)

    func testPipeRouteClicksAndEnterCommit() {
        let (tool, cap) = makeTool()
        cap.pipeStyle = PipeToolStyle(
            attrs: PipeAttributes(usage: "CW", usageName: "給水",
                                  material: "HIVP", materialLabel: "HIVP",
                                  size: "20", sizeLabel: "20", outerDiameter: 26,
                                  annotate: true, textHeight: 125),
            style: Style(colorIndex: 2, lineType: 0))
        tool.select(.pipe)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(2000, 0), shiftDown: false)
        tool.click(at: Vec2(2000, 1500), shiftDown: false)
        XCTAssertTrue(cap.produced.isEmpty)              // ⏎までは確定しない
        XCTAssertTrue(tool.keyInput("\r"))
        XCTAssertEqual(cap.produced.count, 1)
        guard case .pipe(let points, let attrs) = cap.produced[0].kind else {
            return XCTFail("配管でない")
        }
        XCTAssertEqual(points, [Vec3(0, 0, 0), Vec3(2000, 0, 0), Vec3(2000, 1500, 0)])
        XCTAssertEqual(attrs.usageName, "給水")
        XCTAssertEqual(cap.produced[0].style.colorIndex, 2)
        // 確定後は次のルートの待機状態(連続作図)
        XCTAssertTrue(tool.pipePoints.isEmpty)
        XCTAssertEqual(tool.kind, .pipe)
    }

    func testPipeEscCommitsPartialRoute() {
        let (tool, cap) = makeTool()
        tool.select(.pipe)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(1000, 0), shiftDown: false)
        tool.cancel()                                    // 途中キャンセル=そこまで確定
        XCTAssertEqual(cap.produced.count, 1)
        XCTAssertTrue(tool.pipePoints.isEmpty)
        XCTAssertEqual(tool.kind, .pipe)
    }

    func testPipeSinglePointCancelProducesNothing() {
        let (tool, cap) = makeTool()
        tool.select(.pipe)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.cancel()                                    // 1点だけなら何も作らない
        XCTAssertTrue(cap.produced.isEmpty)
    }

    func testPipeNumericInputAddsVertex() {
        let (tool, cap) = makeTool()
        tool.select(.pipe)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        _ = tool.preview(cursor: Vec2(500, 0), shiftDown: false)   // カーソルは右方向
        for ch in "3000" { XCTAssertTrue(tool.keyInput(ch)) }
        XCTAssertTrue(tool.keyInput("\r"))
        XCTAssertEqual(tool.pipePoints.count, 2)
        XCTAssertEqual(tool.pipePoints[1].x, 3000, accuracy: 1e-9)
        XCTAssertTrue(cap.produced.isEmpty)              // 頂点追加であって確定ではない
        XCTAssertTrue(tool.keyInput("\r"))              // 空⏎で確定
        XCTAssertEqual(cap.produced.count, 1)
    }

    /// 作図中に高さを変えると、その位置で立管(平面同一点・z違い)が挟まる(M6.2)
    func testPipeHeightChangeInsertsRiser() {
        let (tool, cap) = makeTool()
        cap.pipeStyle.z = 0
        tool.select(.pipe)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.click(at: Vec2(2000, 0), shiftDown: false)
        cap.pipeStyle.z = 3000                           // カードで高さを変更
        tool.click(at: Vec2(2000, 1500), shiftDown: false)
        XCTAssertTrue(tool.keyInput("\r"))
        guard case .pipe(let points, _) = cap.produced[0].kind else { return XCTFail() }
        XCTAssertEqual(points, [Vec3(0, 0, 0), Vec3(2000, 0, 0),
                                Vec3(2000, 0, 3000), Vec3(2000, 1500, 3000)])
        XCTAssertEqual(PipeGeometry.risers(points: points).count, 1)
    }

    func testEscEndsChainThenReturnsToSelect() {
        let (tool, cap) = makeTool()
        tool.select(.line)
        tool.click(at: Vec2(0, 0), shiftDown: false)
        tool.cancel()  // 作図中→連続作図の終了
        XCTAssertEqual(tool.kind, .line)
        tool.cancel()  // 待機中→選択へ
        XCTAssertEqual(tool.kind, .select)
        XCTAssertTrue(cap.produced.isEmpty)
    }
}
