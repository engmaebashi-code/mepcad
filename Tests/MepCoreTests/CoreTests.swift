import XCTest
@testable import MepCore

final class CoreTests: XCTestCase {

    func testBBoxUnion() {
        var box = BBox.empty
        XCTAssertTrue(box.isEmpty)
        box.union(point: Vec2(10, 20))
        box.union(point: Vec2(-5, 40))
        XCTAssertFalse(box.isEmpty)
        XCTAssertEqual(box.minX, -5)
        XCTAssertEqual(box.maxY, 40)
        XCTAssertEqual(box.width, 15)
    }

    func testEntityBoundsAndSnapPoints() {
        let layerID = LayerID()
        let line = Entity(layerID: layerID, kind: .line(a: Vec2(0, 0), b: Vec2(100, 0)))
        XCTAssertEqual(line.bounds.width, 100)
        XCTAssertEqual(line.snapPoints.count, 3)  // 両端+中点
        XCTAssertTrue(line.snapPoints.contains(Vec2(50, 0)))
    }

    func testUndoRedo() {
        let document = Document()
        let stack = CommandStack(document: document)
        let before = document.entities.count
        let entity = Entity(layerID: document.currentLayerID,
                            kind: .line(a: Vec2(0, 0), b: Vec2(1000, 1000)))
        stack.run(AddEntityCommand(entity: entity))
        XCTAssertEqual(document.entities.count, before + 1)
        stack.undo()
        XCTAssertEqual(document.entities.count, before)
        stack.redo()
        XCTAssertEqual(document.entities.count, before + 1)
        XCTAssertNotNil(document.entity(id: entity.id))
    }

    func testCommandGroupUndoesAsOne() {
        let document = Document()
        let stack = CommandStack(document: document)
        let before = document.entities.count
        let e1 = Entity(layerID: document.currentLayerID, kind: .line(a: .zero, b: Vec2(1, 1)))
        let e2 = Entity(layerID: document.currentLayerID, kind: .circle(center: .zero, radius: 5))
        stack.run(CommandGroup(name: "テスト複合", commands: [
            AddEntityCommand(entity: e1),
            AddEntityCommand(entity: e2),
        ]))
        XCTAssertEqual(document.entities.count, before + 2)
        stack.undo()
        XCTAssertEqual(document.entities.count, before)
    }
}
