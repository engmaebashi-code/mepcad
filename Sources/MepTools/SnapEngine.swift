import Foundation
import MepCore

public enum SnapKind: Int, Sendable {
    case endpoint = 0      // 端点
    case midpoint = 1      // 中点
    case center = 2        // 円・円弧の中心
    case grid = 3          // グリッド
    case intersection = 4  // 交点
    case onLine = 5        // 線上
    case port = 6          // 接続口(配管・機器のポート)M7

    public var label: String {
        switch self {
        case .endpoint: return "端点"
        case .midpoint: return "中点"
        case .center: return "中心"
        case .grid: return "グリッド"
        case .intersection: return "交点"
        case .onLine: return "線上"
        case .port: return "接続口"
        }
    }
}

public struct SnapResult: Sendable {
    public let point: Vec2
    public let kind: SnapKind
}

/// スナップ種別ごとの有効/無効(環境設定に載せる想定の設定値)
public struct SnapSettings: Sendable {
    public var endpoint = true
    public var midpoint = true
    public var center = true
    public var intersection = true
    public var onLine = true
    public var grid = true
    /// 接続口(配管の自由端・機器の接続口)への吸着。M7
    public var port = true

    public init() {}
}

/// グリッドバケット空間索引によるスナップエンジン。
/// 点(端点・中点・中心)は事前索引、交点・線上はカーソル近傍の線分だけを
/// その場で計算する(全交点の事前計算はO(n²)で7万線分では不可能なため)。
/// 優先順位: 端点 > 交点 > 中点 > 中心 > 線上 > グリッド
public final class SnapEngine {

    private struct TypedPoint {
        var point: Vec2
        var kind: SnapKind
    }

    private struct Segment {
        var a: Vec2
        var b: Vec2
    }

    private var pointBuckets: [Int64: [TypedPoint]] = [:]
    /// 未接続の接続口(M7)。数が少ない(数十〜数百)ので線形探索で足りる
    private var openPorts: [PipePort] = []
    private var segments: [Segment] = []
    private var segmentBuckets: [Int64: [Int32]] = [:]
    private let cellSize: Double

    public var settings = SnapSettings()
    public var gridSpacing: Double = 250  // mm

    /// 互換ブリッジ(グリッド表示切替と連動)
    public var gridEnabled: Bool {
        get { settings.grid }
        set { settings.grid = newValue }
    }

    public init(cellSize: Double = 500) {
        self.cellSize = cellSize
    }

    // MARK: - 索引構築

    private func cellKey(_ cx: Int64, _ cy: Int64) -> Int64 {
        cx &* 1_000_003 &+ cy
    }

    private func cellOf(_ p: Vec2) -> (Int64, Int64) {
        (Int64((p.x / cellSize).rounded(.down)), Int64((p.y / cellSize).rounded(.down)))
    }

    /// excluding: 索引から除外するエンティティ(グリップ編集中に自分自身の
    /// 旧位置へ吸着して動かせなくなるのを防ぐ)
    public func rebuild(from document: Document, excluding: Set<EntityID> = []) {
        pointBuckets.removeAll(keepingCapacity: true)
        segments.removeAll(keepingCapacity: true)
        segmentBuckets.removeAll(keepingCapacity: true)
        openPorts.removeAll(keepingCapacity: true)

        let defs = document.blockDefinitionsByID
        // 接続口(M7): 配管の自由端と機器の接続口。表示中・除外外のものだけ
        let portSources = document.entities.filter {
            !excluding.contains($0.id) && document.isEntityVisible($0)
        }
        openPorts = PipePortIndex.openPorts(in: portSources, definitions: defs)
        for entity in document.entities {
            guard !excluding.contains(entity.id) else { continue }
            guard document.isEntityVisible(entity) else { continue }
            // ブロック配置は実体化して中身の端点・線分を索引(器具の接続点にスナップできる)
            if case .blockRef(let defID, let insert, let rotation, let scale, let mirrored, _) = entity.kind,
               let def = defs[defID] {
                for sub in def.instantiate(insert: insert, rotation: rotation,
                                           scale: scale, mirrored: mirrored, layer: entity.layer) {
                    index(sub)
                }
                continue
            }
            index(entity)
        }
    }

