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
}
