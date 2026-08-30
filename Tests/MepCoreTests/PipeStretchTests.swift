import XCTest
@testable import MepCore

/// 配管の伸縮(継手の角度を保つ頂点移動)M7.1
final class PipeStretchTests: XCTestCase {

    /// 全区間の方向(平面)を返す — 伸縮しても変わってはいけない値
    private func directions(_ points: [Vec3]) -> [Double] {
        var out: [Double] = []
        for i in 0..<(points.count - 1) {
            let d = points[i + 1].xy - points[i].xy
            guard d.length > 1e-9 else { continue }
            out.append(atan2(d.y, d.x))
        }
        return out
    }

    private func assertSameDirections(_ a: [Vec3], _ b: [Vec3],
                                      file: StaticString = #filePath, line: UInt = #line) {
        let da = directions(a), db = directions(b)
        XCTAssertEqual(da.count, db.count, file: file, line: line)
        for (x, y) in zip(da, db) {
            XCTAssertEqual(x, y, accuracy: 1e-9, "区間の方向が変わった", file: file, line: line)
        }
    }

    /// L字(90°)の端点を掴むと、その区間の方向へ伸縮するだけ — 折れ角は90°のまま
    func testEndVertexSlidesAlongItsSegment() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 4000, 0)]
        // 終点を斜め上へ引っ張る(x方向にもずらす)
        let out = PipeGeometry.stretch(points: pts, index: 2, to: Vec2(3600, 5000))
        XCTAssertEqual(out[0], pts[0])            // 他の頂点は動かない
        XCTAssertEqual(out[1], pts[1])
        XCTAssertEqual(out[2].x, 3000, accuracy: 1e-9)   // 区間方向(+y)にだけ動く
        XCTAssertEqual(out[2].y, 5000, accuracy: 1e-9)
        assertSameDirections(pts, out)
        // 折れ点は90°エルボのまま
        XCTAssertEqual(PipeGeometry.fittings(points: out).first?.kind, .elbow90)
    }

    /// 始点側も同じ(区間方向へ伸縮)
    func testStartVertexSlidesAlongItsSegment() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 4000, 0)]
        let out = PipeGeometry.stretch(points: pts, index: 0, to: Vec2(-500, 800))
        XCTAssertEqual(out[0].x, -500, accuracy: 1e-9)
        XCTAssertEqual(out[0].y, 0, accuracy: 1e-9)
        XCTAssertEqual(out[1], pts[1])
        assertSameDirections(pts, out)
    }

    /// 折れ点(90°)を掴むとカーソルに追随し、両脚が伸縮して角度は保たれる
    func testCornerFollowsCursorAndKeepsAngles() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 4000, 0)]
        let target = Vec2(3500, 600)
        let out = PipeGeometry.stretch(points: pts, index: 1, to: target)
        // 掴んだ頂点はカーソル位置へ(90°なのでu,vが平面を張る)
        XCTAssertEqual(out[1].xy.x, target.x, accuracy: 1e-6)
        XCTAssertEqual(out[1].xy.y, target.y, accuracy: 1e-6)
        assertSameDirections(pts, out)
        XCTAssertEqual(PipeGeometry.fittings(points: out).first?.kind, .elbow90)
        // 手前側は v(+y)方向へ、先側は u(+x)方向へ平行移動している
        XCTAssertEqual(out[0].xy.x, 0, accuracy: 1e-6)
        XCTAssertEqual(out[0].xy.y, 600, accuracy: 1e-6)
        XCTAssertEqual(out[2].xy.x, 3500, accuracy: 1e-6)
        XCTAssertEqual(out[2].xy.y, 4000, accuracy: 1e-6)
    }

    /// 45°の折れ点でも角度は保たれる(45°エルボのまま)
    func test45CornerKeepsAngle() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(5000, 2000, 0)]
        XCTAssertEqual(PipeGeometry.fittings(points: pts).first?.kind, .elbow45)
        let out = PipeGeometry.stretch(points: pts, index: 1, to: Vec2(2600, 400))
        assertSameDirections(pts, out)
        XCTAssertEqual(PipeGeometry.fittings(points: out).first?.kind, .elbow45)
    }

    /// 4点(90°が2つ)でも全部の角度が保たれ、掴んだ頂点の先だけ平行移動する
    func testMultipleCornersAllPreserved() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 3000, 0), Vec3(6000, 3000, 0)]
        let out = PipeGeometry.stretch(points: pts, index: 1, to: Vec2(3400, 500))
        assertSameDirections(pts, out)
        let kinds = PipeGeometry.fittings(points: out).map(\.kind)
        XCTAssertEqual(kinds, [.elbow90, .elbow90])
        // 先側(index2,3)は u=+x 方向にだけ動く
        XCTAssertEqual(out[2].xy.x - pts[2].xy.x, 400, accuracy: 1e-6)
        XCTAssertEqual(out[2].xy.y, pts[2].xy.y, accuracy: 1e-6)
        XCTAssertEqual(out[3].xy.x - pts[3].xy.x, 400, accuracy: 1e-6)
    }

    /// 立管(平面上で同じ位置の連続頂点)はまとめて動き、高さは変わらない
    func testRiserVerticesMoveTogether() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 0, 2500), Vec3(3000, 3000, 2500)]
        let out = PipeGeometry.stretch(points: pts, index: 1, to: Vec2(3400, 500))
        XCTAssertEqual(out[1].xy, out[2].xy)          // 立管の上下端は同じ平面位置のまま
        XCTAssertEqual(out[1].z, 0)
        XCTAssertEqual(out[2].z, 2500)                 // 高さは維持
        assertSameDirections(pts, out)
    }

    /// 脚が潰れない(残り長さが最小値で止まる)
    func testLegDoesNotCollapse() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 4000, 0)]
        // 手前の脚(長さ3000)を大きく縮める方向へ引っ張る
        let out = PipeGeometry.stretch(points: pts, index: 1, to: Vec2(-5000, 0), minLeg: 1)
        let leg1 = out[0].xy.distance(to: out[1].xy)
        XCTAssertEqual(leg1, 1, accuracy: 1e-6)
        assertSameDirections(pts, out)
    }

    /// 直進の頂点(角がない)は区間方向への伸縮に落とす
    func testStraightVertexFallsBackToSlide() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(6000, 0, 0)]
        let out = PipeGeometry.stretch(points: pts, index: 1, to: Vec2(3500, 900))
        XCTAssertEqual(out[1].xy.y, 0, accuracy: 1e-9)   // 横にはずれない
        XCTAssertEqual(out[1].xy.x, 3500, accuracy: 1e-9)
        assertSameDirections(pts, out)
    }

    // MARK: - 区間の伸縮(M7.5)

    /// Z形: 上の横走りを下げると、縦の区間が縮んで吸収し、下の横走りは1mmも動かない
    func testSegmentStretchAbsorbedByNeighbour() {
        let pts = [Vec3(0, 3000, 0), Vec3(6000, 3000, 0), Vec3(6000, 0, 0), Vec3(12000, 0, 0)]
        let out = PipeGeometry.stretchSegment(points: pts, index: 0, by: Vec2(0, -800))
        // 掴んだ区間は800下がる
        XCTAssertEqual(out[0].xy, Vec2(0, 2200))
        XCTAssertEqual(out[1].xy, Vec2(6000, 2200))
        // 下の横走りは動かない
        XCTAssertEqual(out[2], pts[2])
        XCTAssertEqual(out[3], pts[3])
        // 縦の区間が3000→2200に縮む(方向は不変)
        XCTAssertEqual(out[1].xy.distance(to: out[2].xy), 2200, accuracy: 1e-6)
        assertSameDirections(pts, out)
        XCTAssertEqual(PipeGeometry.fittings(points: out).map(\.kind), [.elbow90, .elbow90])
    }

    /// 中央の縦区間を横へ動かすと、上下の横走りが伸縮して両端は動かない
    func testMiddleSegmentSlidesAndNeighboursAdjust() {
        let pts = [Vec3(0, 3000, 0), Vec3(6000, 3000, 0), Vec3(6000, 0, 0), Vec3(12000, 0, 0)]
        let out = PipeGeometry.stretchSegment(points: pts, index: 1, by: Vec2(500, 0))
        XCTAssertEqual(out[0], pts[0])                    // 両端は据え置き
        XCTAssertEqual(out[3], pts[3])
        XCTAssertEqual(out[1].xy, Vec2(6500, 3000))       // 縦区間が500右へ
        XCTAssertEqual(out[2].xy, Vec2(6500, 0))
        assertSameDirections(pts, out)
    }

    /// 区間の軸方向へ動かしても形は変わらない(直線を自分の上で滑らせても同じ直線)
    func testSegmentMoveAlongItsAxisDoesNothing() {
        let pts = [Vec3(0, 3000, 0), Vec3(6000, 3000, 0), Vec3(6000, 0, 0)]
        let out = PipeGeometry.stretchSegment(points: pts, index: 0, by: Vec2(700, 0))
        XCTAssertEqual(out[1], pts[1])                    // 折れ点は動かない
        XCTAssertEqual(out[2], pts[2])
        XCTAssertEqual(out[0].xy, Vec2(700, 3000))        // 自由端だけが軸上を動く
        assertSameDirections(pts, out)
    }

    /// 隣の区間が潰れる手前で止まる
    func testSegmentStretchStopsBeforeCollapse() {
        let pts = [Vec3(0, 3000, 0), Vec3(6000, 3000, 0), Vec3(6000, 0, 0), Vec3(12000, 0, 0)]
        let out = PipeGeometry.stretchSegment(points: pts, index: 0, by: Vec2(0, -5000), minLeg: 1)
        XCTAssertEqual(out[1].xy.distance(to: out[2].xy), 1, accuracy: 1e-6)
        XCTAssertEqual(out[2], pts[2])
        assertSameDirections(pts, out)
    }

    /// 立管(平面上は点)の区間には伸縮グリップを作らない = 何も起きない
    func testRiserSegmentIsNotStretched() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 0, 2500)]
        XCTAssertEqual(PipeGeometry.stretchSegment(points: pts, index: 1, by: Vec2(0, 500)), pts)
    }
}
