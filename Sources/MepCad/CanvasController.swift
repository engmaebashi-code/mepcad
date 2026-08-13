import Foundation
import AppKit
import UniformTypeIdentifiers
import MepCore
import MepFormats
import MepRender
import MepTools

/// 選択中オブジェクトの属性サマリ(プロパティパネル表示用)
struct SelectionSummary: Equatable {
    var count: Int
    var lineCount: Int
    var circleCount: Int
    var arcCount: Int
    var textCount: Int
    var pointCount: Int
    /// 全選択で共通ならその値(内側nil=byLayer)、混在なら外側nil
    var commonColorIndex: Int??
    var commonLineType: Int??
    var commonLineWeight: Double??
    var commonLayer: LayerAddress?
}

/// キャンバスの状態と操作を束ねるコントローラ(メインスレッド専用)。
/// NSView(イベント)とSwiftUI(ステータスバー・パネル)の橋渡しをする。
final class CanvasController: NSObject {
    let document: Document
    let commandStack: CommandStack
    let snapEngine = SnapEngine()
    let tools: DrawingToolController
    let editOp = EditOperation()

    var transform = ViewTransform(scale: 0.08, origin: Vec2(60, 540))
    var theme = RenderTheme.light()
    var gridSpacing: Double = 250  // mm
    var gridVisible = true
    var pickBoxPx: Double = 10     // 環境設定と連動予定

    /// 描画に渡すグリッド間隔(非表示時は0=描かない)
    var effectiveGridSpacing: Double { gridVisible ? gridSpacing : 0 }

    func toggleGrid() {
        gridVisible.toggle()
        // グリッド非表示のときはグリッドスナップも無効にする(端点スナップは維持)
        snapEngine.gridEnabled = gridVisible
        // グリッドはキャッシュに焼き込まれているため破棄が必要
        onDocumentChanged?()
        needsContentRedraw?()
        onGridChanged?(gridVisible)  // 状態はコントローラが唯一の情報源(UI側はこれに追従)
    }

    /// 最後に計算したカーソル状態(オーバーレイ描画用)
    var cursorScreen: Vec2?
    var snappedScreen: Vec2?
    var snappedKind: SnapKind?
    /// 作図プレビュー(ワールド座標。オーバーレイが描画)
    var previewShape: PreviewShape = .none

    // MARK: - 選択状態(M4)

    /// 現在の選択(idの集合)
    private(set) var selection: Set<EntityID> = []
    /// オーバーレイ描画用の選択エンティティ実体キャッシュ
    private(set) var selectedEntities: [Entity] = []
    /// 矩形選択(マーキー)中のスクリーン座標
    var marqueeStartScreen: Vec2?
    var marqueeCurrentScreen: Vec2?
    /// マーキーのモード(ドラッグ方向で決まる: 左→右=窓、右→左=交差)
    var marqueeMode: RectSelectionMode {
        guard let s = marqueeStartScreen, let c = marqueeCurrentScreen else { return .window }
        return c.x >= s.x ? .window : .crossing
    }
    /// 移動/複写/回転ゴーストの変換(ワールド)。nilなら非表示
    var ghostTransform: EditTransform?
    /// SwiftUIパネル上にカーソルがある間true(十字カーソルを消して矢印に戻す)
    var uiHovering = false {
        didSet {
            guard uiHovering != oldValue else { return }
            if uiHovering {
                cursorScreen = nil
                snappedScreen = nil
                snappedKind = nil
            }
            needsOverlayRedraw?()
            onUIHoverChanged?()
        }
    }

