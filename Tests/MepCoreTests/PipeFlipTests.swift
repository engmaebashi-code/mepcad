import XCTest
@testable import MepCore

/// 継手反転(M7.8)
final class PipeFlipTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    private func dv100() -> PipeFittingDims {
        PipeFittingDims(elbow90A: 112, elbow45A: 67, teeA: 113, socketDepth: 50,
                        socketOD: 124, capLength: 58, elbow90LLA: 178, y45A: 193)
    }

    private func pipe(_ pts: [Vec3], od: Double = 114, branchKind: String = "DT") -> Entity {
        Entity(layer: layer,
               kind: .pipe(points: pts,
                           attrs: PipeAttributes(size: "100", sizeLabel: "100", outerDiameter: od,
                                                 annotate: false, doubleLine: true,
                                                 fittingSeries: "DV", fittingDims: dv100(),
                                                 branchKind: branchKind)))
    }

    private func points(_ e: Entity) -> [Vec3] {
        guard case .pipe(let pts, _) = e.kind else { return [] }
        return pts
    }

    private func attrs(_ e: Entity) -> PipeAttributes? {
        guard case .pipe(_, let a) = e.kind else { return nil }
        return a
    }

    /// 45°の枝(下流側へ傾いて付いている)を反転 → 反対の端(器具側)は動かず、
    /// 接続点が本管上を滑って傾きが逆(上流側)になる。長さは変わらない
    func testObliqueBranchMirrorsAboutFarEnd() {
        let main = pipe([Vec3(0, 0, 0), Vec3(10000, 0, 0)])
        // 本管は+xが下流。枝は接続点(3000,0)から+x側(下流側)へ傾いて伸びている=流れと逆向きのY
        let branch = pipe([Vec3(3000, 0, 0), Vec3(4000, 1000, 0)], od: 89)
        guard let r = PipeFlip.flip(branch, in: [main, branch]) else { return XCTFail() }
        XCTAssertEqual(r.outcome, .mirroredBranch(aboutFarEnd: true))
        let p = points(r.entity)
        XCTAssertEqual(p[1], Vec3(4000, 1000, 0))                 // 器具側の端は据え置き
        XCTAssertEqual(p[0].xy.x, 5000, accuracy: 1e-6)           // 接続点は本管上を滑る
        XCTAssertEqual(p[0].xy.y, 0, accuracy: 1e-6)
        XCTAssertEqual(p[0].xy.distance(to: p[1].xy), 1000 * 2.0.squareRoot(), accuracy: 1e-6)
        // 反転後は本管側にY(斜め)のティーズが同じ本管に出る(接続が保たれている)
        let js = PipeNetwork.junctions(in: [main, r.entity])
        XCTAssertEqual(js[main.id]?.count, 1)
    }

    /// 接続点が本管の区間から外れてしまう場合は接続点を軸に鏡映(反対の端が動く)
    func testObliqueBranchFallsBackToJunctionPivot() {
        let main = pipe([Vec3(0, 0, 0), Vec3(4000, 0, 0)])
        // 器具側を軸にすると接続点が(5000,0)→本管の外に出る
        let branch = pipe([Vec3(3000, 0, 0), Vec3(4000, 1000, 0)], od: 89)
        guard let r = PipeFlip.flip(branch, in: [main, branch]) else { return XCTFail() }
        XCTAssertEqual(r.outcome, .mirroredBranch(aboutFarEnd: false))
        let p = points(r.entity)
        XCTAssertEqual(p[0], Vec3(3000, 0, 0))                    // 接続点は据え置き
        XCTAssertEqual(p[1].xy.x, 2000, accuracy: 1e-6)           // 傾きが逆(上流側)に
        XCTAssertEqual(p[1].xy.y, 1000, accuracy: 1e-6)
    }

    /// 枝が終点側で本管に付いていても同じ(点の並びは維持)
    func testObliqueBranchAttachedAtEnd() {
        let main = pipe([Vec3(0, 0, 0), Vec3(10000, 0, 0)])
        let branch = pipe([Vec3(4000, 1000, 0), Vec3(3000, 0, 0)], od: 89)
        guard let r = PipeFlip.flip(branch, in: [main, branch]) else { return XCTFail() }
        XCTAssertEqual(r.outcome, .mirroredBranch(aboutFarEnd: true))
        let p = points(r.entity)
        XCTAssertEqual(p[0], Vec3(4000, 1000, 0))
        XCTAssertEqual(p[1].xy.x, 5000, accuracy: 1e-6)
        XCTAssertEqual(p[1].xy.y, 0, accuracy: 1e-6)
    }

    /// 直角の枝(DT/LT)は印を切り替える → 本管側ティーズの mainDirection が逆向きになる
    func testPerpendicularBranchTogglesReversedFlag() {
        let main = pipe([Vec3(0, 0, 0), Vec3(10000, 0, 0)])
        let branch = pipe([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)], od: 89, branchKind: "LT")
        func mainDirection(_ b: Entity) -> Vec2? {
            let js = PipeNetwork.junctions(in: [main, b])
            for j in js[main.id] ?? [] {
                if case .tee(_, _, _, _, let d, _, _) = j.kind { return d }
            }
            return nil
        }
        XCTAssertEqual(mainDirection(branch)?.x ?? 0, 1, accuracy: 1e-9)
        guard let r = PipeFlip.flip(branch, in: [main, branch]) else { return XCTFail() }
        XCTAssertEqual(r.outcome, .toggledBranch(nowReversed: true))
        XCTAssertEqual(points(r.entity), points(branch))          // 形は変えない
        XCTAssertEqual(attrs(r.entity)?.branchReversed, true)
        XCTAssertEqual(mainDirection(r.entity)?.x ?? 0, -1, accuracy: 1e-9)
        // もう一度で元に戻る
        guard let r2 = PipeFlip.flip(r.entity, in: [main, r.entity]) else { return XCTFail() }
        XCTAssertEqual(r2.outcome, .toggledBranch(nowReversed: false))
    }

    /// 反転したLTは大曲のスイープが反対側(−作図方向)へ出る
    func testReversedLTSweepsUpstream() {
        let main = pipe([Vec3(0, 0, 0), Vec3(10000, 0, 0)])
        let branch = pipe([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)], od: 114, branchKind: "LT")
        func sweepX(_ b: Entity) -> Double {
            let js = PipeNetwork.junctions(in: [main, b])
            guard let tee = js[main.id]?.first, let a = attrs(main),
                  let shape = PipeNetwork.junctionShapes(tee, attrs: a).first else { return 0 }
            // 継手の頂点の平均x − 接続点x。スイープの側へ偏る
            let xs = shape.points.map(\.x)
            return xs.reduce(0, +) / Double(xs.count) - 3000
        }
        XCTAssertGreaterThan(sweepX(branch), 5)
        guard let r = PipeFlip.flip(branch, in: [main, branch]) else { return XCTFail() }
        XCTAssertLessThan(sweepX(r.entity), -5)
    }

    /// 本管を選んで反転 → 作図方向が逆になる(付いている分岐の数を返す)
    func testHostReversesFlow() {
        let main = pipe([Vec3(0, 0, 0), Vec3(10000, 0, 0), Vec3(10000, 3000, 0)])
        let b1 = pipe([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)], od: 89, branchKind: "LT")
        let b2 = pipe([Vec3(6000, 0, 0), Vec3(6000, -2000, 0)], od: 89)
        guard let r = PipeFlip.flip(main, in: [main, b1, b2]) else { return XCTFail() }
        XCTAssertEqual(r.outcome, .reversedFlow(branches: 2))
        XCTAssertEqual(points(r.entity), Array(points(main).reversed()))
        // 反転後も分岐はそのまま付いている
        let js = PipeNetwork.junctions(in: [r.entity, b1, b2])
        XCTAssertEqual(js[main.id]?.count, 2)
    }

    /// 単独の配管は作図方向だけ逆にする
    func testLonePipeReversesPoints() {
        let p = pipe([Vec3(0, 0, 0), Vec3(5000, 0, 0)])
        guard let r = PipeFlip.flip(p, in: [p]) else { return XCTFail() }
        XCTAssertEqual(r.outcome, .reversedFlow(branches: 0))
        XCTAssertEqual(points(r.entity), [Vec3(5000, 0, 0), Vec3(0, 0, 0)])
    }

    /// 配管以外はnil
    func testNonPipeReturnsNil() {
        let line = Entity(layer: layer, kind: .line(a: Vec2(0, 0), b: Vec2(1, 1)))
        XCTAssertNil(PipeFlip.flip(line, in: [line]))
    }
}
