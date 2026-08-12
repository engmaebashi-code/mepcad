import Foundation
import MepCore

/// 矩形選択のモード(ドラッグ方向で自動判定するのがCADの流儀)
/// 左→右: 窓選択(完全内包のみ) / 右→左: 交差選択(触れたものすべて)
public enum RectSelectionMode: Sendable {
    case window    // 内包
    case crossing  // 交差

    public var label: String {
        switch self {
        case .window: return "窓選択(内包)"
        case .crossing: return "交差選択"
        }
    }
}

/// 選択のヒットテスト(UI非依存・ユニットテスト対象)。
/// 非表示レイヤ・ロックレイヤ(isEditable=false)のエンティティは選択対象外。
public enum SelectionEngine {

    /// 選択可能なレイヤidの集合を作る
    public static func selectableLayerIDs(_ layers: [Layer]) -> Set<LayerID> {
        Set(layers.filter { $0.isVisible && $0.isEditable }.map(\.id))
    }

    /// クリック位置に最も近いエンティティ(許容距離内)。同距離なら後から描いたものを優先
    public static func topmostHit(at p: Vec2, tolerance: Double,
                                  entities: [Entity], layers: [Layer]) -> EntityID? {
        let selectable = selectableLayerIDs(layers)
        var best: EntityID?
        var bestDist = tolerance
        // 後方(=上に描かれるもの)から走査し、同距離では先に見つけた方=上を保持
        for entity in entities.reversed() where selectable.contains(entity.layerID) {
            // バウンディングボックスで粗く除外(数万要素対応)
            let box = entity.bounds.expanded(by: tolerance)
            guard box.contains(p) else { continue }
            let d = entity.hitDistance(to: p)
            if d < bestDist {
                bestDist = d
                best = entity.id
            }
        }
        return best
    }

    /// 矩形範囲のエンティティid(モードに応じて内包/交差)
    public static func ids(in rect: BBox, mode: RectSelectionMode,
                           entities: [Entity], layers: [Layer]) -> [EntityID] {
        let selectable = selectableLayerIDs(layers)
        var result: [EntityID] = []
        for entity in entities where selectable.contains(entity.layerID) {
            // 粗い除外: バウンディングボックスが矩形と重ならないものはスキップ
            let box = entity.bounds
            guard !(box.maxX < rect.minX || box.minX > rect.maxX ||
                    box.maxY < rect.minY || box.minY > rect.maxY) else { continue }
            switch mode {
            case .window:
                if entity.isContained(in: rect) { result.append(entity.id) }
            case .crossing:
                if entity.intersects(rect: rect) { result.append(entity.id) }
            }
        }
        return result
    }
}