    /// UI更新通知
    var onStatusUpdate: ((_ coords: String, _ zoom: String, _ snap: String) -> Void)?
    var onInfo: ((String) -> Void)?
    var onToolChanged: ((ToolKind) -> Void)?
    var needsContentRedraw: (() -> Void)?
    var needsOverlayRedraw: (() -> Void)?
    /// ドキュメント内容の変更(描画キャッシュ破棄が必要)
    var onDocumentChanged: (() -> Void)?
    /// キャンバスの現在サイズ(コンテナビューが提供)
    var viewSizeProvider: (() -> CGSize)?
    /// レイヤ構造の変化(レイヤパネル用: 16グループ+カレント+レイヤ別要素数[256])
    var onLayersChanged: (([LayerGroup], LayerAddress, [Int]) -> Void)?
    /// 選択の変化(プロパティパネル用)
    var onSelectionChanged: ((SelectionSummary?) -> Void)?
    /// パネルホバー状態の変化(カーソル矩形の更新用)
    var onUIHoverChanged: (() -> Void)?
    /// 右端接近の変化(Dock風パネルの出し入れ用。trueで接近)
    var onEdgeProximity: ((Bool) -> Void)?
    private var lastEdgeProximity = false
    /// グリッド表示状態の変化(ステータスバー表示の同期用)
    var onGridChanged: ((Bool) -> Void)?
    /// グリッド間隔の変化(ステータスバー表示の同期用)
    var onGridSpacingChanged: ((Double) -> Void)?
    /// 補助線表示状態の変化(ステータスバー表示の同期用)
    var onAuxiliaryChanged: ((Bool) -> Void)?

    override init() {
        let doc = Document()
        document = doc
        commandStack = CommandStack(document: doc)
        tools = DrawingToolController(currentLayer: doc.current)
        super.init()
        document.loadDemoContent()
        snapEngine.rebuild(from: document)
        document.onChange = { [weak self] in
            guard let self else { return }
            self.snapEngine.rebuild(from: self.document)
            // 書込レイヤの変更をツールに同期
            self.tools.currentLayer = self.document.current
            // 選択中エンティティが消えた/変わった場合に追従
            self.pruneSelection()
            self.onDocumentChanged?()
            self.needsContentRedraw?()
            self.publishLayers()
        }
        tools.delegate = self
    }

    // MARK: - 選択(M4)

    /// ワールド座標でのヒット許容距離(画面上のピックボックス半幅+1px)
    private var hitToleranceMm: Double {
        (pickBoxPx / 2 + 1) / max(transform.scale, 1e-9)
    }

    /// クリック選択。shift=追加/除外トグル
    func clickSelect(atScreen p: Vec2, shiftDown: Bool) {
        let world = transform.toWorld(p)
        let hit = SelectionEngine.topmostHit(at: world, tolerance: hitToleranceMm,
                                             entities: document.entities,
                                             groups: document.groups,
                                             includeAuxiliary: document.showAuxiliary)
        if let hit {
            if shiftDown {
                if selection.contains(hit) { selection.remove(hit) } else { selection.insert(hit) }
            } else {
                selection = [hit]
            }
        } else if !shiftDown {
            selection = []
        }
        selectionDidChange()

        // 空振り時の診断: ロック/表示のみレイヤの要素だったら理由を知らせる
        // (「クリックしても選べない」を無言にしない)
        if hit == nil {
            let visibleOnly = SelectionEngine.topmostHit(at: world, tolerance: hitToleranceMm,
                                                         entities: document.entities,
                                                         groups: document.groups,
                                                         among: SelectionEngine.visibleAddresses(document.groups),
                                                         includeAuxiliary: document.showAuxiliary)
            if let visibleOnly, let entity = document.entity(id: visibleOnly) {
                onInfo?("その要素は \(layerDisplayName(entity.layer)) がロック中のため選択できません(レイヤパネルで解除)")
            }
        }
    }

    /// 矩形選択の確定
    func commitMarquee(shiftDown: Bool) {
        defer {
            marqueeStartScreen = nil
            marqueeCurrentScreen = nil
            needsOverlayRedraw?()
        }
        guard let s = marqueeStartScreen, let c = marqueeCurrentScreen else { return }
        let mode = marqueeMode
        let w1 = transform.toWorld(s)
        let w2 = transform.toWorld(c)
        let rect = BBox(minX: min(w1.x, w2.x), minY: min(w1.y, w2.y),
                        maxX: max(w1.x, w2.x), maxY: max(w1.y, w2.y))
        let ids = SelectionEngine.ids(in: rect, mode: mode,
                                      entities: document.entities,
                                      groups: document.groups,
                                      includeAuxiliary: document.showAuxiliary)
        if shiftDown {
            selection.formUnion(ids)
        } else {
            selection = Set(ids)
        }
        selectionDidChange()
    }

