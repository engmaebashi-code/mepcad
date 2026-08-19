import Foundation

// MARK: - 接続口(ポート)M7
//
// 継手・配管・機器の「口」を、位置だけでなく向きを持つ点として表す。
// OSE Piping Workbench(FreeCAD)の AdvancedPort — 位置a・法線n・角度基準r — を
// 平面図(2D)+高さ に落とした版。3Dでは回転行列が要るが、平面図では
//   方位角(azimuth) + 立管フラグ(axis)
// だけで足りる。
//
// 効能は、配管網・継手カタログ・機器ライブラリの接点をこの型ひとつに集約できること:
// - 作図中の吸着先(スナップ)が「端点」ではなく「口径と向きを持つ接続口」になる
// - 機器(ブロック)も同じ口を持てるので、配管の機器接続が継手と同じ仕組みで済む
// - 部品を相手の口へ突き合わせる配置計算が mate(to:) の1式に集約される
//
// M7では既存の継手描画(PipeGeometry / PipeNetwork)には手を入れず、
// そこから「導出される情報」としてポートを載せる追加レイヤーの位置づけ。

/// 接続口。位置(3D)と平面での外向き方位を持つ
public struct PipePort: Equatable, Sendable {

    /// 口の由来(表示・絞り込み用)
    public enum Role: String, Equatable, Sendable, CaseIterable {
        case pipeEnd = "管端"
        case elbow = "エルボ"
        case tee = "ティーズ"
        case riser = "立管"
        case equipment = "機器"
    }

    /// 口の向く軸。水平口は azimuth が有効、立管口は上/下向き
    public enum Axis: Int, Equatable, Sendable {
        case horizontal = 0
        case up = 1
        case down = -1
    }

    /// 接続点(実寸mm。x,y=平面図、z=高さ)
    public var position: Vec3
    /// 平面での外向き方位角(rad)。この口から管が出ていく向き
    public var azimuth: Double
    public var axis: Axis
    public var role: Role
    /// 呼び径ラベル("100")
    public var sizeLabel: String
    /// 管外径(mm)
    public var outerDiameter: Double
    /// 受口深さ(mm。管を差し込む量)
    public var socketDepth: Double
    /// 受口外径(mm)
    public var socketOD: Double
    /// 用途id・管種id・継手規格シリーズ(接続時に継承する属性)
    public var usage: String
    public var material: String
    public var series: String
    /// 表示名(機器の接続口名「給水」「排水」など)
    public var name: String
    /// 持ち主のエンティティ
    public var ownerID: EntityID?
    /// 未接続か(接続済みの口には吸着させない)
    public var isOpen: Bool

    public init(position: Vec3, azimuth: Double, axis: Axis = .horizontal,
                role: Role = .pipeEnd, sizeLabel: String = "", outerDiameter: Double = 0,
                socketDepth: Double = 0, socketOD: Double = 0,
                usage: String = "", material: String = "", series: String = "",
                name: String = "", ownerID: EntityID? = nil, isOpen: Bool = true) {
        self.position = position
        self.azimuth = azimuth
        self.axis = axis
        self.role = role
        self.sizeLabel = sizeLabel
        self.outerDiameter = outerDiameter
        self.socketDepth = socketDepth
        self.socketOD = socketOD
        self.usage = usage
        self.material = material
        self.series = series
        self.name = name
        self.ownerID = ownerID
        self.isOpen = isOpen
    }

    /// 平面位置
    public var plan: Vec2 { position.xy }

    /// 外向き単位ベクトル(平面)
    public var direction: Vec2 { Vec2(cos(azimuth), sin(azimuth)) }

    /// 受口の底(=差し込んだ管の管端)。口の内側へ受口深さぶん入った点
    public var socketBottom: Vec3 {
        Vec3(plan - direction * socketDepth, z: position.z)
    }

    /// 口径が合うか。呼び径ラベルが両方にあればラベルで、無ければ外径で判定
    public func fits(_ other: PipePort, tolerance: Double = 0.5) -> Bool {
        if !sizeLabel.isEmpty, !other.sizeLabel.isEmpty { return sizeLabel == other.sizeLabel }
        return abs(outerDiameter - other.outerDiameter) <= tolerance
    }

