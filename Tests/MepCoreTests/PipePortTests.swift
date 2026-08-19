import XCTest
@testable import MepCore

/// 接続口(ポート)M7 — 導出・突き合わせ・機器ポート・径違いの受口ずれ
final class PipePortTests: XCTestCase {

    let layer = LayerAddress(0, 0)

    /// DV100相当の寸法(A=112, 受口深さ50, 受口外径124)
    private func attrs(size: String = "100", od: Double = 114,
                       a: Double = 112, depth: Double = 50, socketOD: Double = 124)
    -> PipeAttributes {
        PipeAttributes(usage: "S", usageName: "汚水", material: "VP", materialLabel: "VP",
                       size: size, sizeLabel: size, outerDiameter: od,
                       fittingSeries: "DV",
                       fittingDims: PipeFittingDims(elbow90A: a, elbow45A: a * 0.6,
                                                    teeA: a, socketDepth: depth,
                                                    socketOD: socketOD))
    }

    private func pipe(_ pts: [Vec3], _ a: PipeAttributes) -> Entity {
        Entity(layer: layer, kind: .pipe(points: pts, attrs: a))
    }

    // MARK: - 導出

    /// 端部の口は外向き(管の内側から外へ)を向く
    func testEndPortsFaceOutward() {
        let pts = [Vec3(0, 0, 0), Vec3(5000, 0, 0)]
        let ports = PipePorts.ports(points: pts, attrs: attrs())
        XCTAssertEqual(ports.count, 2)
        let start = ports[0], end = ports[1]
        XCTAssertEqual(start.position, Vec3(0, 0, 0))
        XCTAssertEqual(start.direction.x, -1, accuracy: 1e-9)   // 始点は−x向き
        XCTAssertEqual(end.direction.x, 1, accuracy: 1e-9)      // 終点は+x向き
        XCTAssertEqual(start.axis, .horizontal)
        XCTAssertEqual(start.sizeLabel, "100")
        XCTAssertEqual(start.socketDepth, 50)
        XCTAssertTrue(start.isOpen)
    }

    /// 折れ点のエルボは、芯からA寸法だけ離れた位置に口を2つ持つ(常に接続済み)
    func testElbowPortsAtADimension() {
        let pts = [Vec3(0, 0, 0), Vec3(3000, 0, 0), Vec3(3000, 3000, 0)]
        let ports = PipePorts.ports(points: pts, attrs: attrs())
        let elbow = ports.filter { $0.role == .elbow }
        XCTAssertEqual(elbow.count, 2)
        for p in elbow {
            XCTAssertEqual(p.plan.distance(to: Vec2(3000, 0)), 112, accuracy: 1e-6)
            XCTAssertFalse(p.isOpen)
        }
        // 手前側の口は−x(戻る向き)、先側は+y
        XCTAssertEqual(elbow[0].direction.x, -1, accuracy: 1e-9)
        XCTAssertEqual(elbow[1].direction.y, 1, accuracy: 1e-9)
    }

    /// 立管で終わる配管の端は上/下向きの口になる
    func testVerticalEndPortAxis() {
        let up = PipePorts.ports(points: [Vec3(0, 0, 0), Vec3(0, 0, 2500)], attrs: attrs())
        XCTAssertEqual(up[1].axis, .up)
        let down = PipePorts.ports(points: [Vec3(0, 0, 0), Vec3(0, 0, -800)], attrs: attrs())
        XCTAssertEqual(down[1].axis, .down)
    }

    /// 受口の底は口から内側へ受口深さぶん入った点
    func testSocketBottom() {
        let ports = PipePorts.ports(points: [Vec3(0, 0, 0), Vec3(5000, 0, 0)], attrs: attrs())
        XCTAssertEqual(ports[1].socketBottom.x, 5000 - 50, accuracy: 1e-9)
    }

    // MARK: - 突き合わせ(mate)

