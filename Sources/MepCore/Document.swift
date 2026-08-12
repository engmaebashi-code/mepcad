import Foundation

/// 図面ドキュメント。エンティティとレイヤを保持する。
/// スレッド安全性はM1では「メインスレッドからのみ触る」規約で担保する。
public final class Document {
    public private(set) var layers: [Layer]
    public private(set) var entities: [Entity]
    public var currentLayerID: LayerID

    /// 変更通知(再描画トリガ用)。UIが差し替える。
    public var onChange: (() -> Void)?

    public init() {
        let set = DefaultLayers.standardSet()
        self.layers = set
        self.entities = []
        // 既定カレントは「基本作図」
        self.currentLayerID = set.first(where: { $0.name == "基本作図" })?.id ?? set[0].id
    }

    // MARK: - 参照

    public func layer(id: LayerID) -> Layer? {
        layers.first(where: { $0.id == id })
    }

    public func entity(id: EntityID) -> Entity? {
        entities.first(where: { $0.id == id })
    }

    public var bounds: BBox {
        var box = BBox.empty
        for e in entities { box.union(e.bounds) }
        return box
    }

    // MARK: - 変更(CommandStack経由で呼ばれる想定。直接呼んでも動く)

    public func add(_ entity: Entity) {
        entities.append(entity)
        onChange?()
    }

    public func remove(id: EntityID) -> Entity? {
        guard let idx = entities.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = entities.remove(at: idx)
        onChange?()
        return removed
    }

    /// 大量追加(JWW読込等)。onChangeは最後に1回だけ発火する
    public func appendBulk(_ newEntities: [Entity]) {
        entities.append(contentsOf: newEntities)
        onChange?()
    }

    /// 指定レイヤのエンティティを全削除(下敷きの入替に使用)
    public func removeAll(inLayer layerID: LayerID) {
        entities.removeAll { $0.layerID == layerID }
        onChange?()
    }

    /// 全エンティティを削除(ファイルを開く=新しい図面に置き換える時に使用)
    public func removeAllEntities() {
        entities.removeAll()
        onChange?()
    }

    public func replace(_ entity: Entity) {
        guard let idx = entities.firstIndex(where: { $0.id == entity.id }) else { return }
        entities[idx] = entity
        onChange?()
    }

    public func updateLayer(_ layer: Layer) {
        guard let idx = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        layers[idx] = layer
        onChange?()
    }

    /// レイヤ追加(JWWグループ展開・ユーザー追加レイヤ用)
    public func addLayer(_ layer: Layer) {
        layers.append(layer)
        onChange?()
    }

    /// 条件に合うレイヤを削除(所属エンティティも削除)。カレントレイヤは削除しない
    public func removeLayers(where predicate: (Layer) -> Bool) {
        let removing = Set(layers.filter { predicate($0) && $0.id != currentLayerID }.map(\.id))
        guard !removing.isEmpty else { return }
        entities.removeAll { removing.contains($0.layerID) }
        layers.removeAll { removing.contains($0.id) }
        onChange?()
    }

    public func setCurrentLayer(id: LayerID) {
        guard layers.contains(where: { $0.id == id }) else { return }
        currentLayerID = id
        onChange?()
    }

    // MARK: - 一括編集(M4: 選択編集用。onChangeは1回だけ発火)

    /// 複数エンティティを平行移動する
    public func translateBulk(ids: Set<EntityID>, by delta: Vec2) {
        guard !ids.isEmpty else { return }
        for idx in entities.indices where ids.contains(entities[idx].id) {
            entities[idx] = entities[idx].translated(by: delta)
        }
        onChange?()
    }

    /// 複数エンティティを削除し、削除したスナップショットを返す(Undo用)
    @discardableResult
    public func removeBulk(ids: Set<EntityID>) -> [Entity] {
        guard !ids.isEmpty else { return [] }
        let removed = entities.filter { ids.contains($0.id) }
        entities.removeAll { ids.contains($0.id) }
        onChange?()
        return removed
    }