    /// 1エンティティ分の索引追加(blockRefの中身は事前に実体化して渡す)
    private func index(_ entity: Entity) {
            switch entity.kind {
            case .line(let a, let b):
                addPoint(a, .endpoint)
                addPoint(b, .endpoint)
                addPoint(Vec2((a.x + b.x) / 2, (a.y + b.y) / 2), .midpoint)
                addSegment(a, b)
            case .circle(let c, _):
                addPoint(c, .center)
            case .arc(let c, let r, let sa, let ea):
                addPoint(c, .center)
                addPoint(Vec2(c.x + r * cos(sa), c.y + r * sin(sa)), .endpoint)
                addPoint(Vec2(c.x + r * cos(ea), c.y + r * sin(ea)), .endpoint)
            case .text(let p, _, _, _):
                addPoint(p, .endpoint)
            case .point(let p):
                addPoint(p, .endpoint)
            case .blockRef(_, let insert, _, _, _, _):
                addPoint(insert, .endpoint)  // 挿入点(定義が引けない場合の保険)
            case .hatch(let boundary, _):
                // 境界の頂点と辺(パターン線には吸着しない — 境界に合わせる操作が主)
                guard boundary.count >= 2 else { break }
                for i in 0..<boundary.count {
                    addPoint(boundary[i], .endpoint)
                    addSegment(boundary[i], boundary[(i + 1) % boundary.count])
                }
            case .dimension(let a, let b, _, _, _):
                // 測定点と寸法線の両端(連続寸法の起点に使える)
                guard let layout = DimensionGeometry.layout(of: entity) else { break }
                addPoint(a, .endpoint)
                addPoint(b, .endpoint)
                addPoint(layout.dimLine.0, .endpoint)
                addPoint(layout.dimLine.1, .endpoint)
                addSegment(layout.dimLine.0, layout.dimLine.1)
            case .leader(let tip, let elbow, _, _):
                addPoint(tip, .endpoint)
                addPoint(elbow, .endpoint)
                addSegment(tip, elbow)
            case .pipe(let points, _):
                guard points.count >= 2 else { break }
                for p in points { addPoint(p.xy, .endpoint) }
                for seg in PipeGeometry.planSegments(points: points) {
                    addPoint(Vec2((seg.0.x + seg.1.x) / 2, (seg.0.y + seg.1.y) / 2), .midpoint)
                    addSegment(seg.0, seg.1)
                }
            }
    }

    private func addPoint(_ p: Vec2, _ kind: SnapKind) {
        let (cx, cy) = cellOf(p)
        pointBuckets[cellKey(cx, cy), default: []].append(TypedPoint(point: p, kind: kind))
    }

