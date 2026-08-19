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

/// 機器(ブロック定義)の接続口。定義のローカル座標で持ち、配置時に世界座標のPipePortになる。M7
///
/// これがあると「機器に配管を繋ぐ」が継手とまったく同じ仕組み(ポート突き合わせ)で扱える。
/// メーカーCAD(DXF)から取り込んだ機器は図形だけでは接続口が分からないので定義側に明示的に持つ
public struct BlockPort: Equatable, Codable, Sendable {
    /// 定義ローカル座標での接続点
    public var position: Vec2
    /// 定義ローカル座標での外向き方位角(rad)。ここから配管が出ていく向き
    public var azimuth: Double
    /// 基準面からの高さ(mm)
    public var z: Double
    /// 接続口名("給水" "排水" "冷媒液" など)
    public var name: String
    /// 呼び径ラベルと外径(mm)。0なら接続する配管に合わせる
    public var sizeLabel: String
    public var outerDiameter: Double
    /// 用途id("CW"等。空なら配管側の設定のまま)
    public var usage: String

    public init(position: Vec2, azimuth: Double, z: Double = 0, name: String = "",
                sizeLabel: String = "", outerDiameter: Double = 0, usage: String = "") {
        self.position = position
        self.azimuth = azimuth
        self.z = z
        self.name = name
        self.sizeLabel = sizeLabel
        self.outerDiameter = outerDiameter
        self.usage = usage
    }
}

public struct BlockDefinition: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    /// 中身(基準点を原点とするローカル座標。blockRefは含まない)
    public var entities: [Entity]
    /// 機器仕様書などへのリンク(v2: 図面から仕様書PDFを開く)
    public var linkURL: String?
    /// 機器の接続口(M7)。空なら配管は吸着しない
    public var ports: [BlockPort]

    public init(id: UUID = UUID(), name: String, entities: [Entity], linkURL: String? = nil,
                ports: [BlockPort] = []) {
        self.id = id
        self.name = name
        self.entities = entities
        self.linkURL = linkURL
        self.ports = ports
    }

    // portsは後から足した項目。旧図面(portsキーなし)もそのまま読めるようにする
    private enum CodingKeys: String, CodingKey {
        case id, name, entities, linkURL, ports
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        entities = try c.decode([Entity].self, forKey: .entities)
        linkURL = try c.decodeIfPresent(String.self, forKey: .linkURL)
        ports = try c.decodeIfPresent([BlockPort].self, forKey: .ports) ?? []
    }

    /// 配置情報を適用して実体化する(描画・スナップ・分解用)。
    /// 変換順: ローカル反転(縦軸) → 倍率 → 回転 → 挿入点へ平行移動。
    /// layerは配置(blockRef)のレイヤ — byLayerスタイルはこのレイヤで解決される。
    /// overrideStyleは配置側のスタイル上書き(M4.8.1): 非nilの項目(色・線種・太さ)は
    /// 全メンバーに強制適用され、nilの項目はメンバー自身の値のまま。
    /// これによりブロック化後もプロパティパネルからの属性変更が効く。
    public func instantiate(insert: Vec2, rotation: Double, scale: Double,
                            mirrored: Bool, layer: LayerAddress,
                            overrideStyle: Style = .byLayer,
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
            out.style = overrideStyle.overriding(out.style)
            if freshIDs {
                out = Entity(layer: out.layer, style: out.style, kind: out.kind)
            }
            return out
        }
    }

    /// 配置情報を適用した世界座標の接続口(M7)。
    /// 変換順は instantiate と同じ(反転→倍率→回転→挿入点)。反転は縦軸(x→−x)なので
    /// 方位角は π−θ になる。回転はそのまま加算、倍率は位置だけに効く(口径は実寸のまま)
    public func worldPorts(insert: Vec2, rotation: Double, scale: Double,
                           mirrored: Bool, ownerID: EntityID? = nil) -> [PipePort] {
        ports.map { p in
            var pos = p.position
            var az = p.azimuth
            if mirrored {
                pos = Vec2(-pos.x, pos.y)
                az = .pi - az
            }
            if abs(scale - 1) > 1e-12 {
                pos = pos * scale
            }
            if abs(rotation) > 1e-12 {
                let c = cos(rotation), s = sin(rotation)
                pos = Vec2(pos.x * c - pos.y * s, pos.x * s + pos.y * c)
                az += rotation
            }
            pos = pos + insert
            return PipePort(position: Vec3(pos, z: p.z), azimuth: az, axis: .horizontal,
                            role: .equipment, sizeLabel: p.sizeLabel,
                            outerDiameter: p.outerDiameter,
                            usage: p.usage, name: p.name, ownerID: ownerID, isOpen: true)
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