    /// 同じ位置で正対しているか(=接続されている)
    public func isMated(with other: PipePort, tolerance: Double = 1.0) -> Bool {
        guard plan.distance(to: other.plan) <= tolerance,
              abs(position.z - other.position.z) <= tolerance else { return false }
        if axis != .horizontal || other.axis != .horizontal {
            return axis.rawValue == -other.axis.rawValue
        }
        let dot = direction.x * other.direction.x + direction.y * other.direction.y
        return dot < -0.999
    }
}

/// 部品を相手の口へ突き合わせる変換(平面の回転+平行移動+高さ合わせ)
public struct PortMate: Equatable, Sendable {
    /// 平面での回転角(rad。原点まわり)
    public let rotation: Double
    /// 回転後の平行移動
    public let translation: Vec2
    /// 高さの移動量
    public let zShift: Double

    public init(rotation: Double, translation: Vec2, zShift: Double = 0) {
        self.rotation = rotation
        self.translation = translation
        self.zShift = zShift
    }

    public func apply(_ p: Vec2) -> Vec2 {
        let c = cos(rotation), s = sin(rotation)
        return Vec2(p.x * c - p.y * s + translation.x, p.x * s + p.y * c + translation.y)
    }

    public func apply(_ p: Vec3) -> Vec3 {
        Vec3(apply(p.xy), z: p.z + zShift)
    }

    public func apply(azimuth: Double) -> Double { azimuth + rotation }

    /// ポートを丸ごと変換する
    public func apply(_ port: PipePort) -> PipePort {
        var out = port
        out.position = apply(port.position)
        out.azimuth = apply(azimuth: port.azimuth)
        return out
    }
}

extension PipePort {
    /// 自分(動かす部品側の口)を相手の口へ突き合わせる変換を返す。
    /// 3Dの AdvancedPort.getPartPlacement の2D版 — 相手と正対する(180°反転)ように回す:
    ///   rotation = 相手の方位 + π − 自分の方位
    /// これ1式で継手・機器の種類に依らず配置できる(部品ごとの場合分けが不要)
    public func mate(to target: PipePort) -> PortMate {
        let rot = target.azimuth + .pi - azimuth
        let c = cos(rot), s = sin(rot)
        let rx = plan.x * c - plan.y * s
        let ry = plan.x * s + plan.y * c
        return PortMate(rotation: rot,
                        translation: Vec2(target.plan.x - rx, target.plan.y - ry),
                        zShift: target.position.z - position.z)
    }
}

// MARK: - 配管からのポート導出

public enum PipePorts {

    /// 配管1本の接続口。端部2つ(自由端になり得る)と、折れ点の継手の口(常に接続済み)。
    /// 立管の付け根も折れ点として上/下向きの口になる
    public static func ports(points: [Vec3], attrs: PipeAttributes,
                             ownerID: EntityID? = nil) -> [PipePort] {
        guard points.count >= 2 else { return [] }
        let dims = attrs.effectiveFittingDims
        var result: [PipePort] = []

        func port(at p: Vec3, outward: Vec3, role: PipePort.Role, isOpen: Bool,
                  planFallback: Vec2?) -> PipePort {
            let planLen = Vec2(outward.x, outward.y).length
            let axis: PipePort.Axis
            let azimuth: Double
            if planLen <= PipeGeometry.planEpsilon {
                axis = outward.z >= 0 ? .up : .down
                let f = planFallback ?? Vec2(1, 0)
                azimuth = atan2(f.y, f.x)
            } else {
                axis = .horizontal
                azimuth = atan2(outward.y, outward.x)
            }
            return PipePort(position: p, azimuth: azimuth, axis: axis, role: role,
                            sizeLabel: attrs.sizeLabel, outerDiameter: attrs.outerDiameter,
                            socketDepth: dims.socketDepth, socketOD: dims.socketOD,
                            usage: attrs.usage, material: attrs.material,
                            series: attrs.fittingSeries, name: "",
                            ownerID: ownerID, isOpen: isOpen)
        }

        // 端部(始点・終点)。立管で終わっていれば上/下向きの口になる
        let n = points.count
        let startOut = points[0] - points[1]
        let endOut = points[n - 1] - points[n - 2]
        result.append(port(at: points[0], outward: startOut, role: .pipeEnd, isOpen: true,
                           planFallback: PipeNetwork.outwardDirection(points: points, atStart: true)))
        result.append(port(at: points[n - 1], outward: endOut, role: .pipeEnd, isOpen: true,
                           planFallback: PipeNetwork.outwardDirection(points: points, atStart: false)))

        // 折れ点の継手。口は折れ点からA寸法だけ各脚方向へ出た位置(=受口の先端)
        guard points.count >= 3 else { return result }
        for i in 1..<(n - 1) {
            let d1 = points[i] - points[i - 1]
            let d2 = points[i + 1] - points[i]
            let l1 = d1.length, l2 = d2.length
            guard l1 > 1e-9, l2 > 1e-9 else { continue }
            let dot = (d1.x * d2.x + d1.y * d2.y + d1.z * d2.z) / (l1 * l2)
            let turnDeg = acos(max(-1, min(1, dot))) * 180 / .pi
            guard turnDeg > 2 else { continue }
            let a = PipeGeometry.elbowA(dims, turnDeg: turnDeg, longRadius: attrs.longRadius)
            let back = d1 * (-1 / l1)        // 折れ点→手前の頂点(=口の外向き)
            let fwd = d2 * (1 / l2)          // 折れ点→次の頂点
            let isRiser = Vec2(back.x, back.y).length <= PipeGeometry.planEpsilon
                || Vec2(fwd.x, fwd.y).length <= PipeGeometry.planEpsilon
            let role: PipePort.Role = isRiser ? .riser : .elbow
            result.append(port(at: points[i] + back * a, outward: back, role: role,
                               isOpen: false, planFallback: Vec2(fwd.x, fwd.y)))
            result.append(port(at: points[i] + fwd * a, outward: fwd, role: role,
                               isOpen: false, planFallback: Vec2(back.x, back.y)))
        }
        return result
    }
}

