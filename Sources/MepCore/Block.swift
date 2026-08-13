import Foundation

// MARK: - ブロック定義(M4.8)
//
// 定義と参照を分離する: BlockDefinitionが中身(基準点を原点とするローカル座標)を持ち、
// 配置はEntityKind.blockRef(挿入点・回転・倍率・反転)の1要素になる。
// - 器具が1クリックで塊として選択でき、移動・複写・回転・反転がそのまま効く
// - 材料拾いはblockRefを数えるだけ
// - 機器仕様書URL(v2要望)は定義のlinkURLに持たせる
// - DXFのBLOCKS/INSERT・JWWのCDataBlockと同じ構造なので相互変換の受け皿になる
// 制約(v1): 定義の中にblockRefは入れない(ブロック化時に入れ子は展開して取り込む)

public struct BlockDefinition: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    /// 中身(基準点を原点とするローカル座標。blockRefは含まない)
    public var entities: [Entity]
    /// 機器仕様書などへのリンク(v2: 図面から仕様書PDFを開く)
    public var linkURL: String?

    public init(id: UUID = UUID(), name: String, entities: [Entity], linkURL: String? = nil) {
        self.id = id
        self.name = name
        self.entities = entities
        self.linkURL = linkURL
    }

    /// 配置情報を適用して実体化する(描画・スナップ・分解用)。
    /// 変換順: ローカル反転(縦軸) → 倍率 → 回転 → 挿入点へ平行移動。
    /// layerは配置(blockRef)のレイヤ — byLayerスタイルはこのレイヤで解決される。
    public func instantiate(insert: Vec2, rotation: Double, scale: Double,
                            mirrored: Bool, layer: LayerAddress,
                            freshIDs: Bool = false) -> [Entity] {
        entities.map { element in
            var out = element
            if mirrored {
                out = out.mirrored(acrossLineFrom: .zero, to: Vec2(0, 1))
            }
            if abs(scale - 1) > 1e-12 {
                out = out.scaled(by: scale, around: .zero)
            }
            if abs(rotation) > 1e-12 {
                out = out.rotated(around: .zero, byRadians: rotation)
            }
            out = out.translated(by: insert)
            out.layer = layer
            if freshIDs {
                out = Entity(layer: out.layer, style: out.style, kind: out.kind)
            }
            return out
        }
    }

    /// この定義の配置1つ分のバウンディングボックス(cachedBounds計算用)
    public func bounds(insert: Vec2, rotation: Double, scale: Double, mirrored: Bool) -> BBox {
        var box = BBox.empty
        for e in instantiate(insert: insert, rotation: rotation, scale: scale,
                             mirrored: mirrored, layer: .zero) {
            box.union(e.bounds)
        }
        return box
    }
}

// MARK: - Documentのブロック管理

extension Document {

    public func blockDefinition(id: UUID) -> BlockDefinition? {
        blockDefinitions.first(where: { $0.id == id })
    }

    /// 定義の辞書(描画・スナップの1パス用)
    public var blockDefinitionsByID: [UUID: BlockDefinition] {
        Dictionary(uniqueKeysWithValues: blockDefinitions.map { ($0.id, $0) })
    }
}

// MARK: - コマンド

/// 選択をブロック化する(定義を登録し、元要素を配置1つに置き換える)。1回のUndoで戻る
public final class BlockifyCommand: Command {
    public let name = "ブロック化"
    private let definition: BlockDefinition
    private let memberIDs: Set<EntityID>
    private let reference: Entity
    private var removed: [(index: Int, entity: Entity)] = []

    public init(definition: BlockDefinition, memberIDs: Set<EntityID>, reference: Entity) {
        self.definition = definition
        self.memberIDs = memberIDs
        self.reference = reference
    }

    public func execute(on document: Document) {
        document.addBlockDefinition(definition)
        removed = document.removeBulkIndexed(ids: memberIDs)
        document.add(reference)
    }

    public func undo(on document: Document) {
        _ = document.remove(id: reference.id)
        document.insertBulk(removed)
        document.removeBlockDefinition(id: definition.id)
    }
}

/// ブロック配置を基本図形に分解する(定義は残す — 他の配置が使っている可能性があるため)
public final class ExplodeBlockCommand: Command {
    public let name = "ブロック解除"
    private let reference: Entity
    private let expanded: [Entity]

    /// expandedは新しいidを持つ展開済みエンティティを渡す
    public init(reference: Entity, expanded: [Entity]) {
        self.reference = reference
        self.expanded = expanded
    }

    public func execute(on document: Document) {
        _ = document.remove(id: reference.id)
        document.appendBulk(expanded)
    }

    public func undo(on document: Document) {
        document.removeBulk(ids: Set(expanded.map(\.id)))
        document.add(reference)
    }
}
