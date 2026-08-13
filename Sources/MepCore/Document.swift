import Foundation

/// 図面ドキュメント。エンティティと16グループ×16レイヤ(Jw_cad準拠)を保持する。
/// スレッド安全性は「メインスレッドからのみ触る」規約で担保する。
public final class Document {
    /// レイヤ構造(常に16グループ。各グループは常に16レイヤ)
    public private(set) var groups: [LayerGroup]
    public private(set) var entities: [Entity]
    /// 書込レイヤ(カレント)
    public private(set) var current: LayerAddress
    /// 補助線(補助線種・補助線色)の表示。falseで描画・スナップ・選択から外れる
    public private(set) var showAuxiliary = true

    /// 変更通知(再描画トリガ用)。UIが差し替える。
    public var onChange: (() -> Void)?

    public init() {
        self.groups = DefaultLayers.standardGroups()
        self.entities = []
        self.current = DefaultLayers.standardCurrent
    }

    // MARK: - レイヤ参照

    public func group(_ index: Int) -> LayerGroup {
        groups[min(max(index, 0), 15)]
    }

    public func layer(at address: LayerAddress) -> Layer {
        groups[address.group].layers[address.layer]
    }

    /// 実効表示状態(グループとレイヤの両方が表示のとき見える)
    public func isVisible(_ address: LayerAddress) -> Bool {
        let g = groups[address.group]
        return g.isVisible && g.layers[address.layer].isVisible
    }

    /// 実効編集可否(グループ・レイヤともロックされておらず、かつ表示されている)
    public func isSelectable(_ address: LayerAddress) -> Bool {
        let g = groups[address.group]
        let l = g.layers[address.layer]
        return g.isVisible && g.isEditable && l.isVisible && l.isEditable
    }

    /// エンティティ単位の実効表示(レイヤ表示+補助線表示設定)
    public func isEntityVisible(_ entity: Entity) -> Bool {
        isVisible(entity.layer) && (showAuxiliary || !entity.isAuxiliary)
    }

    /// 補助線の表示切替
    public func setShowAuxiliary(_ show: Bool) {
        guard show != showAuxiliary else { return }
        showAuxiliary = show
        onChange?()
    }

    public func entity(id: EntityID) -> Entity? {
        entities.first(where: { $0.id == id })
    }

    public var bounds: BBox {
        var box = BBox.empty
        for e in entities where isVisible(e.layer) { box.union(e.bounds) }
        return box
    }

    // MARK: - レイヤ変更

    /// レイヤ状態の変更(名前・表示・ロック・既定スタイル)
    public func updateLayer(at address: LayerAddress, _ change: (inout Layer) -> Void) {
        change(&groups[address.group].layers[address.layer])
        onChange?()
    }

    /// グループ状態の変更(名前・縮尺・表示・ロック)
    public func updateGroup(_ index: Int, _ change: (inout LayerGroup) -> Void) {
        guard index >= 0, index < 16 else { return }
        change(&groups[index])
        onChange?()
    }

    /// レイヤ構造の一括置換(JWW読込時)
    public func replaceGroups(_ newGroups: [LayerGroup], current newCurrent: LayerAddress) {
        precondition(newGroups.count == 16 && newGroups.allSatisfy { $0.layers.count == 16 },
                     "レイヤ構造は16グループ×16レイヤ固定")
        groups = newGroups
        current = newCurrent
        onChange?()
    }

    /// 書込レイヤの変更(非表示・ロックのレイヤには書き込めない)
    @discardableResult
    public func setCurrent(_ address: LayerAddress) -> Bool {
        guard isSelectable(address) else { return false }
        current = address
        onChange?()
        return true
    }

    // MARK: - エンティティ変更(CommandStack経由で呼ばれる想定。直接呼んでも動く)

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

    /// 複数エンティティを同id置換する(属性一括変更・レイヤ間移動用)
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
        let base = LayerAddress(0, 2)   // 基本作図
        let pipe = LayerAddress(0, 3)   // 空調配管

        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ layer: LayerAddress) {
            entities.append(Entity(layer: layer,
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
        entities.append(Entity(layer: pipe, kind: .circle(center: Vec2(4000, 6100), radius: 60)))
        entities.append(Entity(layer: pipe, kind: .circle(center: Vec2(4000, 5800), radius: 60)))
        // 注記(文字高さは実寸mm: 1/50印刷時に紙面7mm/6mm相当)
        entities.append(Entity(layer: base,
                               kind: .text(position: Vec2(1100, 6600), content: "AC-1", height: 350, angle: 0)))
        entities.append(Entity(layer: pipe,
                               kind: .text(position: Vec2(4300, 6350), content: "50A 冷温水(往)", height: 300, angle: 0)))
        onChange?()
    }
}