// MARK: - 図面全体のポート索引

public enum PipePortIndex {

    /// 接続とみなす許容(mm)
    public static var tolerance: Double { PipeNetwork.joinTolerance }

    /// 図面内の配管・機器(ポートを持つブロック配置)からポートを集める。
    /// 端部の口は、他の配管に繋がっていれば isOpen=false になる
    public static func ports(in entities: [Entity],
                             definitions: [UUID: BlockDefinition] = [:]) -> [PipePort] {
        struct P {
            let id: EntityID
            let points: [Vec3]
        }
        var pipes: [P] = []
        var result: [PipePort] = []
        for e in entities {
            switch e.kind {
            case .pipe(let pts, let attrs):
                guard pts.count >= 2 else { continue }
                pipes.append(P(id: e.id, points: pts))
                result += PipePorts.ports(points: pts, attrs: attrs, ownerID: e.id)
            case .blockRef(let defID, let insert, let rotation, let scale, let mirrored, _):
                guard let def = definitions[defID], !def.ports.isEmpty else { continue }
                result += def.worldPorts(insert: insert, rotation: rotation, scale: scale,
                                         mirrored: mirrored, ownerID: e.id)
            default:
                continue
            }
        }
        let tol = tolerance
        for i in result.indices where result[i].isOpen {
            let port = result[i]
            var connected = false
            for pipe in pipes where pipe.id != port.ownerID {
                // 相手の端点と一致
                for p in [pipe.points[0], pipe.points[pipe.points.count - 1]] {
                    if p.xy.distance(to: port.plan) <= tol, abs(p.z - port.position.z) <= tol {
                        connected = true
                        break
                    }
                }
                if connected { break }
                // 相手の芯線上に乗っている(分岐として取り付いている)
                for s in 0..<(pipe.points.count - 1) {
                    let a = pipe.points[s], b = pipe.points[s + 1]
                    guard a.xy.distance(to: b.xy) > PipeGeometry.planEpsilon else { continue }
                    let foot = HitGeometry.closestPointOnSegment(port.plan, a.xy, b.xy)
                    guard foot.distance(to: port.plan) <= tol,
                          abs(port.position.z - a.z) <= tol else { continue }
                    connected = true
                    break
                }
                if connected { break }
            }
            result[i].isOpen = !connected
        }
        return result
    }

    /// 未接続の口だけ(作図中の吸着先)
    public static func openPorts(in entities: [Entity],
                                 definitions: [UUID: BlockDefinition] = [:]) -> [PipePort] {
        ports(in: entities, definitions: definitions).filter(\.isOpen)
    }

    /// 指定点に最も近い口(許容内)
    public static func nearest(to point: Vec2, in ports: [PipePort],
                               within radius: Double) -> PipePort? {
        var best: (PipePort, Double)?
        for p in ports {
            let d = p.plan.distance(to: point)
            guard d <= radius else { continue }
            if best == nil || d < best!.1 { best = (p, d) }
        }
        return best?.0
    }
}
