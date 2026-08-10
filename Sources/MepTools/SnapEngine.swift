import Foundation
import MepCore

public enum SnapKind: Int, Sendable {
    case endpoint = 0
    case midpoint = 1
    case center = 2
    case grid = 3
}

public struct SnapResult: Sendable {
    public let point: Vec2
    public let kind: SnapKind
}

/// グリッドバケット空間索引によるスナップエンジン。
/// M1は端点・中点・中心+グリッド補正。交点・線上スナップはM3で追加。
public final class SnapEngine {
    private var buckets: [Int64: [Vec2]] = [:]
    private let cellSize: Double

    public var gridSpacing: Double = 250  // mm
    public var gridEnabled = true
    public var pointSnapEnabled = true

    public init(cellSize: Double = 500) {
        self.cellSize = cellSize
    }

    private func key(_ p: Vec2) -> Int64 {
        let cx = Int64((p.x / cellSize).rounded(.down))
        let cy = Int64((p.y / cellSize).rounded(.down))
        return cx &* 1_000_003 &+ cy
    }

    /// ドキュメントからスナップ点索引を再構築
    public func rebuild(from document: Document) {
        buckets.removeAll(keepingCapacity: true)
        for entity in document.entities {
            guard let layer = document.layer(id: entity.layerID), layer.isVisible else { continue }
            for p in entity.snapPoints {
                buckets[key(p), default: []].append(p)
            }
        }
    }

    /// worldPoint近傍のスナップを探す。radiusはワールドmm(ピックボックス半径をmm換算して渡す)
    public func snap(_ worldPoint: Vec2, radius: Double) -> SnapResult? {
        // 1) 端点系スナップ
        if pointSnapEnabled {
            var best: Vec2?
            var bestDist = radius
            let cx = Int64((worldPoint.x / cellSize).rounded(.down))
            let cy = Int64((worldPoint.y / cellSize).rounded(.down))
            for dx in -1...1 {
                for dy in -1...1 {
                    let k = (cx + Int64(dx)) &* 1_000_003 &+ (cy + Int64(dy))
                    guard let points = buckets[k] else { continue }
                    for p in points {
                        let d = p.distance(to: worldPoint)
                        if d < bestDist {
                            bestDist = d
                            best = p
                        }
                    }
                }
            }
            if let b = best {
                return SnapResult(point: b, kind: .endpoint)
            }
        }
        // 2) グリッド補正
        if gridEnabled {
            let gx = (worldPoint.x / gridSpacing).rounded() * gridSpacing
            let gy = (worldPoint.y / gridSpacing).rounded() * gridSpacing
            let gp = Vec2(gx, gy)
            if gp.distance(to: worldPoint) <= radius {
                return SnapResult(point: gp, kind: .grid)
            }
        }
        return nil
    }
}