    func selectAll() {
        let selectable = SelectionEngine.selectableAddresses(document.groups)
        selection = Set(document.entities.filter {
            selectable.contains($0.layer) && (document.showAuxiliary || !$0.isAuxiliary)
        }.map(\.id))
        selectionDidChange()
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
        selectionDidChange()
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let snapshot = document.entities(ids: selection)
        selection = []
        commandStack.run(RemoveEntitiesCommand(entities: snapshot))
        selectionDidChange()
        onInfo?("\(snapshot.count)個の要素を削除しました(⌘Zで取り消し)")
    }

    /// ドキュメント変更後、存在しないid・選択不能になったidを選択から取り除く
    private func pruneSelection() {
        guard !selection.isEmpty else {
            selectedEntities = []
            return
        }
        let selectable = SelectionEngine.selectableAddresses(document.groups)
        var pruned = Set<EntityID>()
        for e in document.entities where selection.contains(e.id) && selectable.contains(e.layer) {
            // 補助線が非表示なら補助線も選択から外す
            if !document.showAuxiliary, e.isAuxiliary { continue }
            pruned.insert(e.id)
        }
        selection = pruned
        selectedEntities = document.entities(ids: selection)
        // 移動・複写の途中で選択が消えたら(レイヤロック等)操作も終了する
        if selection.isEmpty, editOp.isActive {
            cancelEditOperation()
        }
        onSelectionChanged?(selectionSummary())
        needsOverlayRedraw?()
    }

    private func selectionDidChange() {
        selectedEntities = document.entities(ids: selection)
        needsOverlayRedraw?()
        onSelectionChanged?(selectionSummary())
        publishSelectionHint()
    }

    private func publishSelectionHint() {
        if editOp.isActive { return }
        if selection.isEmpty {
            if tools.kind == .select {
                onInfo?("クリック=選択 / 左→右ドラッグ=窓選択 / 右→左=交差選択 / 右クリック=メニュー")
            }
        } else {
            onInfo?("\(selection.count)個選択中 — 右クリック=複写・移動 / delete=削除 / esc=解除")
        }
    }

    private func selectionSummary() -> SelectionSummary? {
        guard !selectedEntities.isEmpty else { return nil }
        var lines = 0, circles = 0, arcs = 0, texts = 0, points = 0
        for e in selectedEntities {
            switch e.kind {
            case .line: lines += 1
            case .circle: circles += 1
            case .arc: arcs += 1
            case .text: texts += 1
            case .point: points += 1
            }
        }
        func common<T: Equatable>(_ values: [T]) -> T? {
            guard let first = values.first else { return nil }
            return values.allSatisfy { $0 == first } ? first : nil
        }
        return SelectionSummary(
            count: selectedEntities.count,
            lineCount: lines, circleCount: circles, arcCount: arcs, textCount: texts,
            pointCount: points,
            commonColorIndex: common(selectedEntities.map(\.style.colorIndex)),
            commonLineType: common(selectedEntities.map(\.style.lineType)),
            commonLineWeight: common(selectedEntities.map(\.style.lineWeight)),
            commonLayer: common(selectedEntities.map(\.layer))
        )
    }

    // MARK: - 選択オブジェクトの属性変更(プロパティパネルから)

    /// スタイル・レイヤの一括変更。changeでコピーを書き換える
    private func updateSelection(name: String, change: (inout Entity) -> Void) {
        guard !selectedEntities.isEmpty else { return }
        let before = selectedEntities
        var after = before
        for i in after.indices { change(&after[i]) }
        guard after != before else { return }
        commandStack.run(UpdateEntitiesCommand(name: name, before: before, after: after))
        selectionDidChange()
    }

    func applyColorIndex(_ index: Int?) {
        updateSelection(name: "色変更") { $0.style.colorIndex = index }
    }