    /// 複数エンティティを削除し、(元の位置, 実体)を返す(Undoでの重なり順復元用)
    @discardableResult
    public func removeBulkIndexed(ids: Set<EntityID>) -> [(index: Int, entity: Entity)] {
        guard !ids.isEmpty else { return [] }
        var removed: [(index: Int, entity: Entity)] = []
        var kept: [Entity] = []
        kept.reserveCapacity(entities.count)
        for (i, e) in entities.enumerated() {
            if ids.contains(e.id) {
                removed.append((i, e))
            } else {
                kept.append(e)
            }
        }
        guard !removed.isEmpty else { return [] }
        entities = kept
        onChange?()
        return removed
    }

    /// removeBulkIndexedの逆操作: 元の位置に挿入して重なり順を復元する
    public func insertBulk(_ items: [(index: Int, entity: Entity)]) {
        guard !items.isEmpty else { return }
        for item in items.sorted(by: { $0.index < $1.index }) {
            entities.insert(item.entity, at: min(item.index, entities.count))
        }
        onChange?()
    }

    /// 複数エンティティを同id置換する(属性一括変更用)
    public func replaceBulk(_ newEntities: [Entity]) {
        guard !newEntities.isEmpty else { return }
        var byID: [EntityID: Entity] = [:]
        for e in newEntities { byID[e.id] = e }
        for idx in entities.indices {
            if let replacement = byID[entities[idx].id] {
                entities[idx] = replacement
            }
        }
        onChange?()
    }

    /// idの集合からエンティティ実体を引く(選択ハイライト・プロパティ表示用)
    public func entities(ids: Set<EntityID>) -> [Entity] {
        entities.filter { ids.contains($0.id) }
    }

    // MARK: - デモ用サンプル(M1動作確認)

    /// 機械室風のサンプル図形を配置する(10m×8mの部屋+機器+配管ライン)
    public func loadDemoContent() {
        guard let base = layers.first(where: { $0.name == "基本作図" }),
              let pipe = layers.first(where: { $0.name == "空調配管" }) else { return }

        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ layer: Layer) {
            entities.append(Entity(layerID: layer.id,
                                   kind: .line(a: Vec2(x1, y1), b: Vec2(x2, y2))))
        }

        // 部屋の外形 10,000×8,000
        line(0, 0, 10000, 0, base)
        line(10000, 0, 10000, 8000, base)
        line(10000, 8000, 0, 8000, base)
        line(0, 8000, 0, 0, base)
        // 間仕切り
        line(6000, 0, 6000, 8000, base)
        // 機器(AC-1) 1,500×900 @ (1000, 5500)
        line(1000, 5500, 2500, 5500, base)
        line(2500, 5500, 2500, 6400, base)
        line(2500, 6400, 1000, 6400, base)
        line(1000, 6400, 1000, 5500, base)
        // 冷温水配管(往復)
        line(2500, 6100, 8000, 6100, pipe)
        line(8000, 6100, 8000, 2000, pipe)
        line(2500, 5800, 7700, 5800, pipe)
        line(7700, 5800, 7700, 2000, pipe)
        // バルブ位置の円
        entities.append(Entity(layerID: pipe.id, kind: .circle(center: Vec2(4000, 6100), radius: 60)))
        entities.append(Entity(layerID: pipe.id, kind: .circle(center: Vec2(4000, 5800), radius: 60)))
        // 注記(文字高さは実寸mm: 1/50印刷時に紙面7mm/6mm相当)
        entities.append(Entity(layerID: base.id,
                               kind: .text(position: Vec2(1100, 6600), content: "AC-1", height: 350, angle: 0)))
        entities.append(Entity(layerID: pipe.id,
                               kind: .text(position: Vec2(4300, 6350), content: "50A 冷温水(往)", height: 300, angle: 0)))
        onChange?()
    }
}
