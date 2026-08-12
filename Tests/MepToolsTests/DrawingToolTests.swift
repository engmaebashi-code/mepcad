import XCTest
@testable import MepTools
@testable import MepCore

/// 作図ツール状態機械のテスト(UI非依存)
final class DrawingToolTests: XCTestCase {

    final class Capture: DrawingToolDelegate {
        var produced: [Entity] = []
        var hints: [String] = []
        var kinds: [ToolKind] = []
        var textToReturn: String? = "テスト"

        func toolDidProduce(_ entity: Entity) { produced.append(entity) }
        func toolRequestsText(at point: Vec2, completion: @escaping (String?) -> Void) {
            completion(textToReturn)
        }
        func toolStatusChanged(_ hint: String) { hints.append(hint) }
        func toolKindChanged(_ kind: ToolKind) { kinds.append(kind) }
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
