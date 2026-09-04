import XCTest
@testable import MepCore

/// 移動時の接続追随(伸縮移動)M7.3
final class PipeConnectionTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    private func pipe(_ pts: [Vec3], od: Double = 114, size: String = "100") -> Entity {
        Entity(layer: layer,
               kind: .pipe(points: pts,
                           attrs: PipeAttributes(size: size, sizeLabel: size, outerDiameter: od,
                                                 annotate: false, doubleLine: true)))
    }

    private func points(_ e: Entity) -> [Vec3] {
        guard case .pipe(let pts, _) = e.kind else { return [] }
        return pts
    }

    private func direction(_ pts: [Vec3], _ i: Int, _ j: Int) -> Double {
        let d = pts[j].xy - pts[i].xy
        return atan2(d.y, d.x)
    }

    /// 本管を下へ移動 → 芯線上に乗っている45°の枝管が自分の管軸方向へ伸びて接続を保つ。
    /// 枝管の向き(=継手の角度)は変わらない
    func testBranchStretchesAlongItsAxis() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])
        let branch = pipe([Vec3(0, 0, 0), Vec3(2000, 2000, 0)], od: 89, size: "75")
        let before = points(branch)

        let moved = PipeConnections.followers(movingIDs: [main.id], delta: Vec2(0, -500),
                                              in: [main, branch])
        XCTAssertEqual(moved.count, 1)
        let after = points(moved[0])
        XCTAssertEqual(moved[0].id, branch.id)
        // 端は管軸(45°)上を滑って、移動後の本管の芯線(y=-500)へ
        XCTAssertEqual(after[0].xy.x, -500, accuracy: 1e-6)
        XCTAssertEqual(after[0].xy.y, -500, accuracy: 1e-6)
        XCTAssertEqual(after[1], before[1])                       // 反対の端は動かない
        // 向きは不変(継手の角度が変わらない)
        XCTAssertEqual(direction(after, 0, 1), direction(before, 0, 1), accuracy: 1e-9)
        // 伸びている(短くなっていない)
        XCTAssertGreaterThan(after[0].xy.distance(to: after[1].xy),
                             before[0].xy.distance(to: before[1].xy))
    }

    /// 直角の枝管でも同じ(本管の移動ぶんだけ枝が伸びる)
    func testPerpendicularBranchFollows() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])
        let branch = pipe([Vec3(0, 0, 0), Vec3(0, 2000, 0)], od: 89, size: "75")
        let moved = PipeConnections.followers(movingIDs: [main.id], delta: Vec2(0, -500),
                                              in: [main, branch])
        XCTAssertEqual(moved.count, 1)
        let after = points(moved[0])
        XCTAssertEqual(after[0].xy.x, 0, accuracy: 1e-6)
        XCTAssertEqual(after[0].xy.y, -500, accuracy: 1e-6)
    }

    /// 本管を管軸方向(横)に動かしても、枝は芯線上に乗ったまま(枝は動かない)
    func testMoveAlongMainAxisKeepsBranch() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])
        let branch = pipe([Vec3(0, 0, 0), Vec3(0, 2000, 0)], od: 89, size: "75")
        let moved = PipeConnections.followers(movingIDs: [main.id], delta: Vec2(800, 0),
                                              in: [main, branch])
        // 芯線の位置(y=0)が変わらないので枝は動かす必要がない
        XCTAssertTrue(moved.isEmpty)
    }

    /// 端点どうしの突き合わせは、接続点そのものへ追随する
    func testButtJointFollowsConnectionPoint() {
        let a = pipe([Vec3(0, 0, 0), Vec3(3000, 0, 0)])
        let b = pipe([Vec3(3000, 0, 0), Vec3(6000, 0, 0)])
        let moved = PipeConnections.followers(movingIDs: [a.id], delta: Vec2(0, -500),
                                              in: [a, b])
        XCTAssertEqual(moved.count, 1)
        let after = points(moved[0])
        XCTAssertEqual(after[0].xy, Vec2(3000, -500))
        XCTAssertEqual(after[1].xy, Vec2(6000, 0))    // 反対の端は据え置き
    }

    /// 複数の枝がぶら下がっていれば全部が追随する
    func testMultipleBranchesFollow() {
        let main = pipe([Vec3(-4000, 0, 0), Vec3(4000, 0, 0)])
        let b1 = pipe([Vec3(-1000, 0, 0), Vec3(1000, 2000, 0)], od: 114, size: "100")
        let b2 = pipe([Vec3(1000, 0, 0), Vec3(3000, 2000, 0)], od: 89, size: "75")
        let moved = PipeConnections.followers(movingIDs: [main.id], delta: Vec2(0, -600),
                                              in: [main, b1, b2])
        XCTAssertEqual(Set(moved.map(\.id)), [b1.id, b2.id])
        for e in moved {
            XCTAssertEqual(points(e)[0].xy.y, -600, accuracy: 1e-6)
        }
    }

    /// 一緒に選択して動かす配管は追随の対象にしない(二重に動いてしまう)
    func testMovingTogetherIsNotFollowed() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])
        let branch = pipe([Vec3(0, 0, 0), Vec3(2000, 2000, 0)])
        XCTAssertTrue(PipeConnections.followers(movingIDs: [main.id, branch.id],
                                                delta: Vec2(0, -500),
                                                in: [main, branch]).isEmpty)
    }

    /// 接続していない配管・高さが違う配管は動かさない
    func testUnconnectedPipesUntouched() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])
        let far = pipe([Vec3(0, 5000, 0), Vec3(2000, 7000, 0)])
        let crossing = pipe([Vec3(0, 0, 2000), Vec3(2000, 2000, 2000)])   // 平面上は交わるが高さ違い
        XCTAssertTrue(PipeConnections.followers(movingIDs: [main.id], delta: Vec2(0, -500),
                                                in: [main, far, crossing]).isEmpty)
    }

    /// 移動量ゼロなら何もしない
    func testNoMoveNoFollowers() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])
        let branch = pipe([Vec3(0, 0, 0), Vec3(2000, 2000, 0)])
        XCTAssertTrue(PipeConnections.followers(movingIDs: [main.id], delta: .zero,
                                                in: [main, branch]).isEmpty)
    }

    /// 芯線にきっちりスナップできていない枝(胴の中で止まっている)も追随する。M7.4
    /// 追随後は端が芯線にぴったり乗るので、そこで継手も出るようになる
    func testLooselyAttachedBranchStillFollows() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])          // VP100(外径114)
        // 枝の端が芯線から40mm手前で止まっている(本管の胴の中)
        let branch = pipe([Vec3(40, 40, 0), Vec3(2040, 2040, 0)], od: 89, size: "75")
        let moved = PipeConnections.followers(movingIDs: [main.id], delta: Vec2(0, -500),
                                              in: [main, branch])
        XCTAssertEqual(moved.count, 1)
        let after = points(moved[0])
        // 移動後の芯線(y=-500)にぴったり乗る
        XCTAssertEqual(after[0].xy.y, -500, accuracy: 1e-6)
        XCTAssertEqual(after[0].xy.x, -500, accuracy: 1e-6)   // 45°の軸上を滑る
    }

    /// 胴からも外れている(明らかに繋がっていない)枝は追随しない
    func testClearlyDetachedBranchDoesNotFollow() {
        let main = pipe([Vec3(-3000, 0, 0), Vec3(3000, 0, 0)])
        // 芯線から400mm離れている(本管の外半径57+枝の外半径44.5を大きく超える)
        let branch = pipe([Vec3(400, 400, 0), Vec3(2400, 2400, 0)], od: 89, size: "75")
        XCTAssertTrue(PipeConnections.followers(movingIDs: [main.id], delta: Vec2(0, -500),
                                                in: [main, branch]).isEmpty)
    }

    // MARK: - 伸縮での追随(M7.6)

    /// 本管を「区間伸縮」で下げると、DT(直角)の枝管が伸びて接続を保つ
    func testBranchFollowsSegmentStretch() {
        let main = pipe([Vec3(0, 3000, 0), Vec3(6000, 3000, 0), Vec3(6000, 0, 0)])
        let branch = pipe([Vec3(3000, 3000, 0), Vec3(3000, 6000, 0)], od: 89, size: "75")
        // 上の横走り(区間0)を800下げる
        let after = PipeGeometry.stretchSegment(points: points(main), index: 0, by: Vec2(0, -800))
        let change = PipeConnections.PipeChange(before: points(main), after: after, radius: 57)
        let moved = PipeConnections.followers(changes: [change], movingIDs: [main.id],
                                              in: [main, branch])
        XCTAssertEqual(moved.count, 1)
        let b = points(moved[0])
        XCTAssertEqual(b[0].xy, Vec2(3000, 2200))     // 枝の端が新しい芯線へ
        XCTAssertEqual(b[1].xy, Vec2(3000, 6000))     // 反対の端は動かない
    }

    /// 45°の枝(Y)は自分の管軸上を滑るので角度が変わらない
    func testObliqueBranchKeepsAngleOnStretch() {
        let main = pipe([Vec3(0, 0, 0), Vec3(6000, 0, 0), Vec3(6000, -3000, 0)])
        let branch = pipe([Vec3(3000, 0, 0), Vec3(5000, 2000, 0)], od: 89, size: "75")
        let before = points(branch)
        let after = PipeGeometry.stretchSegment(points: points(main), index: 0, by: Vec2(0, -500))
        let change = PipeConnections.PipeChange(before: points(main), after: after, radius: 57)
        let moved = PipeConnections.followers(changes: [change], movingIDs: [main.id],
                                              in: [main, branch])
        XCTAssertEqual(moved.count, 1)
        let b = points(moved[0])
        XCTAssertEqual(b[0].xy.y, -500, accuracy: 1e-6)
        XCTAssertEqual(b[0].xy.x, 2500, accuracy: 1e-6)         // 45°の軸上を滑る
        XCTAssertEqual(direction(b, 0, 1), direction(before, 0, 1), accuracy: 1e-9)
    }

    /// 頂点の伸縮(掴んだ折れ点を動かす)でも、その区間に付いている枝は追随する
    func testBranchFollowsVertexStretch() {
        let main = pipe([Vec3(0, 0, 0), Vec3(6000, 0, 0), Vec3(6000, 4000, 0)])
        let branch = pipe([Vec3(3000, 0, 0), Vec3(3000, -2000, 0)], od: 89, size: "75")
        // 折れ点を動かすと手前の区間が+yへ平行移動する
        let after = PipeGeometry.stretch(points: points(main), index: 1, to: Vec2(6500, 400))
        let change = PipeConnections.PipeChange(before: points(main), after: after, radius: 57)
        let moved = PipeConnections.followers(changes: [change], movingIDs: [main.id],
                                              in: [main, branch])
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(points(moved[0])[0].xy.y, 400, accuracy: 1e-6)
    }
}