    func applyLineType(_ type: Int?) {
        updateSelection(name: "線種変更") { $0.style.lineType = type }
    }

    func applyLineWeight(_ weight: Double?) {
        updateSelection(name: "太さ変更") { $0.style.lineWeight = weight }
    }

    // MARK: - レイヤ間の移動・複写(M4.1)

    /// 選択をレイヤへ移動(同id・属性維持でレイヤだけ変更。Undo可)
    func moveSelectionToLayer(_ address: LayerAddress) {
        let count = selectedEntities.count  // 移動先が非表示/ロックだと選択が減るため先に取る
        guard count > 0 else { return }
        updateSelection(name: "レイヤへ移動") { $0.layer = address }
        onInfo?("\(count)個を \(layerDisplayName(address)) へ移動しました(⌘Zで取り消し)")
    }

    /// 選択をレイヤへ複写(同位置に複製を作り、指定レイヤへ。Undo可)
    func copySelectionToLayer(_ address: LayerAddress) {
        guard !selectedEntities.isEmpty else { return }
        let copies = selectedEntities.map { entity -> Entity in
            var copy = entity.duplicated(by: .zero)
            copy.layer = address
            return copy
        }
        commandStack.run(AddEntitiesCommand(name: "レイヤへ複写", entities: copies))
        if document.isSelectable(address) {
            // 複写先を新しい選択にする(そのまま移動などを続けられる)
            selection = Set(copies.map(\.id))
            selectionDidChange()
            onInfo?("\(copies.count)個を \(layerDisplayName(address)) へ複写しました(⌘Zで取り消し)")
        } else {
            // 非表示・ロック先への複写は選択を引き継がない(見えない選択を作らない)
            selection = []
            selectionDidChange()
            onInfo?("\(copies.count)個を \(layerDisplayName(address)) へ複写しました(非表示/ロック中のレイヤです。⌘Zで取り消し)")
        }
    }

    /// レイヤの表示名: 「0-3 空調配管」/ 名前が無ければ「0-3」
    func layerDisplayName(_ address: LayerAddress) -> String {
        let name = document.layer(at: address).name
        return name.isEmpty ? address.description : "\(address.description) \(name)"
    }

    // MARK: - 移動・複写(M4)

    func beginEditOperation(_ kind: EditOpKind) {
        guard !selection.isEmpty else { return }
        // 作図ツール中なら選択ツールへ戻してから開始
        if tools.kind != .select { tools.select(.select) }
        editOp.angleConstraint = tools.angleConstraint  // パレットの角度拘束を移動・複写にも効かせる
        editOp.begin(kind, hasSelection: true)
        ghostTransform = nil
        onInfo?(editOp.hint)
        needsOverlayRedraw?()
    }

    /// 編集操作中のクリック(スナップ有効)
    func editClick() {
        guard editOp.isActive, let cursor = cursorScreen else { return }
        let effective = snappedScreen ?? cursor
        let world = transform.toWorld(effective)
        if let result = editOp.click(at: world) {
            commitEditTransform(result)  // 結果メッセージはコミット側が出す
        } else if editOp.isActive {
            onInfo?(editOp.hint)
        }
        ghostTransform = editOp.previewTransform(cursor: world)
        needsOverlayRedraw?()
    }

    private func commitEditTransform(_ result: EditTransform) {
        guard !selection.isEmpty else { return }
        switch (editOp.kind, result) {
        case (.move, .translate(let delta)):
            commandStack.run(TranslateEntitiesCommand(ids: selection, delta: delta))
            onInfo?("\(selection.count)個を移動しました(⌘Zで取り消し)")
        case (.copy, .translate(let delta)):
            let copies = selectedEntities.map { $0.duplicated(by: delta) }
            commandStack.run(AddEntitiesCommand(name: "複写", entities: copies))
            onInfo?("\(copies.count)個を複写しました — 続けてクリックで連続配置 / escで終了")
        case (.rotate, .rotate(let center, let angle)):
            commandStack.run(RotateEntitiesCommand(ids: selection, center: center, angle: angle))
            onInfo?(String(format: "%d個を %.1f° 回転しました(⌘Zで取り消し)", selection.count, angle * 180 / .pi))
        case (.rotateCopy, .rotate(let center, let angle)):
            let copies = selectedEntities.map {
                $0.duplicated(by: .zero).rotated(around: center, byRadians: angle)
            }
            commandStack.run(AddEntitiesCommand(name: "回転複写", entities: copies))
            onInfo?(String(format: "%d個を %.1f° 回転複写しました — 続けてクリックで連続配置 / escで終了", copies.count, angle * 180 / .pi))
        default:
            break
        }
    }