    /// 線分を通過セルすべてに登録(セルサイズの半分刻みで線分上を歩く)
    private func addSegment(_ a: Vec2, _ b: Vec2) {
        let index = Int32(segments.count)
        segments.append(Segment(a: a, b: b))
        let length = a.distance(to: b)
        let steps = max(1, Int(length / (cellSize * 0.5)))
        var lastKey: Int64 = .min
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let p = Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            let (cx, cy) = cellOf(p)
            let key = cellKey(cx, cy)
            if key != lastKey {
                segmentBuckets[key, default: []].append(index)
                lastKey = key
            }
        }
    }

    // MARK: - スナップ検索

    public func snap(_ worldPoint: Vec2, radius: Double) -> SnapResult? {
        // 第1層: 点系スナップ(端点・交点・中点・中心)は「距離×重み」で競争させる。
        // 固定優先順だと密集図面で端点が常に勝ってしまい、交点に吸着できないため。
        // 重みが小さいほど有利(端点をわずかに優遇)。
        var best: (result: SnapResult, score: Double)?

        func consider(_ candidate: (SnapResult, Double)?, weight: Double) {
            guard let candidate else { return }
            let score = candidate.1 * weight
            if best == nil || score < best!.score {
                best = (candidate.0, score)
            }
        }

        if settings.port, let p = nearestPort(to: worldPoint, within: radius) {
            // 接続口は端点より優遇する(端点と同じ位置にあるので、負けると種別が出ない)
            consider((SnapResult(point: p.0.plan, kind: .port), p.1), weight: 0.7)
        }
        if settings.endpoint {
            consider(nearestPoint(of: [.endpoint], to: worldPoint, within: radius), weight: 0.8)
        }
        if settings.intersection {
            consider(nearestIntersection(to: worldPoint, within: radius), weight: 0.9)
        }
        if settings.midpoint {
            consider(nearestPoint(of: [.midpoint], to: worldPoint, within: radius), weight: 1.0)
        }
        if settings.center {
            consider(nearestPoint(of: [.center], to: worldPoint, within: radius), weight: 1.0)
        }
        if let best {
            return best.result
        }

        // 第2層: 線上(点系が何もないときだけ。カーソルは常に線の近くに居るため競争には入れない)
        if settings.onLine, let r = nearestOnLine(to: worldPoint, within: radius) {
            return r
        }
        // 第3層: グリッド
        if settings.grid {
            let gx = (worldPoint.x / gridSpacing).rounded() * gridSpacing
            let gy = (worldPoint.y / gridSpacing).rounded() * gridSpacing
            let gp = Vec2(gx, gy)
            if gp.distance(to: worldPoint) <= radius {
                return SnapResult(point: gp, kind: .grid)
            }
        }
        return nil
    }

    /// 最寄りの接続口。戻り値は(口, 距離)
    private func nearestPort(to point: Vec2, within radius: Double) -> (PipePort, Double)? {
        var best: (PipePort, Double)?
        for p in openPorts {
            let d = p.plan.distance(to: point)
            guard d <= radius else { continue }
            if best == nil || d < best!.1 { best = (p, d) }
        }
        return best
    }

    /// 指定点付近の接続口(作図側が口径・管種を継承するために引く)。M7
    public func port(at point: Vec2, radius: Double) -> PipePort? {
        nearestPort(to: point, within: radius)?.0
    }

    /// 現在索引されている未接続の接続口(表示・デバッグ用)
    public var indexedOpenPorts: [PipePort] { openPorts }

    /// 最寄りの点系スナップ。戻り値は(結果, 距離)
    private func nearestPoint(of kinds: Set<SnapKind>, to world: Vec2, within radius: Double) -> (SnapResult, Double)? {
        var best: TypedPoint?
        var bestDist = radius
        let (cx, cy) = cellOf(world)
        for dx in -1...1 {
            for dy in -1...1 {
                guard let points = pointBuckets[cellKey(cx + Int64(dx), cy + Int64(dy))] else { continue }
                for tp in points where kinds.contains(tp.kind) {
                    let d = tp.point.distance(to: world)
                    if d < bestDist {
                        bestDist = d
                        best = tp
                    }
                }
            }
        }
        guard let best else { return nil }
        return (SnapResult(point: best.point, kind: best.kind), bestDist)
    }

    /// カーソル近傍の線分インデックス(重複除去済み)
    private func nearbySegmentIndices(around world: Vec2) -> [Int32] {
        var seen = Set<Int32>()
        var result: [Int32] = []
        let (cx, cy) = cellOf(world)
        for dx in -1...1 {
            for dy in -1...1 {
                guard let list = segmentBuckets[cellKey(cx + Int64(dx), cy + Int64(dy))] else { continue }
                for idx in list where seen.insert(idx).inserted {
                    result.append(idx)
                }
            }
        }
        return result
    }

    /// 最寄りの交点。戻り値は(結果, 距離)。
    /// 交点が半径内にあるためには両方の線分がカーソル半径内を通る必要があるので、
    /// まず「カーソルに近い線分」だけに絞ってから総当たり計算する(密集図面対策)。
    private func nearestIntersection(to world: Vec2, within radius: Double) -> (SnapResult, Double)? {
        let indices = nearbySegmentIndices(around: world)
        // カーソルからの距離で線分を絞り込み
        var near: [(index: Int32, dist: Double)] = []
        for idx in indices {
            let s = segments[Int(idx)]
            let d = Self.closestPointOnSegment(world, s.a, s.b).distance(to: world)
            if d <= radius * 1.2 {
                near.append((idx, d))
            }
        }
        guard near.count >= 2 else { return nil }
        // それでも多い場合は近い順に32本まで(O(k²)の上限を確保)
        if near.count > 32 {
            near.sort { $0.dist < $1.dist }
            near.removeSubrange(32...)
        }
        var best: Vec2?
        var bestDist = radius
        for i in 0..<(near.count - 1) {
            let s1 = segments[Int(near[i].index)]
            for j in (i + 1)..<near.count {
                let s2 = segments[Int(near[j].index)]
                guard let p = Self.segmentIntersection(s1.a, s1.b, s2.a, s2.b) else { continue }
                let d = p.distance(to: world)
                if d < bestDist {
                    bestDist = d
                    best = p
                }
            }
        }
        guard let best else { return nil }
        return (SnapResult(point: best, kind: .intersection), bestDist)
    }

    private func nearestOnLine(to world: Vec2, within radius: Double) -> SnapResult? {
        let indices = nearbySegmentIndices(around: world)
        var best: Vec2?
        var bestDist = radius
        for idx in indices {
            let s = segments[Int(idx)]
            let p = Self.closestPointOnSegment(world, s.a, s.b)
            let d = p.distance(to: world)
            if d < bestDist {
                bestDist = d
                best = p
            }
        }
        guard let best else { return nil }
        return SnapResult(point: best, kind: .onLine)
    }

    // MARK: - 幾何ヘルパ

    /// 線分同士の交点(端点接触も含む)。平行・非交差はnil
    static func segmentIntersection(_ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ p4: Vec2) -> Vec2? {
        let d1 = p2 - p1
        let d2 = p4 - p3
        let denom = d1.x * d2.y - d1.y * d2.x
        guard abs(denom) > 1e-12 else { return nil }
        let dp = p3 - p1
        let t = (dp.x * d2.y - dp.y * d2.x) / denom
        let u = (dp.x * d1.y - dp.y * d1.x) / denom
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return Vec2(p1.x + d1.x * t, p1.y + d1.y * t)
    }

    /// 点から線分への最近点(垂線の足。線分外なら端点)
    static func closestPointOnSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Vec2 {
        let ab = b - a
        let lenSq = ab.x * ab.x + ab.y * ab.y
        guard lenSq > 1e-12 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lenSq))
        return Vec2(a.x + ab.x * t, a.y + ab.y * t)
    }
}