    /// 口を相手の口へ突き合わせると正対する(向きが180°反対になり位置が一致)
    func testMateFacesTarget() {
        // 部品側: 原点から+x向きの口
        let part = PipePort(position: Vec3(0, 0, 0), azimuth: 0)
        // 相手: (1000, 500)で+y向きに開いた口
        let target = PipePort(position: Vec3(1000, 500, 300), azimuth: .pi / 2)
        let m = part.mate(to: target)
        let moved = m.apply(part)
        XCTAssertEqual(moved.plan.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(moved.plan.y, 500, accuracy: 1e-6)
        XCTAssertEqual(moved.position.z, 300, accuracy: 1e-6)
        // 正対 = 内積が−1
        let dot = moved.direction.x * target.direction.x + moved.direction.y * target.direction.y
        XCTAssertEqual(dot, -1, accuracy: 1e-9)
        XCTAssertTrue(moved.isMated(with: target))
    }

    /// 部品の他の点も同じ変換で動く(口だけが動くのではない)
    func testMateMovesWholePart() {
        let part = PipePort(position: Vec3(0, 0, 0), azimuth: .pi)   // −x向きの口
        let target = PipePort(position: Vec3(2000, 0, 0), azimuth: 0)
        let m = part.mate(to: target)
        // 口の反対側(+x方向に100)の点は、突き合わせ後は目標の先(+x)へ出る
        let tail = m.apply(Vec2(100, 0))
        XCTAssertEqual(tail.x, 2100, accuracy: 1e-6)
        XCTAssertEqual(tail.y, 0, accuracy: 1e-6)
    }

    /// 口径判定(ラベル優先・無ければ外径)
    func testFits() {
        let a = PipePort(position: .init(0, 0, 0), azimuth: 0, sizeLabel: "100", outerDiameter: 114)
        let b = PipePort(position: .init(0, 0, 0), azimuth: 0, sizeLabel: "100", outerDiameter: 114)
        let c = PipePort(position: .init(0, 0, 0), azimuth: 0, sizeLabel: "75", outerDiameter: 89)
        XCTAssertTrue(a.fits(b))
        XCTAssertFalse(a.fits(c))
        let noLabel = PipePort(position: .init(0, 0, 0), azimuth: 0, outerDiameter: 114)
        XCTAssertTrue(noLabel.fits(a))
    }

    // MARK: - 図面全体の索引

    /// 突き合わさっている端は未接続から外れ、自由端だけが残る
    func testOpenPortsExcludeConnectedEnds() {
        let a = pipe([Vec3(0, 0, 0), Vec3(3000, 0, 0)], attrs())
        let b = pipe([Vec3(3000, 0, 0), Vec3(6000, 0, 0)], attrs())
        let open = PipePortIndex.openPorts(in: [a, b])
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(Set(open.map { $0.plan.x }), [0, 6000])
    }

    /// 本管の芯線上に取り付いた枝管の端も接続扱いになる
    func testBranchEndIsConnected() {
        let main = pipe([Vec3(0, 0, 0), Vec3(6000, 0, 0)], attrs())
        let branch = pipe([Vec3(3000, 0, 0), Vec3(3000, 2000, 0)], attrs(size: "75", od: 89))
        let open = PipePortIndex.openPorts(in: [main, branch])
        // 本管の両端 + 枝管の先端 = 3
        XCTAssertEqual(open.count, 3)
        XCTAssertFalse(open.contains { $0.plan.distance(to: Vec2(3000, 0)) < 1 })
    }

    /// 高さが違えば平面上重なっていても接続しない(立体交差)
    func testDifferentHeightNotConnected() {
        let a = pipe([Vec3(0, 0, 0), Vec3(3000, 0, 0)], attrs())
        let b = pipe([Vec3(3000, 0, 2000), Vec3(6000, 0, 2000)], attrs())
        XCTAssertEqual(PipePortIndex.openPorts(in: [a, b]).count, 4)
    }

    // MARK: - 機器(ブロック)のポート

    /// ブロック定義のポートは配置の回転・挿入点に追随する
    func testBlockPortsFollowPlacement() {
        let def = BlockDefinition(name: "洗面器", entities: [],
                                  ports: [BlockPort(position: Vec2(100, 0), azimuth: 0, z: 500,
                                                    name: "給水", sizeLabel: "13",
                                                    outerDiameter: 18, usage: "CW")])
        let ports = def.worldPorts(insert: Vec2(1000, 2000), rotation: .pi / 2,
                                   scale: 1, mirrored: false)
        XCTAssertEqual(ports.count, 1)
        let p = ports[0]
        XCTAssertEqual(p.plan.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(p.plan.y, 2100, accuracy: 1e-6)   // +x100が回転して+y100
        XCTAssertEqual(p.direction.y, 1, accuracy: 1e-9) // 向きも回る
        XCTAssertEqual(p.position.z, 500)
        XCTAssertEqual(p.role, .equipment)
        XCTAssertEqual(p.name, "給水")
    }

    /// 反転(縦軸)ではx座標と方位が鏡映される
    func testBlockPortsMirrored() {
        let def = BlockDefinition(name: "機器", entities: [],
                                  ports: [BlockPort(position: Vec2(100, 50), azimuth: 0)])
        let p = def.worldPorts(insert: .zero, rotation: 0, scale: 1, mirrored: true)[0]
        XCTAssertEqual(p.plan.x, -100, accuracy: 1e-6)
        XCTAssertEqual(p.plan.y, 50, accuracy: 1e-6)
        XCTAssertEqual(p.direction.x, -1, accuracy: 1e-9)
    }

    /// 機器の口も、配管が刺さっていれば未接続から外れる
    func testEquipmentPortClosedWhenPipeAttached() {
        let def = BlockDefinition(name: "機器", entities: [],
                                  ports: [BlockPort(position: Vec2(0, 0), azimuth: 0,
                                                    sizeLabel: "100", outerDiameter: 114)])
        let ref = Entity(layer: layer,
                         kind: .blockRef(definitionID: def.id, insert: Vec2(1000, 0),
                                         rotation: 0, scale: 1, mirrored: false,
                                         cachedBounds: .empty))
        let defs = [def.id: def]
        XCTAssertEqual(PipePortIndex.openPorts(in: [ref], definitions: defs).count, 1)
        let p = pipe([Vec3(1000, 0, 0), Vec3(4000, 0, 0)], attrs())
        let open = PipePortIndex.openPorts(in: [ref, p], definitions: defs)
        XCTAssertFalse(open.contains { $0.role == .equipment })
    }

    // MARK: - 径違いの受口ずれ(shiftA1)

    /// 同径なら0(既存の見た目が変わらないことの保証)
    func testSocketShiftZeroForSameSize() {
        XCTAssertEqual(PipeGeometry.socketShift(od: 114, otherOD: 114,
                                                socketOD: 124, otherSocketOD: 124,
                                                taper: 30), 0)
    }

    /// 大径→小径では正(受口底が小径側へずれる)。テーパが長いほど小さくなる
    func testSocketShiftSign() {
        let short = PipeGeometry.socketShift(od: 114, otherOD: 89,
                                             socketOD: 124, otherSocketOD: 97, taper: 30)
        let long = PipeGeometry.socketShift(od: 114, otherOD: 89,
                                            socketOD: 124, otherSocketOD: 97, taper: 100)
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(short, long)
        // 肉厚(=max(124−114, 97−89)/2 = 5)を超えない
        XCTAssertLessThanOrEqual(short, 5)
        // 逆向き(小径→大径)は負
        XCTAssertLessThan(PipeGeometry.socketShift(od: 89, otherOD: 114,
                                                   socketOD: 97, otherSocketOD: 124,
                                                   taper: 30), 0)
    }
}