    func cancelEditOperation() {
        guard editOp.isActive else { return }
        editOp.cancel()
        ghostTransform = nil
        publishSelectionHint()
        needsOverlayRedraw?()
    }

    /// 角度拘束の変更(ツールバーのパレットから。作図と編集の両方に効く)
    func setAngleConstraint(_ constraint: AngleConstraint) {
        tools.angleConstraint = constraint
        editOp.angleConstraint = constraint
    }

    // MARK: - 右クリックメニュー(M4)

    /// 現在の状態に応じたコンテキストメニュー。nilならメニューを出さない
    /// (作図ツール中・編集操作中は右クリック=キャンセルの操作感を維持)
    func contextMenu() -> NSMenu? {
        guard tools.kind == .select, !editOp.isActive else { return nil }

        let menu = NSMenu()
        if !selection.isEmpty {
            // 最上段: 複写・移動(一番使うため)
            menu.addItem(menuItem("複写", #selector(menuCopy)))
            menu.addItem(menuItem("移動", #selector(menuMove)))
            menu.addItem(menuItem("回転", #selector(menuRotate)))
            menu.addItem(menuItem("回転複写", #selector(menuRotateCopy)))
            menu.addItem(.separator())
            // レイヤ間の移動・複写(グループ→レイヤの2段サブメニュー)
            menu.addItem(layerSubmenu(title: "レイヤへ移動", action: #selector(menuMoveToLayer(_:))))
            menu.addItem(layerSubmenu(title: "レイヤへ複写", action: #selector(menuCopyToLayer(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("削除", #selector(menuDelete)))
            menu.addItem(.separator())
            menu.addItem(menuItem("選択解除", #selector(menuDeselect)))
        } else {
            menu.addItem(menuItem("すべて選択", #selector(menuSelectAll)))
            menu.addItem(menuItem("全体表示", #selector(menuFit)))
            menu.addItem(menuItem(gridVisible ? "グリッドを隠す" : "グリッドを表示", #selector(menuToggleGrid)))
        }
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// グループ→レイヤの2段サブメニュー。tagにグループ×16+レイヤを入れて選択先を渡す
    private func layerSubmenu(title: String, action: Selector) -> NSMenuItem {
        // 共通レイヤはループの外で1回だけ計算する(大量選択で256回のO(n)走査になるのを防ぐ)
        var commonLayer: LayerAddress?
        if let first = selectedEntities.first?.layer,
           selectedEntities.allSatisfy({ $0.layer == first }) {
            commonLayer = first
        }

        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let groupsMenu = NSMenu()
        for g in 0..<16 {
            let group = document.group(g)
            let groupTitle = group.name.isEmpty
                ? String(format: "グループ%X (%@)", g, group.scaleLabel)
                : String(format: "%X %@ (%@)", g, group.name, group.scaleLabel)
            let groupItem = NSMenuItem(title: groupTitle, action: nil, keyEquivalent: "")
            let layersMenu = NSMenu()
            for l in 0..<16 {
                let address = LayerAddress(g, l)
                let item = NSMenuItem(title: layerDisplayName(address), action: action, keyEquivalent: "")
                item.target = self
                item.tag = g * 16 + l
                // 現在の選択が居るレイヤに印
                if commonLayer == address {
                    item.state = .on
                }
                layersMenu.addItem(item)
            }
            groupItem.submenu = layersMenu
            groupsMenu.addItem(groupItem)
        }
        root.submenu = groupsMenu
        return root
    }

    @objc private func menuCopy() { beginEditOperation(.copy) }
    @objc private func menuMove() { beginEditOperation(.move) }
    @objc private func menuRotate() { beginEditOperation(.rotate) }
    @objc private func menuRotateCopy() { beginEditOperation(.rotateCopy) }
    @objc private func menuDelete() { deleteSelection() }
    @objc private func menuDeselect() { clearSelection() }
    @objc private func menuSelectAll() { selectAll() }
    @objc private func menuFit() {
        if let size = viewSizeProvider?() { fit(viewSize: size) }
    }
    @objc private func menuToggleGrid() { toggleGrid() }
    @objc private func menuMoveToLayer(_ sender: NSMenuItem) {
        moveSelectionToLayer(LayerAddress(sender.tag / 16, sender.tag % 16))
    }
    @objc private func menuCopyToLayer(_ sender: NSMenuItem) {
        copySelectionToLayer(LayerAddress(sender.tag / 16, sender.tag % 16))
    }

    // MARK: - レイヤ操作(レイヤパネルから)

    func setLayerVisible(_ address: LayerAddress, _ visible: Bool) {
        document.updateLayer(at: address) { $0.isVisible = visible }
    }

    func setLayerLocked(_ address: LayerAddress, _ locked: Bool) {
        document.updateLayer(at: address) { $0.isEditable = !locked }
    }

    func setGroupVisible(_ index: Int, _ visible: Bool) {
        document.updateGroup(index) { $0.isVisible = visible }
    }

    func setGroupLocked(_ index: Int, _ locked: Bool) {
        document.updateGroup(index) { $0.isEditable = !locked }
    }

    /// 書込レイヤの変更(非表示・ロックには書き込めない)。成功でtrue
    @discardableResult
    func setCurrentLayer(_ address: LayerAddress) -> Bool {
        let ok = document.setCurrent(address)
        if !ok {
            onInfo?("\(layerDisplayName(address)) は非表示またはロック中のため書込先にできません")
        }
        return ok
    }

    private func publishLayers() {
        // レイヤ別の要素数(空レイヤを薄く表示するため)
        var counts = [Int](repeating: 0, count: 256)
        for e in document.entities {
            counts[e.layer.group * 16 + e.layer.layer] += 1
        }
        onLayersChanged?(document.groups, document.current, counts)
    }

    /// グリッド間隔の変更(50刻みプリセット/自由入力)。選択したら非表示中でも表示に戻す
    func setGridSpacing(_ mm: Double) {
        gridSpacing = max(1, mm)
        snapEngine.gridSpacing = gridSpacing
        if !gridVisible {
            gridVisible = true
            snapEngine.gridEnabled = true
            onGridChanged?(gridVisible)
        }
        // グリッドはキャッシュに焼き込まれているため破棄が必要
        onDocumentChanged?()
        needsContentRedraw?()
        onGridSpacingChanged?(gridSpacing)
        onInfo?("グリッド間隔を \(Int(gridSpacing))mm にしました(グリッドスナップも連動)")
    }

    /// 自由入力のグリッド間隔(910などのモジュール寸法用)
    func promptGridSpacing() {
        let alert = NSAlert()
        alert.messageText = "グリッド間隔(実寸mm)"
        alert.informativeText = "例: 910(モジュール)、455、303 など"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.stringValue = String(Int(gridSpacing))
        alert.accessoryView = field
        alert.addButton(withTitle: "設定")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let value = Double(field.stringValue.trimmingCharacters(in: .whitespaces)),
              value >= 1, value <= 100000 else { return }
        setGridSpacing(value)
    }

    /// 補助線(補助線種・補助線色)の表示切替。
    /// 非表示中は描画・スナップ・選択のすべてから外れる(JWWビューワーと同じ考え方)
    func toggleAuxiliary() {
        document.setShowAuxiliary(!document.showAuxiliary)  // onChange経由でキャッシュ破棄・スナップ再構築
        onAuxiliaryChanged?(document.showAuxiliary)
        onInfo?(document.showAuxiliary
                ? "補助線を表示しました"
                : "補助線を非表示にしました(スナップ・選択からも外れます)")
    }

    /// 初期表示用(SwiftUI側のonAppearから呼ぶ)
    func publishInitialState() {
        publishLayers()
        onSelectionChanged?(selectionSummary())
        onGridChanged?(gridVisible)
        onGridSpacingChanged?(gridSpacing)
        onAuxiliaryChanged?(document.showAuxiliary)
    }

    // MARK: - 作図ツール(M3)

    func selectTool(_ kind: ToolKind) {
        cancelEditOperation()
        tools.select(kind)
    }

    /// クリック(作図ツール用)。スナップが効いていればスナップ点を使う
    func toolClick(shiftDown: Bool) {
        guard let cursor = cursorScreen else { return }
        let effective = snappedScreen ?? cursor
        tools.click(at: transform.toWorld(effective), shiftDown: shiftDown)
        refreshPreview(shiftDown: shiftDown)
    }

    func toolCancel() {
        if editOp.isActive {
            cancelEditOperation()
            return
        }
        if tools.kind == .select, !selection.isEmpty {
            clearSelection()
            return
        }
        tools.cancel()
        previewShape = .none
        needsOverlayRedraw?()
    }

    func toolKey(_ character: Character) -> Bool {
        // 編集操作(移動・複写)の数値入力を優先
        if editOp.isActive {
            var committed = false
            let handled = editOp.keyInput(character) { [weak self] result in
                committed = true
                self?.commitEditTransform(result)
                self?.ghostTransform = nil
            }
            if handled {
                // コミット時は結果メッセージ(commitEditDelta側)を残す
                if !committed, editOp.isActive {
                    onInfo?(editOp.hint)
                }
                needsOverlayRedraw?()
            }
            return handled
        }
        let handled = tools.keyInput(character)
        if handled {
            // 数値バッジ表示と、⏎確定後のプレビュー更新
            refreshPreview(shiftDown: false)
        }
        return handled
    }

    private func refreshPreview(shiftDown: Bool) {
        guard let cursor = cursorScreen else {
            previewShape = .none
            return
        }
        let effective = snappedScreen ?? cursor
        previewShape = tools.preview(cursor: transform.toWorld(effective), shiftDown: shiftDown)
        needsOverlayRedraw?()
    }

    func undo() {
        commandStack.undo()
    }

    func redo() {
        commandStack.redo()
    }

    // MARK: - JWW読込(M2 → M4.1で16×16展開に変更)

    func openJwwPanel() {
        let panel = NSOpenPanel()
        panel.title = "JWWファイルを開く"
        if let jwwType = UTType(filenameExtension: "jww") {
            panel.allowedContentTypes = [jwwType]
        }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadJww(url: url)
    }

    func loadJww(url: URL) {
        onInfo?("JWW読込中… \(url.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // 解析はバックグラウンド、ドキュメント反映はメインで行う
                let data = try Data(contentsOf: url)
                let parser = JwwParser(data: data)
                let start = Date()
                let drawing = try parser.parse()
                let parseMs = Int(Date().timeIntervalSince(start) * 1000)

                DispatchQueue.main.async {
                    // 「開く」= 図面全体の置き換え(レイヤ構造ごとJWWの16×16を展開)
                    self.selection = []
                    let stats = JwwReader.importDrawingWithStats(drawing, into: self.document)
                    self.selectionDidChange()
                    if let size = self.viewSizeProvider?() {
                        self.fit(viewSize: size)
                    }
                    var note = "そのまま編集できます"
                    if stats.visibilityRelaxed || stats.locksRelaxed {
                        note = "レイヤ状態が読めなかったため全レイヤを編集可能で展開しました"
                    }
                    self.onInfo?("\(url.lastPathComponent) — 線\(drawing.lines.count) 弧\(drawing.arcs.count) 字\(drawing.texts.count) / 解析\(parseMs)ms / 計\(stats.entityCount)要素(\(note))")
                }
            } catch {
                DispatchQueue.main.async {
                    self.onInfo?("読込エラー: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 操作

    func pan(dx: Double, dy: Double) {
        transform.pan(by: Vec2(dx, dy))
        needsContentRedraw?()
        needsOverlayRedraw?()
    }

    func zoom(factor: Double, atScreen p: Vec2) {
        transform.zoom(by: factor, at: p)
        needsContentRedraw?()
        needsOverlayRedraw?()
        publishStatus()
    }

    func fit(viewSize: CGSize) {
        var box = document.bounds
        if box.isEmpty { box = BBox(minX: 0, minY: 0, maxX: 10000, maxY: 8000) }
        transform.fit(box.expanded(by: 500), in: Vec2(Double(viewSize.width), Double(viewSize.height)))
        needsContentRedraw?()
        needsOverlayRedraw?()
        publishStatus()
    }

    func mouseMoved(toScreen p: Vec2, shiftDown: Bool = false) {
        // 右端接近の検知(Dock風パネルのトリガ)
        if let size = viewSizeProvider?(), size.width > 0 {
            let near = Double(size.width) - p.x < 16
            if near != lastEdgeProximity {
                lastEdgeProximity = near
                onEdgeProximity?(near)
            }
        }
        guard !uiHovering else { return }
        cursorScreen = p
        let world = transform.toWorld(p)
        let radiusMm = pickBoxPx / max(transform.scale, 1e-9)
        snapEngine.gridSpacing = gridSpacing
        if let result = snapEngine.snap(world, radius: radiusMm) {
            snappedScreen = transform.toScreen(result.point)
            snappedKind = result.kind
        } else {
            snappedScreen = nil
            snappedKind = nil
        }
        // 作図中プレビューの更新
        if tools.isDrawingToolActive {
            let effective = snappedScreen ?? p
            previewShape = tools.preview(cursor: transform.toWorld(effective), shiftDown: shiftDown)
        } else {
            previewShape = .none
        }
        // 移動・複写・回転のゴースト更新(スナップ点優先)
        if editOp.isActive {
            let effective = snappedScreen ?? p
            ghostTransform = editOp.previewTransform(cursor: transform.toWorld(effective))
        } else {
            ghostTransform = nil
        }
        needsOverlayRedraw?()
        publishStatus()
    }

    func mouseExited() {
        cursorScreen = nil
        snappedScreen = nil
        snappedKind = nil
        needsOverlayRedraw?()
    }

    func toggleTheme() {
        theme = theme.isDark ? .light() : .dark()
        // テーマは描画キャッシュに焼き込まれているため、キャッシュ破棄が必須
        onDocumentChanged?()
        needsContentRedraw?()
        needsOverlayRedraw?()
    }

    // MARK: - ステータス

    private func publishStatus() {
        guard let p = cursorScreen else { return }
        let effective = snappedScreen ?? p
        let w = transform.toWorld(effective)
        let coords = String(format: "X: %.0f  Y: %.0f", w.x, w.y)
        let zoom = String(format: "%.0f%%", transform.scale * 1000)  // 1/50図面での見かけ倍率目安
        let snapText = snappedKind?.label ?? "—"
        onStatusUpdate?(coords, zoom, snapText)
    }
}

// MARK: - DrawingToolDelegate

extension CanvasController: DrawingToolDelegate {

    func toolDidProduce(_ entity: Entity) {
        commandStack.run(AddEntityCommand(entity: entity))
    }

    func toolDidProduceGroup(_ entities: [Entity], name: String) {
        commandStack.run(AddEntitiesCommand(name: name, entities: entities))
    }

    func toolRequestsText(at point: Vec2, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "文字を入力"
        alert.informativeText = "配置位置: X \(Int(point.x))  Y \(Int(point.y))"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "配置")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func toolStatusChanged(_ hint: String) {
        onInfo?(hint)
    }

    func toolKindChanged(_ kind: ToolKind) {
        previewShape = .none
        needsOverlayRedraw?()
        onToolChanged?(kind)
    }
}
